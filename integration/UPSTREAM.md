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


## Call-prompt safety patch

The CI overlay also applies two conservative changes to the pinned upstream source:

- If the live call-list reader returns no enabled rows, the reader falls back to visible AtkValues action labels; call-prompt state 28 is included in diagnostics.
- If Mortal times out on a Pon/Chi/MinKan reaction without an authoritative opponent-discard event, automation is disarmed instead of sending a Pass. The player must resolve that prompt manually.

This is a safety and detection improvement, not proof that every China-client Chi/Pon/Kan option is decoded. Verify the prompt and action index against a live `/mjauto variant dump` and call-prompt capture before re-enabling Auto-play.


## Simplified Chinese Emj dump findings (2026-11-16)

A user-provided live dump reports `Client language: ChineseSimplified` and resolved addon `Emj` (not `EmjL`). The candidate layout now matches both fields so `VariantSelector` scores it above the generic Emj profile. The same dump places the live action labels at AtkValues indexes 30–36 (`碰！`, `吃！`, `杠！`, `立直！`, `自摸！`, `和牌！`, `听牌！`), while the upstream default scan limit was 20. The CN candidate scan limit is now 50 (the dump has 50 values) and exact full-width punctuation aliases are included.

The intended user mode is automatic discard assistance with manual user choice at call prompts; do not force an automatic Chi/Pon/Kan selection. The game prompt should remain available for the user to click. Build success only confirms compile/package; in-game call-prompt and win recognition still require replay testing against the captured dump and fresh live prompts.


## Continuous auto-queue manual opt-in

On every plugin load, startup configuration initialization resets `ContinuousCollection` to false before the collection loop is constructed. The queue loop therefore stays idle after launching/reloading the plugin until the user explicitly checks the `Auto-queue, commence and repeat until stopped` checkbox. Checking it still invokes the existing `Collection.Start()` flow; unchecking invokes `Stop()`. The settings hint now states that it will not auto-start after reload.


## Hide unused local-capture settings UI

The CN candidate build removes the SettingsWindow cards for Debug packet logger, Memory snapshots, and Training data archive. Their internal services and configuration fields remain for source compatibility but are not user-configurable from this build's normal settings UI; privacy-sensitive options stay disabled by default. Existing files in `debug-packets`, `memdumps`, and `training-data` are not automatically deleted when recording is disabled or the UI is hidden. The user may manually delete old files after closing the game/plugin if they no longer want them.
