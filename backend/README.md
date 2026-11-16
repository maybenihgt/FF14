# Mortal backend bridge

This folder contains an HTTP adapter for the **standard four-player riichi-mahjong** Mortal bot. It does not contain Mortal source code or pretrained weights.

## Setup

1. Clone the upstream project: https://github.com/Equim-chan/Mortal
2. Follow its documented environment setup and obtain a valid pretrained checkpoint. Mortal's upstream README explains that weights are distributed separately; this repository does not redistribute them.
3. Set `MORTAL_DIR` to the upstream checkout, `MORTAL_CHECKPOINT` to the checkpoint file, and `MORTAL_CONFIG` to a Mortal config whose `control.state_file` points to that checkpoint.
4. Install upstream Python dependencies and the `libriichi` extension as documented upstream.
5. Run `python backend/mortal_bridge.py`.

The service listens on `127.0.0.1:8765` by default:
- `GET /health`
- `POST /v1/session/{session_id}/events` with `{"events":[MJAI event, ...]}`

The first batch must start with `start_game` and its `id` is the observer seat (0..3). Send subsequent events in chronological order. One request returns the last reaction produced by Mortal.

## Important

- This is an adapter, not a game-state reader. A client still has to capture the live table and send a complete, correctly ordered MJAI event stream.
- Mortal is for standard four-player Japanese riichi mahjong. It is not a Doman Mahjong rules engine.
- The upstream Mortal code is AGPL-3.0-or-later. This adapter communicates with it as a separate process; review AGPL obligations before distributing a combined product.
- Do not expose this unauthenticated local service to the public internet.
