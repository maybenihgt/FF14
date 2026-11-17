$ErrorActionPreference = 'Stop'

$path = 'upstream/Mahjong.Plugin.Dalamud/Actions/AutoPlayLoop.cs'
$source = Get-Content $path -Raw

$oldDelay = @'
        bool smallFastAction = IsMultiplayerSmallAccount() && (label == "discard" || label == "call");
        var delay = smallFastAction
            ? HumanTiming.RandomDelay(medianMs: 90, sigma: 0.2, floorMs: 60, capMs: 160)
            : HumanTiming.RandomDelay(medianMs: medianDelayMs);
'@
$newDelay = @'
        bool teamFastAction = (IsMultiplayerSmallAccount() || IsMultiplayerBigAccount())
            && (label == "discard" || label == "call");
        var delay = teamFastAction
            ? HumanTiming.RandomDelay(medianMs: 110, sigma: 0.2, floorMs: 70, capMs: 180)
            : HumanTiming.RandomDelay(medianMs: medianDelayMs);
'@
if (-not $source.Contains('bool teamFastAction = (IsMultiplayerSmallAccount() || IsMultiplayerBigAccount())')) {
    if (-not $source.Contains($oldDelay)) { throw 'Small-account-only delay block not found.' }
    $source = $source.Replace($oldDelay, $newDelay.TrimEnd())
}

$oldRevision = @'
                    || (!(IsMultiplayerSmallAccount() && (label == "discard" || label == "call"))
                        && (plugin.Aggregator.Latest?.Revision ?? 0) != scheduledRevision))
'@
$newRevision = @'
                    || (!((IsMultiplayerSmallAccount() || IsMultiplayerBigAccount())
                          && (label == "discard" || label == "call"))
                        && (plugin.Aggregator.Latest?.Revision ?? 0) != scheduledRevision))
'@
if (-not $source.Contains('!((IsMultiplayerSmallAccount() || IsMultiplayerBigAccount())')) {
    if (-not $source.Contains($oldRevision)) { throw 'Small-account-only revision guard not found.' }
    $source = $source.Replace($oldRevision, $newRevision)
}

$oldCooldown = 'fsm.ShouldSuppressForContext(context, clock.UtcNow, IsMultiplayerSmallAccount() ? TimeSpan.FromMilliseconds(300) : null)'
$newCooldown = 'fsm.ShouldSuppressForContext(context, clock.UtcNow, (IsMultiplayerSmallAccount() || IsMultiplayerBigAccount()) ? TimeSpan.FromMilliseconds(250) : null)'
if (-not $source.Contains($newCooldown)) {
    if (-not $source.Contains($oldCooldown)) { throw 'Small-account-only retry cooldown not found.' }
    $source = $source.Replace($oldCooldown, $newCooldown)
}

Set-Content -Path $path -Value $source -NoNewline
Write-Host 'Both big and small clients now use 70-180ms multiplayer discard/call pacing and a 250ms retry cooldown.'
