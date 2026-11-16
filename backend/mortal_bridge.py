#!/usr/bin/env python3
"""Local HTTP bridge for Mortal's MJAI stdin/stdout protocol.

The game adapter must send a complete, ordered MJAI event stream. This service
never fabricates game state and never sends game inputs to FFXIV.
"""
from __future__ import annotations

import json
import os
import queue
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

MORTAL_DIR = Path(os.environ.get("MORTAL_DIR", "./Mortal")).resolve()
CHECKPOINT = Path(os.environ.get("MORTAL_CHECKPOINT", "./mortal.pth")).resolve()
CONFIG = Path(os.environ.get("MORTAL_CONFIG", "./config.toml")).resolve()
PYTHON = os.environ.get("MORTAL_PYTHON", "python")
HOST = os.environ.get("MAHJONG_AI_HOST", "127.0.0.1")
PORT = int(os.environ.get("MAHJONG_AI_PORT", "8765"))
RESPONSE_TIMEOUT = float(os.environ.get("MORTAL_RESPONSE_TIMEOUT", "8"))
MAX_BODY = 2 * 1024 * 1024

sessions: dict[str, "Session"] = {}
sessions_lock = threading.RLock()


class Session:
    """One persistent Mortal process per MJAI game; stdout is drained asynchronously."""

    def __init__(self, seat: int):
        env = os.environ.copy()
        # Mortal reads MORTAL_CFG (not MORTAL_CONFIG) in mortal/config.py.
        env["MORTAL_CFG"] = str(CONFIG)
        env.pop("MORTAL_REVIEW_MODE", None)
        self.output: queue.Queue[str | None] = queue.Queue()
        self.lock = threading.Lock()
        self.proc = subprocess.Popen(
            [PYTHON, "mortal.py", str(seat)],
            cwd=MORTAL_DIR,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            bufsize=1,
            env=env,
        )
        self.reader = threading.Thread(target=self._read_stdout, daemon=True)
        self.reader.start()

    def _read_stdout(self):
        assert self.proc.stdout is not None
        try:
            for line in self.proc.stdout:
                line = line.strip()
                if line:
                    self.output.put(line)
        finally:
            self.output.put(None)

    def send(self, events: list[dict]) -> dict:
        with self.lock:
            if self.proc.poll() is not None:
                raise RuntimeError("Mortal process exited; reset this session")
            assert self.proc.stdin is not None
            for event in events:
                self.proc.stdin.write(json.dumps(event, separators=(",", ":"), ensure_ascii=False) + "\n")
            self.proc.stdin.flush()

            # Mortal emits output only when an event produces a reaction.
            # Wait briefly; do not block the Dalamud plugin indefinitely.
            try:
                line = self.output.get(timeout=RESPONSE_TIMEOUT)
            except queue.Empty:
                return {"type": "none", "reason": "no_reaction_before_timeout"}
            if line is None:
                raise RuntimeError("Mortal closed stdout; verify its checkpoint and config")
            try:
                return json.loads(line)
            except json.JSONDecodeError as exc:
                raise RuntimeError(f"Invalid JSON from Mortal: {line[:200]}") from exc

    def close(self):
        with self.lock:
            if self.proc.poll() is None:
                try:
                    if self.proc.stdin:
                        self.proc.stdin.close()
                except OSError:
                    pass
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait(timeout=2)


class ApiHandler(BaseHTTPRequestHandler):
    server_version = "MahjongMortalBridge/0.2"

    def _reply(self, status: int, value: dict):
        data = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _read_json(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            raise ValueError("invalid Content-Length")
        if length <= 0 or length > MAX_BODY:
            raise ValueError(f"request body must be between 1 and {MAX_BODY} bytes")
        value = json.loads(self.rfile.read(length))
        if not isinstance(value, dict):
            raise ValueError("JSON body must be an object")
        return value

    def do_GET(self):
        if urlparse(self.path).path != "/health":
            return self._reply(404, {"error": "not_found"})
        source_ok = (MORTAL_DIR / "mortal.py").is_file()
        config_ok = CONFIG.is_file()
        checkpoint_ok = CHECKPOINT.is_file()
        ready = source_ok and config_ok and checkpoint_ok
        return self._reply(200 if ready else 503, {
            "status": "ready" if ready else "not_ready",
            "mortal_source": source_ok,
            "config_present": config_ok,
            "checkpoint_present": checkpoint_ok,
            "response_timeout_seconds": RESPONSE_TIMEOUT,
        })

    def do_POST(self):
        parts = urlparse(self.path).path.strip("/").split("/")
        if len(parts) != 4 or parts[:2] != ["v1", "session"] or parts[3] != "events":
            return self._reply(404, {"error": "expected /v1/session/{id}/events"})
        sid = parts[2]
        if not sid or len(sid) > 96:
            return self._reply(400, {"error": "invalid session id"})
        try:
            body = self._read_json()
            events = body.get("events")
            if not isinstance(events, list) or not events:
                return self._reply(400, {"error": "events must be a non-empty array"})
            if any(not isinstance(event, dict) or not isinstance(event.get("type"), str) for event in events):
                return self._reply(400, {"error": "each event must be an MJAI object with a string type"})

            with sessions_lock:
                session = sessions.get(sid)
                if session is None:
                    first = events[0]
                    if first.get("type") != "start_game":
                        return self._reply(409, {"error": "first event must be start_game"})
                    seat = first.get("id")
                    if not isinstance(seat, int) or seat not in range(4):
                        return self._reply(400, {"error": "start_game.id must be 0..3"})
                    session = Session(seat)
                    sessions[sid] = session

            reaction = session.send(events)
            return self._reply(200, {"reaction": reaction, "engine": "Mortal"})
        except (ValueError, json.JSONDecodeError) as exc:
            return self._reply(400, {"error": str(exc)})
        except Exception as exc:
            with sessions_lock:
                failed = sessions.pop(sid, None)
            if failed:
                failed.close()
            return self._reply(502, {"error": str(exc)})

    def do_DELETE(self):
        parts = urlparse(self.path).path.strip("/").split("/")
        if len(parts) != 3 or parts[:2] != ["v1", "session"]:
            return self._reply(404, {"error": "expected /v1/session/{id}"})
        with sessions_lock:
            session = sessions.pop(parts[2], None)
        if session:
            session.close()
        return self._reply(200, {"closed": session is not None})

    def log_message(self, *_):
        pass


def main():
    if not (MORTAL_DIR / "mortal.py").is_file():
        raise SystemExit("Set MORTAL_DIR to a checked-out Equim-chan/Mortal directory")
    if not CONFIG.is_file():
        raise SystemExit("Set MORTAL_CONFIG to a valid Mortal config.toml")
    if not CHECKPOINT.is_file():
        raise SystemExit("Set MORTAL_CHECKPOINT to a valid Mortal checkpoint (.pth)")
    server = ThreadingHTTPServer((HOST, PORT), ApiHandler)
    print(f"Mortal bridge listening on http://{HOST}:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        with sessions_lock:
            active = list(sessions.values())
            sessions.clear()
        for session in active:
            session.close()


if __name__ == "__main__":
    main()
