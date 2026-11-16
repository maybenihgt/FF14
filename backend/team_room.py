#!/usr/bin/env python3
"""Consent-gated 2v2 mahjong analysis rooms for sandbox/replay sessions only.

This relay is deliberately not a game client, packet reader, or input dispatcher.
It accepts only self-reported snapshots from four opted-in participants and
keeps all room state in memory with a short TTL.
"""
from __future__ import annotations

import json
import os
import secrets
import threading
import time
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

HOST = os.environ.get("TEAM_ROOM_HOST", "127.0.0.1")
PORT = int(os.environ.get("TEAM_ROOM_PORT", "8770"))
ROOM_TTL = int(os.environ.get("TEAM_ROOM_TTL_SECONDS", "7200"))
MAX_BODY = 256 * 1024
MAX_ROOMS = 100


@dataclass
class Participant:
    name: str
    team: str
    token: str
    consent: bool = False
    snapshot: dict | None = None
    updated_at: float = 0.0


@dataclass
class Room:
    room_id: str
    invite_code: str
    mode: str
    created_at: float
    participants: dict[str, Participant] = field(default_factory=dict)


rooms: dict[str, Room] = {}
lock = threading.RLock()


def clean_expired() -> None:
    cutoff = time.time() - ROOM_TTL
    for room_id in [key for key, room in rooms.items() if room.created_at < cutoff]:
        del rooms[room_id]


def public_room(room: Room, reveal_snapshots: bool) -> dict:
    members = []
    for participant in room.participants.values():
        item = {
            "name": participant.name,
            "team": participant.team,
            "consent": participant.consent,
            "has_snapshot": participant.snapshot is not None,
            "updated_at": participant.updated_at or None,
        }
        if reveal_snapshots and participant.snapshot is not None:
            item["snapshot"] = participant.snapshot
        members.append(item)
    return {
        "room_id": room.room_id,
        "mode": room.mode,
        "status": "ready" if len(members) == 4 and all(p.consent for p in room.participants.values()) else "waiting_for_consent_or_players",
        "team_counts": {
            "A": sum(p.team == "A" for p in room.participants.values()),
            "B": sum(p.team == "B" for p in room.participants.values()),
        },
        "participants": members,
        "snapshots_visible": reveal_snapshots,
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "MahjongTeamRoom/0.1"

    def reply(self, status: int, value: dict) -> None:
        payload = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def body(self) -> dict:
        try:
            size = int(self.headers.get("Content-Length", "0"))
        except ValueError as exc:
            raise ValueError("invalid Content-Length") from exc
        if size <= 0 or size > MAX_BODY:
            raise ValueError(f"body must be 1..{MAX_BODY} bytes")
        value = json.loads(self.rfile.read(size))
        if not isinstance(value, dict):
            raise ValueError("JSON body must be an object")
        return value

    def auth(self, room: Room) -> Participant | None:
        token = self.headers.get("Authorization", "").removeprefix("Bearer ").strip()
        return next((p for p in room.participants.values() if secrets.compare_digest(p.token, token)), None)

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/health":
            return self.reply(200, {"status": "ok", "mode": "sandbox/replay-only", "rooms_in_memory": len(rooms)})
        parts = path.strip("/").split("/")
        if len(parts) != 3 or parts[:2] != ["v1", "team-rooms"]:
            return self.reply(404, {"error": "not_found"})
        with lock:
            clean_expired()
            room = rooms.get(parts[2])
            if room is None:
                return self.reply(404, {"error": "room_not_found"})
            participant = self.auth(room)
            if participant is None:
                return self.reply(401, {"error": "participant_token_required"})
            ready = len(room.participants) == 4 and all(p.consent for p in room.participants.values())
            return self.reply(200, public_room(room, reveal_snapshots=ready))

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        try:
            data = self.body()
            with lock:
                clean_expired()
                if path == "/v1/team-rooms":
                    if data.get("mode") not in ("sandbox", "replay"):
                        return self.reply(400, {"error": "mode_must_be_sandbox_or_replay"})
                    if data.get("consent") is not True:
                        return self.reply(400, {"error": "creator_must_explicitly_consent"})
                    if len(rooms) >= MAX_ROOMS:
                        return self.reply(503, {"error": "room_capacity_reached"})
                    name = str(data.get("name", "")).strip()[:40]
                    team = data.get("team")
                    if not name or team not in ("A", "B"):
                        return self.reply(400, {"error": "name_and_team_A_or_B_required"})
                    room_id = secrets.token_urlsafe(9)
                    invite = secrets.token_urlsafe(18)
                    token = secrets.token_urlsafe(32)
                    room = Room(room_id, invite, data["mode"], time.time())
                    room.participants[token[:12]] = Participant(name, team, token, True)
                    rooms[room_id] = room
                    return self.reply(201, {"room_id": room_id, "invite_code": invite, "participant_token": token,
                                            "mode": room.mode, "note": "Share invite_code only with the other three consenting sandbox/replay participants."})

                parts = path.strip("/").split("/")
                if len(parts) == 4 and parts[:2] == ["v1", "team-rooms"]:
                    room = rooms.get(parts[2])
                    if room is None:
                        return self.reply(404, {"error": "room_not_found"})
                    action = parts[3]
                    if action == "join":
                        if not secrets.compare_digest(str(data.get("invite_code", "")), room.invite_code):
                            return self.reply(403, {"error": "invalid_invite_code"})
                        if data.get("consent") is not True:
                            return self.reply(400, {"error": "explicit_consent_required"})
                        name = str(data.get("name", "")).strip()[:40]
                        team = data.get("team")
                        if not name or team not in ("A", "B"):
                            return self.reply(400, {"error": "name_and_team_A_or_B_required"})
                        if len(room.participants) >= 4:
                            return self.reply(409, {"error": "room_full"})
                        if sum(p.team == team for p in room.participants.values()) >= 2:
                            return self.reply(409, {"error": "team_full"})
                        if any(p.name.casefold() == name.casefold() for p in room.participants.values()):
                            return self.reply(409, {"error": "participant_name_already_used"})
                        token = secrets.token_urlsafe(32)
                        room.participants[token[:12]] = Participant(name, team, token, True)
                        return self.reply(201, {"room_id": room.room_id, "participant_token": token, "team": team})

                    participant = self.auth(room)
                    if participant is None:
                        return self.reply(401, {"error": "participant_token_required"})
                    if action == "consent":
                        if data.get("consent") is not True:
                            return self.reply(400, {"error": "consent_cannot_be_withdrawn_via_this_endpoint; leave_or_delete_room"})
                        participant.consent = True
                        return self.reply(200, {"consent": True})
                    if action == "snapshot":
                        if not participant.consent:
                            return self.reply(403, {"error": "consent_required"})
                        snapshot = data.get("snapshot")
                        if not isinstance(snapshot, dict):
                            return self.reply(400, {"error": "snapshot_object_required"})
                        encoded = json.dumps(snapshot, ensure_ascii=False)
                        if len(encoded.encode("utf-8")) > MAX_BODY // 2:
                            return self.reply(413, {"error": "snapshot_too_large"})
                        participant.snapshot = snapshot
                        participant.updated_at = time.time()
                        ready = len(room.participants) == 4 and all(p.consent for p in room.participants.values())
                        return self.reply(202, {"accepted": True, "team_snapshots_visible": ready})
                    if action == "leave":
                        room.participants.pop(participant.token[:12], None)
                        if not room.participants:
                            rooms.pop(room.room_id, None)
                        return self.reply(200, {"left": True})
                return self.reply(404, {"error": "not_found"})
        except (ValueError, json.JSONDecodeError) as exc:
            return self.reply(400, {"error": str(exc)})

    def log_message(self, *_):
        pass


def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Team analysis relay listening on http://{HOST}:{PORT} (sandbox/replay only)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
