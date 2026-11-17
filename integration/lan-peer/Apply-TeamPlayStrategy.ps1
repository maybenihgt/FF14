$ErrorActionPreference = 'Stop'

$auto = 'upstream/Mahjong.Plugin.Dalamud/Actions/AutoPlayLoop.cs'
$source = Get-Content $auto -Raw

$helperMarker = '    private StateSnapshot? ResolvePendingTerminalWin(StateSnapshot? current, DateTime now)'
$helper = @'
    private bool IsMultiplayerSmallAccount() =>
        plugin.Configuration.LanPeerDiscoveryEnabled && plugin.Configuration.LanPeerAccountType == "小号";

    private bool IsMultiplayerBigAccount() =>
        plugin.Configuration.LanPeerDiscoveryEnabled && plugin.Configuration.LanPeerAccountType == "大号";

    private bool TryChoosePrivateQuickWinDiscard(StateSnapshot snapshot, out ActionChoice choice)
    {
        choice = ActionChoice.Pass("private quick-win: no scored discard available");
        if (!plugin.HandSync.IsPrivateFourAccountTable || !snapshot.Legal.Can(ActionFlags.Discard))
            return false;

        var candidates = plugin.Aggregator.LastScored;
        if (candidates is not { Length: > 0 })
            return false;

        var best = candidates
            .Where(x => snapshot.Hand.Contains(x.Discard) && snapshot.Legal.AllowsDiscard(x.Discard))
            .OrderBy(x => x.ShantenAfter)
            .ThenByDescending(x => x.UkeireWeighted)
            .ThenByDescending(x => x.UkeireKinds)
            .ThenByDescending(x => x.YakuPotential)
            .ThenByDescending(x => x.Score)
            .FirstOrDefault();

        if (!snapshot.Hand.Contains(best.Discard) || !snapshot.Legal.AllowsDiscard(best.Discard))
            return false;

        choice = ActionChoice.Discard(
            best.Discard,
            $"private quick-win: shanten={best.ShantenAfter}, ukeire={best.UkeireWeighted}, yaku={best.YakuPotential:0.##}",
            DiscardIsRed: best.IsRed);
        return true;
    }

'@
if (-not $source.Contains('private bool IsMultiplayerSmallAccount()')) {
    if (-not $source.Contains($helperMarker)) { throw 'AutoPlayLoop helper insertion marker not found.' }
    $source = $source.Replace($helperMarker, $helper + $helperMarker)
}

# Small accounts always tsumogiri on their own discard turn; they never use the hand scorer.
$discardAnchor = @'
            if (!TryChoose(snap, out var choice))
            {
                LastActionDescription = "waiting for Mortal discard";
                fsm.ClearContext();
                return;
            }
'@
$discardReplacement = @'
            if (IsMultiplayerSmallAccount())
            {
                DispatchOutOfSyncTsumogiri(snap, ActionChoice.Pass("small account: forced tsumogiri; never pursue a win"));
                return;
            }

            if (!TryChoose(snap, out var choice))
            {
                LastActionDescription = "waiting for Mortal discard";
                fsm.ClearContext();
                return;
            }
'@
if (-not $source.Contains('small account: forced tsumogiri')) {
    if (-not $source.Contains($discardAnchor)) { throw 'ScheduleDiscard policy selection anchor not found.' }
    $source = $source.Replace($discardAnchor, $discardReplacement)
}

# Small accounts pass every offer, including Ron/Tsumo, Pon/Chi/Kan and Riichi.
$callAnchor = @'
            if (!TryChoose(snap, out var choice))
            {
                LastActionDescription = "waiting for Mortal call decision";
                fsm.ClearContext();
                return;
            }
'@
$callReplacement = @'
            if (IsMultiplayerSmallAccount())
            {
                var smallPass = ActionChoice.Pass("small account: do not win, call or declare riichi");
                EmitDecisionFinding("small-account-pass", snap, smallPass);
                DispatchCallChoice(snap, smallPass);
                return;
            }

            if (!TryChoose(snap, out var choice))
            {
                LastActionDescription = "waiting for Mortal call decision";
                fsm.ClearContext();
                return;
            }
'@
if (-not $source.Contains('small account: do not win, call or declare riichi')) {
    if (-not $source.Contains($callAnchor)) { throw 'ScheduleCallDecision policy selection anchor not found.' }
    $source = $source.Replace($callAnchor, $callReplacement)
}

# Big accounts take any currently legal win immediately; a private table uses a quick-win discard ordering.
$chooseMarker = '        if (snapshot.Legal.Can(ActionFlags.Ron) && plugin.MortalBridge.HasExpiredReactionWindow(snapshot))'
$bigStrategy = @'
        if (IsMultiplayerBigAccount())
        {
            if (snapshot.Legal.Can(ActionFlags.Tsumo))
            {
                choice = ActionChoice.DeclareTsumo("big account: accept any legal win");
                hasMortalWait = false;
                plugin.Aggregator.PublishLocalExecution(snapshot, choice, "team-fast-win");
                return true;
            }
            if (snapshot.Legal.Can(ActionFlags.Ron) && !plugin.MortalBridge.HasExpiredReactionWindow(snapshot))
            {
                choice = ActionChoice.DeclareRon("big account: accept any legal win");
                hasMortalWait = false;
                plugin.Aggregator.PublishLocalExecution(snapshot, choice, "team-fast-win");
                return true;
            }
            if (plugin.HandSync.IsPrivateFourAccountTable &&
                TryChoosePrivateQuickWinDiscard(snapshot, out choice))
            {
                hasMortalWait = false;
                plugin.Aggregator.PublishLocalExecution(snapshot, choice, "private-quick-win");
                return true;
            }
        }

'@
if (-not $source.Contains('big account: accept any legal win')) {
    if (-not $source.Contains($chooseMarker)) { throw 'TryChoose big-account strategy insertion point not found.' }
    $source = $source.Replace($chooseMarker, $bigStrategy + $chooseMarker)
}

Set-Content -Path $auto -Value $source -NoNewline
Write-Host 'Team play strategy applied: small=pass offers and tsumogiri; big=take legal wins; private four-account bigs=lowest shanten / highest ukeire.'
