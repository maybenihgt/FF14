# UU LAN Peer Discovery Test Build

This overlay adds presence discovery for plugin instances connected to the same IPv4 virtual LAN.

## What it exchanges

Only these fields are broadcast:
- random plugin-instance ID (rotates when plugin reloads)
- local account label: MAIN_A, MAIN_B, ALT_C, ALT_D, or UNASSIGNED
- plugin version
- timestamp and HMAC authentication

It does **not** send or receive game hands, tiles, discards, scores, opponents, board state, game actions, or ranking instructions. Each plugin continues to analyze only its own local client.

## Test setup

1. Install this same test build on at least two PCs connected to the same UU virtual LAN.
2. Open the plugin and find the **UU LAN peers / UU 局域网节点** card.
3. On one PC, choose **Generate and copy room code**.
4. Paste the same room code into the card on every other PC. Use at least 12 characters.
5. Assign a local label (MAIN_A / MAIN_B / ALT_C / ALT_D) on each PC.
6. Enable **Enable peer discovery** on each PC.
7. Allow inbound UDP port **47721** on the Windows **Private** firewall profile.
8. Wait a few seconds. Each PC should list the other active plugin instances and their virtual-LAN IP addresses.

The plugin sends an authenticated IPv4 broadcast every two seconds. Entries expire after eight seconds without a heartbeat. The room code is never transmitted; packets are authenticated with HMAC-SHA256.

## Troubleshooting

- Check that the PCs are in the same UU virtual LAN room.
- Confirm that each PC has the exact same room code.
- Confirm UDP 47721 inbound is permitted by Windows Defender Firewall.
- Some VPN/virtual-LAN adapters do not forward broadcast traffic. If the two PCs can ping each other but do not discover peers, this first test build may need a unicast fallback.
- The LAN feature is disabled by default and does not change the plugin's Off / Hints / Auto-play selection.

## Scope

This is an experimental connectivity test, not proof that UU exposes game memory or another player's private game data. Peer discovery only shows other plugin instances that opted into the same room code.
