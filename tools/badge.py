#!/usr/bin/env python3
"""CLI for the Hack the North 2026 Hacker Badge.

Speaks the same serial protocol as the web IDE (badge.hackthenorth.com/ide/):
115200 baud, bare-CR line endings, "badge> " prompt.
  put <remote> <n>  ->  READY  ->  raw bytes (128B chunks, 20ms pace)  ->  OK <n>

Usage:
  badge.py ports                  list candidate serial ports
  badge.py cmd "apps"             run a console command (apps, heap, ls, rm, reload...)
  badge.py push <app_dir>         install an app dir (manifest.cfg + main.lua) to the badge
  badge.py reboot                 reboot the badge
  badge.py monitor [seconds]      tail serial output (default 10s)
"""
import sys
import time
import glob

import serial
from serial.tools import list_ports

BAUD = 115200
WRITE_CHUNK = 128
WRITE_PAUSE = 0.02
PROMPT = b"badge> "


def find_port():
    for p in list_ports.comports():
        if p.vid == 0x303A:  # Espressif USB JTAG/serial debug unit
            return p.device
    candidates = glob.glob("/dev/cu.usbmodem*")
    if candidates:
        return candidates[0]
    sys.exit("no badge found: plug in USB (badge OFF first, then ON, don't hold Start)")


def open_badge():
    port = find_port()
    ser = serial.Serial(port, BAUD, timeout=0.1)
    print(f"[badge] connected to {port}")
    return ser


def send_line(ser, line):
    ser.write((line + "\r").encode())  # bare CR, per firmware ESP_LINE_ENDINGS_CR


def wait_for(ser, pattern, timeout=5.0):
    deadline = time.time() + timeout
    buf = b""
    while time.time() < deadline:
        chunk = ser.read(4096)
        if chunk:
            buf += chunk
            idx = buf.find(pattern)
            if idx >= 0:
                return buf[: idx + len(pattern)]
    raise TimeoutError(f'timeout waiting for {pattern!r}; got {buf[-200:]!r}')


def sync(ser):
    ser.reset_input_buffer()
    send_line(ser, "")
    wait_for(ser, PROMPT, 3.0)


def run_cmd(ser, command, timeout=5.0):
    ser.reset_input_buffer()
    send_line(ser, command)
    out = wait_for(ser, PROMPT, timeout)
    return out.decode(errors="replace")


def resync(ser, pending):
    # a failed transfer can leave the badge blocked reading file bytes;
    # feed it the most it could still want, then find the prompt again
    if pending:
        for i in range(0, pending, WRITE_CHUNK):
            ser.write(bytes(min(WRITE_CHUNK, pending - i)))
            time.sleep(WRITE_PAUSE)
    ser.reset_input_buffer()
    for _ in range(3):
        send_line(ser, "")
        try:
            wait_for(ser, PROMPT, 2.0)
            return True
        except TimeoutError:
            pass
    return False


def read_back(ser, remote):
    out = run_cmd(ser, f"cat {remote}", timeout=30.0)
    body = out.split("\n", 1)[1].rsplit("badge>", 1)[0]
    return body.replace("\r\n", "\n").replace("\r", "\n").strip("\n")


def put_file(ser, remote, data):
    # a stalled transfer can leave a file that is the right SIZE but padded
    # with garbage (resync feeds filler bytes), so size is not proof:
    # verify contents by reading the file back after every upload
    for attempt in range(3):
        chunk = WRITE_CHUNK if attempt == 0 else 64  # retries go gentler
        pause = WRITE_PAUSE if attempt == 0 else 0.04
        try:
            ser.reset_input_buffer()
            send_line(ser, f"put {remote} {len(data)}")
            wait_for(ser, b"READY", 5.0)
            for i in range(0, len(data), chunk):
                ser.write(data[i : i + chunk])
                if i + chunk < len(data):
                    time.sleep(pause)  # badge RX ring is 256B
            wait_for(ser, b"OK %d" % len(data), 30.0)
            if read_back(ser, remote) == data.decode(errors="replace").strip("\n"):
                return
            print(f"\n[push] {remote} verify mismatch, retrying...")
        except TimeoutError:
            print(f"\n[push] {remote} stalled, resyncing (try {attempt + 1}/3)...")
            if not resync(ser, len(data)):
                raise
    raise TimeoutError(f"gave up on {remote} after 3 tries")


def push(app_dir):
    from pathlib import Path

    app = Path(app_dir)
    manifest = (app / "manifest.cfg").read_text()
    slug = None
    for line in manifest.splitlines():
        if line.strip().startswith("slug"):
            slug = line.split("=", 1)[1].strip()
    if not slug:
        sys.exit("manifest.cfg has no slug= line")

    files = [p for p in sorted(app.rglob("*")) if p.is_file() and p.name != "README.md"]
    ser = open_badge()
    try:
        sync(ser)
        remote_dir = f"/littlefs/apps/{slug}"
        run_cmd(ser, f"mkdir {remote_dir}")
        made = {remote_dir}
        for f in files:
            remote = f"{remote_dir}/{f.relative_to(app)}"
            parent = remote.rsplit("/", 1)[0]
            if parent not in made:
                run_cmd(ser, f"mkdir {parent}")
                made.add(parent)
            data = f.read_bytes()
            print(f"[push] {f.relative_to(app)} ({len(data)} B)...", end=" ", flush=True)
            put_file(ser, remote, data)
            print("OK")
        ser.reset_input_buffer()
        send_line(ser, "reload")
        wait_for(ser, b"reload:", 8.0)
        print(f"[push] reload confirmed — '{slug}' installed, open it from the launcher")
    finally:
        ser.close()


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    action = sys.argv[1]
    if action == "ports":
        for p in list_ports.comports():
            vid = f"{p.vid:04x}" if p.vid else "----"
            print(f"{p.device}  vid={vid}  {p.description}")
        return
    if action == "push":
        push(sys.argv[2])
        return
    ser = open_badge()
    try:
        if action == "cmd":
            sync(ser)
            print(run_cmd(ser, sys.argv[2]), end="")
        elif action == "reboot":
            send_line(ser, "reboot")
            print("[badge] reboot sent")
        elif action == "monitor":
            duration = float(sys.argv[2]) if len(sys.argv) > 2 else 10
            end = time.time() + duration
            while time.time() < end:
                chunk = ser.read(4096)
                if chunk:
                    sys.stdout.write(chunk.decode(errors="replace"))
                    sys.stdout.flush()
        else:
            sys.exit(f"unknown action: {action}")
    finally:
        ser.close()


if __name__ == "__main__":
    main()
