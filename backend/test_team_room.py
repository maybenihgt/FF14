import json
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

from backend import team_room


class TeamRoomApiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), team_room.Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)

    def setUp(self):
        with team_room.lock:
            team_room.rooms.clear()

    def request(self, path, payload=None, token=None):
        data = None if payload is None else json.dumps(payload).encode()
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        req = urllib.request.Request(self.base + path, data=data, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=2) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read())

    def make_room(self):
        status, owner = self.request("/v1/team-rooms", {
            "mode": "sandbox", "name": "A1", "team": "A", "consent": True
        })
        self.assertEqual(status, 201)
        return owner

    def join(self, room, name, team):
        return self.request(f"/v1/team-rooms/{room['room_id']}/join", {
            "invite_code": room["invite_code"], "name": name,
            "team": team, "consent": True
        })

    def test_rejects_live_mode(self):
        status, body = self.request("/v1/team-rooms", {
            "mode": "live", "name": "A1", "team": "A", "consent": True
        })
        self.assertEqual(status, 400)
        self.assertEqual(body["error"], "mode_must_be_sandbox_or_replay")

    def test_snapshots_hidden_until_four_explicit_consents(self):
        owner = self.make_room()
        status, _ = self.request(
            f"/v1/team-rooms/{owner['room_id']}/snapshot",
            {"snapshot": {"hand": ["1m"]}}, owner["participant_token"])
        self.assertEqual(status, 202)

        _, a2 = self.join(owner, "A2", "A")
        _, b1 = self.join(owner, "B1", "B")
        self.assertIn("participant_token", a2)
        self.assertIn("participant_token", b1)

        status, room = self.request(
            f"/v1/team-rooms/{owner['room_id']}", token=owner["participant_token"])
        self.assertEqual(status, 200)
        self.assertFalse(room["snapshots_visible"])
        self.assertNotIn("snapshot", room["participants"][0])

        _, b2 = self.join(owner, "B2", "B")
        self.assertIn("participant_token", b2)
        status, room = self.request(
            f"/v1/team-rooms/{owner['room_id']}", token=owner["participant_token"])
        self.assertEqual(status, 200)
        self.assertTrue(room["snapshots_visible"])
        self.assertEqual(room["participants"][0]["snapshot"]["hand"], ["1m"])

    def test_requires_token_to_read_room(self):
        owner = self.make_room()
        status, body = self.request(f"/v1/team-rooms/{owner['room_id']}")
        self.assertEqual(status, 401)
        self.assertEqual(body["error"], "participant_token_required")

    def test_enforces_two_members_per_team(self):
        owner = self.make_room()
        self.assertEqual(self.join(owner, "A2", "A")[0], 201)
        self.assertEqual(self.join(owner, "A3", "A")[0], 409)


if __name__ == "__main__":
    unittest.main()
