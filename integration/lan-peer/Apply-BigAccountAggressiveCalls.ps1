$ErrorActionPreference = 'Stop'

$callPolicyPath = 'upstream/Mahjong.Policy/Efficiency/EnhancedCallPolicy.cs'
$callPolicy = Get-Content $callPolicyPath -Raw

$oldBefore = @'
        var options = new List<(MeldCandidate Call,int Shanten,int Waits)>();
        foreach (var call in state.Legal.PonCandidates.Concat(state.Legal.ChiCandidates).Concat(state.Legal.KanCandidates))
'@
$newBefore = @'
        var wall = DiscardScorer.BuildVisibleWall(state);
        // Baseline effective tiles in the current 13-tile hand: count draws that
        // strictly reduce shanten. Compare this with the best post-call discard.
        int beforeUkeire = CountImprovingUkeire(state.Hand, state.OurMelds.Count, before, wall);
        var options = new List<(MeldCandidate Call,int Shanten,int Waits)>();
        foreach (var call in state.Legal.PonCandidates.Concat(state.Legal.ChiCandidates).Concat(state.Legal.KanCandidates))
'@
if (-not $callPolicy.Contains('int beforeUkeire = CountImprovingUkeire')) {
    if (-not $callPolicy.Contains($oldBefore)) { throw 'EnhancedCallPolicy baseline insertion point not found.' }
    $callPolicy = $callPolicy.Replace($oldBefore, $newBefore)
}

$oldChoices = @'
                var choices=UkeireEnumerator.Enumerate(Hand.FromTiles(hand,melds),DiscardScorer.BuildVisibleWall(state))
                    .Where(c=>!forbidden.Contains(c.Discard))
                    .OrderBy(c=>c.ShantenAfter).ThenByDescending(c=>c.WeightedCount).ToArray();
'@
$newChoices = @'
                var choices=UkeireEnumerator.Enumerate(Hand.FromTiles(hand,melds),wall)
                    .Where(c=>!forbidden.Contains(c.Discard))
                    .OrderBy(c=>c.ShantenAfter).ThenByDescending(c=>c.WeightedCount).ToArray();
'@
if (-not $callPolicy.Contains($newChoices)) {
    if (-not $callPolicy.Contains($oldChoices)) { throw 'EnhancedCallPolicy post-call ukeire insertion point not found.' }
    $callPolicy = $callPolicy.Replace($oldChoices, $newChoices)
}

$oldAccept = '            if(shanten<before || (kan && stillClosed && shanten==before)) options.Add((call,shanten,waits));'
$newAccept = @'
            int minimumUkeireGain = Math.Max(2, (int)Math.Ceiling(beforeUkeire * 0.10));
            bool improvesShanten = shanten < before;
            bool improvesSameShantenEfficiency = shanten == before && waits >= beforeUkeire + minimumUkeireGain;
            if(improvesShanten || improvesSameShantenEfficiency || (kan && stillClosed && shanten==before))
                options.Add((call,shanten,waits));
'@
if (-not $callPolicy.Contains('improvesSameShantenEfficiency')) {
    if (-not $callPolicy.Contains($oldAccept)) { throw 'EnhancedCallPolicy acceptance rule not found.' }
    $callPolicy = $callPolicy.Replace($oldAccept, $newAccept.TrimEnd())
}

$helperMarker = '    private static int Shanten(IEnumerable<Tile> hand,int melds)'
$helper = @'
    private static int CountImprovingUkeire(
        IReadOnlyList<Tile> hand, int melds, int currentShanten, Wall wall)
    {
        var drawn = hand.ToList();
        int total = 0;
        for (int id = 0; id < Tile.Count34; id++)
        {
            int live = wall.LiveOf(id);
            if (live <= 0) continue;
            drawn.Add(Tile.FromId(id));
            if (Shanten(drawn, melds) < currentShanten)
                total += live;
            drawn.RemoveAt(drawn.Count - 1);
        }
        return total;
    }

'@
if (-not $callPolicy.Contains('private static int CountImprovingUkeire(')) {
    if (-not $callPolicy.Contains($helperMarker)) { throw 'EnhancedCallPolicy helper insertion point not found.' }
    $callPolicy = $callPolicy.Replace($helperMarker, $helper + $helperMarker)
}
Set-Content -Path $callPolicyPath -Value $callPolicy -NoNewline

$autoPath = 'upstream/Mahjong.Plugin.Dalamud/Actions/AutoPlayLoop.cs'
$auto = Get-Content $autoPath -Raw
$helperMarker = '    private bool IsMultiplayerSmallAccount() =>'
$helper = @'
    private bool TryChooseBigAccountEfficiencyCall(StateSnapshot snapshot, out ActionChoice choice)
    {
        choice = ActionChoice.Pass("big account: no efficient chi/pon found");
        if (!IsMultiplayerBigAccount() ||
            (!snapshot.Legal.Can(ActionFlags.Chi) && !snapshot.Legal.Can(ActionFlags.Pon)))
            return false;

        try
        {
            // The big account is allowed to open the hand when doing so improves
            // either shanten or the number of effective tiles, while preserving a
            // reachable legal yaku under Doman rules.
            var chiPonOnly = snapshot.Legal with
            {
                Flags = snapshot.Legal.Flags & (ActionFlags.Chi | ActionFlags.Pon),
                KanCandidates = [],
            };
            var callState = snapshot with { Legal = chiPonOnly };
            var policy = new Mahjong.Policy.Efficiency.EnhancedCallPolicy(
                new Mahjong.Rules.Rulesets.DomanRuleSet());
            var decision = policy.Evaluate(callState);
            if (!decision.Accept || decision.Value is not { } accepted ||
                accepted.Kind is not (MeldKind.Chi or MeldKind.Pon))
                return false;

            ActionKind kind = accepted.Kind == MeldKind.Chi ? ActionKind.Chi : ActionKind.Pon;
            choice = new ActionChoice(
                kind,
                Call: accepted,
                Reasoning: $"big account aggressive efficiency call: {decision.Reason.Display}");
            return true;
        }
        catch (Exception ex)
        {
            log.Warning($"[AutoPlayLoop] aggressive big-account call evaluation failed: {ex.Message}");
            return false;
        }
    }

'@
if (-not $auto.Contains('TryChooseBigAccountEfficiencyCall(')) {
    if (-not $auto.Contains($helperMarker)) { throw 'AutoPlayLoop team helper insertion point not found.' }
    $auto = $auto.Replace($helperMarker, $helper + $helperMarker)
}

$bigMarker = @'
        if (IsMultiplayerBigAccount())
        {
            if (snapshot.Legal.Can(ActionFlags.Tsumo))
'@
$bigReplacement = @'
        if (IsMultiplayerBigAccount())
        {
            if (TryChooseBigAccountEfficiencyCall(snapshot, out choice))
            {
                hasMortalWait = false;
                plugin.Aggregator.PublishLocalExecution(snapshot, choice, "big-aggressive-call");
                return true;
            }

            if (snapshot.Legal.Can(ActionFlags.Tsumo))
'@
if (-not $auto.Contains('"big-aggressive-call"')) {
    if (-not $auto.Contains($bigMarker)) { throw 'Big account decision insertion point not found.' }
    $auto = $auto.Replace($bigMarker, $bigReplacement)
}
Set-Content -Path $autoPath -Value $auto -NoNewline

Write-Host 'Big-account Chi/Pon now accepts yaku-valid calls that improve shanten or materially improve effective-tile count.'
