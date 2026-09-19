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


def put_file(ser, remote, data):
    ser.reset_input_buffer()
    send_line(ser, f"put {remote} {len(data)}")
    wait_for(ser, b"READY", 5.0)
    for i in range(0, len(data), WRITE_CHUNK):
        ser.write(data[i : i + WRITE_CHUNK])
        if i + WRITE_CHUNK < len(data):
            time.sleep(WRITE_PAUSE)  # badge RX ring is 256B; don't overflow it
    wait_for(ser, b"OK %d" % len(data), 20.0)


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
