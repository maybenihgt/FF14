# Upstream reader integration

This integration builds the public source project as a separate upstream checkout:

- Repository: https://github.com/AinaSnow/FFXIV-AutoMahjongSolver
- Pinned revision: `6202b32fffa73b48f21050b884b96c55df5945f3`
- License: AGPL-3.0-or-later (see upstream `LICENSE.md`).

The upstream plugin contains the Dalamud addon reader, layout-profile decoder,
state aggregation, input dispatcher, and optional Mortal bridge. We build it
without copying its implementation into this repository.

## China-client candidate profile

`cn-candidate-layout.json` is a deliberately unverified candidate derived
from the upstream Japanese `EmjL` profile. It is included only to test whether
the China client exposes the same addon name and memory layout. It is **not**
evidence of China-client compatibility. The plugin's probe must match the
addon structure before it can select the profile.

Initial test must use **Off / Hints** only. Do not enable Auto-play until hand,
scores, discards, melds, dora, and legal actions have been checked against the
in-game UI over multiple complete rounds. If the candidate does not match,
capture `/mjauto variant dump` and the addon diagnostic output; do not guess
new offsets.

## Build

The workflow checks out the pinned upstream source, overlays the candidate
profile, installs the upstream pinned Dalamud and Deucalion dependencies, and
builds the plugin. The artifact is an upstream-based test build, not a claim
that the China client has been verified.


### Build compatibility patch

The CI build excludes `Mahjong.Plugin.Dalamud/GameState/EmjTableReader.cs` from the pinned upstream checkout because it references an `FFXIVClientStructs.FFXIV.Client.Game.Emj` namespace absent from the pinned Dalamud SDK. This optional diagnostic probe is not part of the live addon-reader path. The exclusion is CI-only and does not modify the upstream repository or the main branch.
