$ErrorActionPreference = 'Stop'

$path = 'upstream/Mahjong.Plugin.Dalamud/Networking/LanPeerDiscovery.cs'
$source = Get-Content $path -Raw

$start = $source.IndexOf('    private static string ComputeMatchKey(StateSnapshot? snapshot)')
if ($start -lt 0) { throw 'ComputeMatchKey method not found.' }
$next = $source.IndexOf('    private async Task BroadcastLoopAsync', $start)
if ($next -lt 0) { throw 'ComputeMatchKey end marker not found.' }

$newMethod = @'
    private static string ComputeMatchKey(StateSnapshot? snapshot)
    {
        // The China-client candidate profile does not yet expose a verified MJAI
        // seat/dealer context. Do not require PublicStateConsistent or SeatInfo:
        // those flags are precisely what kept all four local clients at 0/4.
        if (snapshot is null ||
            snapshot.Hand.Count is not (13 or 14) ||
            snapshot.Scores.Count != 4 ||
            snapshot.Seats.Count != 4 ||
            snapshot.WallRemaining is < 0 or > 70)
            return string.Empty;

        // Score order is rotated around each local player, so canonicalize it.
        string scoreVector = string.Join(",", snapshot.Scores.Order());

        // Every viewpoint at the same table sees the same dora indicators and
        // live-wall count. These are available from the local Emj view even when
        // the protocol/MJAI stream is not admitted.
        string dora = string.Join(",", snapshot.DoraIndicators.Select(t => t.Id).Order());
        string value = string.Join("|",
            "doman-local-table-v2",
            snapshot.WallRemaining,
            scoreVector,
            dora);

        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    }

'@
$source = $source.Substring(0, $start) + $newMethod + $source.Substring($next)
Set-Content -Path $path -Value $source -NoNewline

# Allow private hand exchange when the China-client local snapshot is valid even
# though MJAI seat/dealer observations are not admitted. The seat wind is marked
# unknown (-1), not fabricated, and the table key still has to match all peers.
$handPath = 'upstream/Mahjong.Plugin.Dalamud/Networking/FourPlayerHandSync.cs'
$hand = Get-Content $handPath -Raw

$oldReady = @'
    private static bool IsReadySnapshot(StateSnapshot snapshot) =>
        snapshot.PublicStateConsistent &&
        snapshot.Hand.Count is 13 or 14 &&
        snapshot.HandIsRed.Count == snapshot.Hand.Count &&
        snapshot.Seats.Count == 4 &&
        snapshot.Scores.Count == 4 &&
        (snapshot.Observations & RequiredPublicObservations) == RequiredPublicObservations;
'@
$newReady = @'
    private static bool IsReadySnapshot(StateSnapshot snapshot) =>
        snapshot.Hand.Count is 13 or 14 &&
        snapshot.HandIsRed.Count == snapshot.Hand.Count;
'@
if (-not $hand.Contains($newReady)) {
    if (-not $hand.Contains($oldReady)) { throw 'HandSync ready-snapshot gate not found.' }
    $hand = $hand.Replace($oldReady, $newReady)
}

$oldLocalGate = @'
        if (snapshot is null || !IsReadySnapshot(snapshot) ||
            snapshot.SeatWind is not (>= 0 and <= 3) || string.IsNullOrEmpty(matchKey))
            return false;
'@
$newLocalGate = @'
        if (snapshot is null || !IsReadySnapshot(snapshot) || string.IsNullOrEmpty(matchKey))
            return false;
'@
if (-not $hand.Contains($newLocalGate)) {
    if (-not $hand.Contains($oldLocalGate)) { throw 'HandSync local snapshot gate not found.' }
    $hand = $hand.Replace($oldLocalGate, $newLocalGate)
}

$oldWind = '                            snapshot.SeatWind!.Value,'
$newWind = '                            snapshot.SeatWind ?? -1,'
if (-not $hand.Contains($newWind)) {
    if (-not $hand.Contains($oldWind)) { throw 'HandSync seat-wind packet field not found.' }
    $hand = $hand.Replace($oldWind, $newWind)
}

$oldValidation = '            frame.SeatWind is < 0 or > 3 || frame.RoundWind is < 0 or > 3 ||'
$newValidation = '            frame.SeatWind is < -1 or > 3 || frame.RoundWind is < 0 or > 3 ||'
if (-not $hand.Contains($newValidation)) {
    if (-not $hand.Contains($oldValidation)) { throw 'HandSync frame seat-wind validation not found.' }
    $hand = $hand.Replace($oldValidation, $newValidation)
}
Set-Content -Path $handPath -Value $hand -NoNewline

Write-Host 'Same-table identity and private hand exchange now work without MJAI seat metadata; unknown seat wind remains explicitly -1.'
