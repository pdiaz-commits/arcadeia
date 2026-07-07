#!/usr/bin/env python3
"""Servidor que recibe frames de MAME (Lua) y guarda la demo."""

from __future__ import annotations

import json
import socket
import sys
import threading
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEMO_DIR = ROOT / "logs" / "demos"
HOST, PORT = "127.0.0.1", 9877


def main() -> None:
    DEMO_DIR.mkdir(parents=True, exist_ok=True)
    session = DEMO_DIR / f"session_{datetime.now().strftime('%Y%m%d_%H%M%S')}.jsonl"
    session.write_text("", encoding="utf-8")
    (DEMO_DIR / "current_session.txt").write_text(str(session) + "\n", encoding="utf-8")
    frame_file = DEMO_DIR / "current_frame.txt"

    print(f"Grabador activo → {session.name}")
    print(f"Puerto {PORT} | Anota con: python3 scripts/teach.py goal \"...\"")

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT))
    srv.listen(1)

    stop = threading.Event()

    def accept_loop() -> None:
        while not stop.is_set():
            try:
                srv.settimeout(1.0)
                conn, _ = srv.accept()
            except TimeoutError:
                continue
            except OSError:
                break
            with conn:
                buf = b""
                while not stop.is_set():
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    buf += chunk
                    while b"\n" in buf:
                        line, buf = buf.split(b"\n", 1)
                        if not line.strip():
                            continue
                        row = json.loads(line.decode("utf-8"))
                        with session.open("a", encoding="utf-8") as f:
                            f.write(json.dumps(row, ensure_ascii=False) + "\n")
                        frame_file.write_text(str(row.get("frame", 0)), encoding="utf-8")

    t = threading.Thread(target=accept_loop, daemon=True)
    t.start()

    try:
        import time
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        print("\nGrabador detenido.")
    finally:
        stop.set()
        srv.close()


if __name__ == "__main__":
    main()
