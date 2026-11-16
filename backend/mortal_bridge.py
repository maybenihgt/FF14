#!/usr/bin/env python3
"""Local HTTP bridge for the official Mortal MJAI command-line bot.

POST /v1/session/{id}/events with {"events":[{...}, ...]}.
The first event must be start_game and contain the observer seat in id.
Requires an independently obtained Mortal checkpoint and Mortal source tree.
"""
from __future__ import annotations
import json, os, subprocess, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

MORTAL_DIR = Path(os.environ.get("MORTAL_DIR", "./Mortal")).resolve()
CHECKPOINT = Path(os.environ.get("MORTAL_CHECKPOINT", "./mortal.pth")).resolve()
CONFIG = Path(os.environ.get("MORTAL_CONFIG", "./config.toml")).resolve()
HOST = os.environ.get("MAHJONG_AI_HOST", "127.0.0.1")
PORT = int(os.environ.get("MAHJONG_AI_PORT", "8765"))
sessions = {}
lock = threading.RLock()

class Session:
    def __init__(self, sid: str, seat: int):
        env = os.environ.copy()
        env["MORTAL_CONFIG"] = str(CONFIG)
        self.proc = subprocess.Popen(
            ["python", "mortal.py", str(seat)], cwd=MORTAL_DIR,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1, env=env
        )
        self.lock = threading.Lock()

    def send(self, events):
        replies = []
        with self.lock:
            if self.proc.poll() is not None:
                raise RuntimeError("Mortal process exited; create a new session")
            for event in events:
                self.proc.stdin.write(json.dumps(event, separators=(",", ":")) + "\n")
                self.proc.stdin.flush()
                line = self.proc.stdout.readline()
                if not line:
                    raise RuntimeError("Mortal returned no reaction; check checkpoint/config")
                replies.append(json.loads(line))
        return replies[-1] if replies else {"type":"none"}

    def close(self):
        with self.lock:
            if self.proc.poll() is None:
                self.proc.stdin.close()
                self.proc.terminate()
                try: self.proc.wait(timeout=2)
                except subprocess.TimeoutExpired: self.proc.kill()

class Handler(BaseHTTPRequestHandler):
    def reply(self, status, value):
        data = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            ready = MORTAL_DIR.joinpath("mortal.py").exists() and CHECKPOINT.exists()
            return self.reply(200 if ready else 503, {
                "status": "ready" if ready else "missing_model_or_source",
                "mortal_dir": str(MORTAL_DIR), "checkpoint_present": CHECKPOINT.exists()
            })
        self.reply(404, {"error":"not_found"})

    def do_POST(self):
        route = urlparse(self.path).path.strip("/").split("/")
        if len(route) != 3 or route[0] != "v1" or route[1] != "session" or route[2] in ("", "events"):
            return self.reply(404, {"error":"expected /v1/session/{id}/events"})
        # Accept canonical path /v1/session/{id}/events (four segments).
        self.reply(404, {"error":"expected /v1/session/{id}/events"})

    def log_message(self, *_): pass

class ApiHandler(Handler):
    def do_POST(self):
        parts = urlparse(self.path).path.strip("/").split("/")
        if len(parts) != 4 or parts[0:2] != ["v1","session"] or parts[3] != "events":
            return self.reply(404, {"error":"expected /v1/session/{id}/events"})
        sid = parts[2]
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length","0"))))
            events = body.get("events", [])
            if not isinstance(events, list) or not events:
                return self.reply(400, {"error":"events must be a non-empty array"})
            with lock:
                session = sessions.get(sid)
                if session is None:
                    first = events[0]
                    if first.get("type") != "start_game":
                        return self.reply(409, {"error":"first event must be start_game"})
                    seat = int(first.get("id", -1))
                    if seat not in range(4):
                        return self.reply(400, {"error":"start_game.id must be 0..3"})
                    session = sessions[sid] = Session(sid, seat)
            result = session.send(events)
            self.reply(200, {"reaction": result, "engine":"Mortal"})
        except Exception as exc:
            self.reply(500, {"error":str(exc)})

def main():
    if not MORTAL_DIR.joinpath("mortal.py").exists():
        raise SystemExit("Set MORTAL_DIR to a checked-out Equim-chan/Mortal directory")
    if not CHECKPOINT.exists():
        raise SystemExit("Set MORTAL_CHECKPOINT to a valid Mortal checkpoint (.pth)")
    server = ThreadingHTTPServer((HOST, PORT), ApiHandler)
    print(f"Mortal bridge listening on http://{HOST}:{PORT}")
    try: server.serve_forever()
    except KeyboardInterrupt: pass
    finally:
        server.server_close()
        for session in sessions.values(): session.close()

if __name__ == "__main__":
    main()
