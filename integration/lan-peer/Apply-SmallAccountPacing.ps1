$ErrorActionPreference = 'Stop'

$auto = 'upstream/Mahjong.Plugin.Dalamud/Actions/AutoPlayLoop.cs'
$source = Get-Content $auto -Raw

# Small-account discard/call: fast human-independent pacing (instead of 400..2500 ms humanized delay).
$oldDelay = '        var delay = HumanTiming.RandomDelay(medianMs: medianDelayMs);'
$newDelay = @'
        bool smallFastAction = IsMultiplayerSmallAccount() && (label == "discard" || label == "call");
        var delay = smallFastAction
            ? HumanTiming.RandomDelay(medianMs: 90, sigma: 0.2, floorMs: 60, capMs: 160)
            : HumanTiming.RandomDelay(medianMs: medianDelayMs);
'@
if (-not $source.Contains('bool smallFastAction = IsMultiplayerSmallAccount()')) {
    if (-not $source.Contains($oldDelay)) { throw 'ScheduleAction delay anchor not found.' }
    $source = $source.Replace($oldDelay, $newDelay.TrimEnd())
}

# Discard/call bodies refresh the current addon snapshot and re-check legality before input.
# Do not silently abandon a small-account action merely because its aggregate revision advanced
# while the UI was animating during the short scheduler delay.
$oldRevisionGuard = @'
                    || (plugin.Aggregator.Latest?.HandId ?? 0) != scheduledHand
                    || (plugin.Aggregator.Latest?.Revision ?? 0) != scheduledRevision)
'@
$newRevisionGuard = @'
                    || (plugin.Aggregator.Latest?.HandId ?? 0) != scheduledHand
                    || (!(IsMultiplayerSmallAccount() && (label == "discard" || label == "call"))
                        && (plugin.Aggregator.Latest?.Revision ?? 0) != scheduledRevision))
'@
if (-not $source.Contains('!(IsMultiplayerSmallAccount() && (label == "discard" || label == "call"))')) {
    if (-not $source.Contains($oldRevisionGuard)) { throw 'ScheduleAction revision guard anchor not found.' }
    $source = $source.Replace($oldRevisionGuard, $newRevisionGuard)
}

# Use a shorter same-context debounce for small accounts so rapid turns are not skipped.
$oldCooldownCall = '            && fsm.ShouldSuppressForContext(context, clock.UtcNow))'
$newCooldownCall = '            && fsm.ShouldSuppressForContext(context, clock.UtcNow, IsMultiplayerSmallAccount() ? TimeSpan.FromMilliseconds(300) : null))'
if (-not $source.Contains($newCooldownCall)) {
    if (-not $source.Contains($oldCooldownCall)) { throw 'OnUpdate context cooldown anchor not found.' }
    $source = $source.Replace($oldCooldownCall, $newCooldownCall)
}

# Preserve physical red-five identity when locating the drawn tile's addon slot.
$oldSlot = '        int slot = plugin.AddonReader.FindAddonSlotOfTile(drawn);'
$newSlot = @'
        bool? drawnIsRed = snap.Observations.HasFlag(SnapshotObservationFlags.HandRedIdentity)
            && snap.HandIsRed.Count == snap.Hand.Count
                ? snap.HandIsRed[^1]
                : null;
        int slot = plugin.AddonReader.FindAddonSlotOfTile(drawn, drawnIsRed);
'@
if (-not $source.Contains('bool? drawnIsRed = snap.Observations.HasFlag')) {
    if (-not $source.Contains($oldSlot)) { throw 'Tsumogiri slot lookup anchor not found.' }
    $source = $source.Replace($oldSlot, $newSlot.TrimEnd())
}

Set-Content -Path $auto -Value $source -NoNewline

$fsm = 'upstream/Mahjong.Plugin.Game/ActionStateMachine.cs'
$state = Get-Content $fsm -Raw
$oldMethod = @'
    public bool ShouldSuppressForContext(DispatchContext context, DateTime now)
        => lastContext.HasValue
           && lastContext.Value.Equals(context)
           && now - lastActionAt < retryCooldown;
'@
$newMethod = @'
    public bool ShouldSuppressForContext(
        DispatchContext context, DateTime now, TimeSpan? overrideCooldown = null)
        => lastContext.HasValue
           && lastContext.Value.Equals(context)
           && now - lastActionAt < (overrideCooldown ?? retryCooldown);
'@
if (-not $state.Contains('TimeSpan? overrideCooldown = null')) {
    if (-not $state.Contains($oldMethod)) { throw 'ActionStateMachine cooldown method anchor not found.' }
    $state = $state.Replace($oldMethod, $newMethod)
    Set-Content -Path $fsm -Value $state -NoNewline
}

Write-Host 'Small-account pacing applied: 60-160ms action delay, live-state revalidation, 300ms context debounce and red-five-safe drawn-slot lookup.'
