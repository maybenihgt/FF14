# Applies diagnostic-only instrumentation to the CN single-player build.
$ErrorActionPreference = 'Stop'

function Replace-One([string]$Source, [string]$Old, [string]$New, [string]$Label) {
    # Earlier single-player patches normalize AutoPlayLoop.cs to LF. Normalize
    # both source and here-string anchors so Windows checkout CRLF cannot break
    # otherwise identical source matches.
    $Source = $Source -replace "`r`n?", "`n"
    $Old = $Old -replace "`r`n?", "`n"
    $New = $New -replace "`r`n?", "`n"
    if (-not $Source.Contains($Old)) { throw "$Label anchor not found." }
    return $Source.Replace($Old, $New)
}

$auto = 'upstream/Mahjong.Plugin.Dalamud/Actions/AutoPlayLoop.cs'
$source = Get-Content $auto -Raw
$oldDecision = @'
    private void EmitDecisionFinding(string source, StateSnapshot snap, ActionChoice choice)
    {
        if (plugin.Configuration.MortalEnabled)
'@
$newDecision = @'
    private void EmitDecisionFinding(string source, StateSnapshot snap, ActionChoice choice)
    {
        log.Info($"[AutoPlayDiag] decision source={source} kind={choice.Kind} tile={choice.DiscardTile} red={choice.DiscardIsRed} handCount={snap.Hand.Count} hand=[{string.Join(",", snap.Hand)}] legal={snap.Legal.Flags} state={snap.AddonStateCode}");
        if (plugin.Configuration.MortalEnabled)
'@
$source = Replace-One $source $oldDecision $newDecision 'AutoPlayLoop decision diagnostic'

$oldFinding = @'
            ["path"] = plugin.Dispatcher.LastDispatchPath,
            ["cur_state"] = snap?.AddonStateCode,
'@
$newFinding = @'
            ["path"] = plugin.Dispatcher.LastDispatchPath,
            ["callback_results"] = plugin.Dispatcher.LastDiscardCallbackResults,
            ["cur_state"] = snap?.AddonStateCode,
'@
$source = Replace-One $source $oldFinding $newFinding 'AutoPlayLoop dispatch finding'

$oldPending = @'
        plugin.GameLogger.RecordActionOutcome(pending.ActionId, pending.Label, status, pending.LastDispatchPath);
'@
$newPending = @'
        plugin.GameLogger.RecordActionOutcome(pending.ActionId, pending.Label, status, pending.LastDispatchPath);
        log.Info($"[AutoPlayDiag] outcome actionId={pending.ActionId} label={pending.Label} status={status} callbackObserved={pending.CallbackObserved} path={pending.LastDispatchPath} beforeState={pending.StateAtDispatch} beforeHand={pending.HandAtDispatch} afterState={snap?.AddonStateCode} afterHand={snap?.Hand.Count}");
'@
$source = Replace-One $source $oldPending $newPending 'AutoPlayLoop dispatch outcome'

$oldMatch = @'
        int slot = plugin.AddonReader.FindAddonSlotOfTile(tile, targetIsRed);
        if (slot < 0)
        {
            LastActionDescription = $"tile {tile} not in hand";
            return;
        }
'@
$newMatch = @'
        int slot = plugin.AddonReader.FindAddonSlotOfTile(tile, targetIsRed);
        int[]? rawHand = plugin.AddonReader.DumpHandArrayRaw();
        log.Info($"[AutoPlayDiag] match tile={tile} red={targetIsRed?.ToString() ?? "unknown"} slot={slot} handCount={snap.Hand.Count} hand=[{string.Join(",", snap.Hand)}] rawSlots=[{(rawHand is null ? "unavailable" : string.Join(",", rawHand))}] state={snap.AddonStateCode}");
        if (slot < 0)
        {
            LastActionDescription = $"tile {tile} not in hand";
            log.Warning($"[AutoPlayDiag] match-failed tile={tile} red={targetIsRed?.ToString() ?? "unknown"}; automatic click was not attempted.");
            return;
        }
'@
$source = Replace-One $source $oldMatch $newMatch 'AutoPlayLoop tile matching'

$oldDispatch = @'
        var result = plugin.Dispatcher.DispatchDiscard(slot);
        LastActionDescription = $"auto-discard {tile} slot={slot} → {result}";
'@
$newDispatch = @'
        log.Info($"[AutoPlayDiag] dispatch-start tile={tile} slot={slot} state={snap.AddonStateCode} handCount={snap.Hand.Count}");
        var result = plugin.Dispatcher.DispatchDiscard(slot);
        log.Info($"[AutoPlayDiag] dispatch-return tile={tile} slot={slot} result={result} path={plugin.Dispatcher.LastDispatchPath} callbacks={plugin.Dispatcher.LastDiscardCallbackResults}");
        LastActionDescription = $"auto-discard {tile} slot={slot} → {result}";
'@
$source = Replace-One $source $oldDispatch $newDispatch 'AutoPlayLoop discard dispatch'
Set-Content -Path $auto -Value $source -NoNewline

$dispatcher = 'upstream/Mahjong.Plugin.Dalamud/Actions/InputDispatcher.cs'
$source = Get-Content $dispatcher -Raw
$oldProperty = @'
    public string LastDiscardPath
    {
        get => lastDiscardPath;
        private set { lastDiscardPath = value; LastDispatchPath = value; }
    }
'@
$newProperty = @'
    public string LastDiscardPath
    {
        get => lastDiscardPath;
        private set { lastDiscardPath = value; LastDispatchPath = value; }
    }

    /// <summary>Diagnostic-only return values from the most recent discard input path. Does not alter dispatch decisions.</summary>
    public string LastDiscardCallbackResults { get; private set; } = "(none)";
'@
$source = Replace-One $source $oldProperty $newProperty 'InputDispatcher diagnostic property'

$oldStart = @'
    public unsafe DispatchResult DispatchDiscard(int slotIndex)
    {
        if (slotIndex is < 0 or > 13)
'@
$newStart = @'
    public unsafe DispatchResult DispatchDiscard(int slotIndex)
    {
        LastDiscardCallbackResults = "not-attempted";
        if (slotIndex is < 0 or > 13)
'@
$source = Replace-One $source $oldStart $newStart 'InputDispatcher discard start'

$oldHandshake = @'
                unit->FireCallback(2, v15, true);

                var v7 = stackalloc AtkValue[2];
                v7[0].SetInt(7);
                v7[1].SetInt(slotIndex);
                unit->FireCallback(2, v7, true);

                LastDiscardPath = $"opcode-15+7(raw={raw},slot={slotIndex})";
'@
$newHandshake = @'
                bool selectCallbackResult = unit->FireCallback(2, v15, true);

                var v7 = stackalloc AtkValue[2];
                v7[0].SetInt(7);
                v7[1].SetInt(slotIndex);
                bool commitCallbackResult = unit->FireCallback(2, v7, true);

                LastDiscardCallbackResults = $"opcode15={selectCallbackResult};opcode7={commitCallbackResult};raw={raw};slot={slotIndex}";
                LastDiscardPath = $"opcode-15+7(raw={raw},slot={slotIndex})";
'@
$source = Replace-One $source $oldHandshake $newHandshake 'InputDispatcher two-callback handshake'

$oldList = @'
        if (IsListWidgetPopupActive(unit) && TryDispatchListItemClick(unit, slotIndex))
        {
            LastDiscardPath = $"list-widget(slot={slotIndex})";
'@
$newList = @'
        if (IsListWidgetPopupActive(unit) && TryDispatchListItemClick(unit, slotIndex))
        {
            LastDiscardCallbackResults = $"SelectItem invoked (void);slot={slotIndex}";
            LastDiscardPath = $"list-widget(slot={slotIndex})";
'@
$source = Replace-One $source $oldList $newList 'InputDispatcher list-widget'

$oldFallback = @'
        bool ok = unit->FireCallback(2, values, true);
        LastDiscardPath = $"opcode-7-fallback(slot={slotIndex},ok={ok})";
'@
$newFallback = @'
        bool ok = unit->FireCallback(2, values, true);
        LastDiscardCallbackResults = $"opcode7={ok};slot={slotIndex}";
        LastDiscardPath = $"opcode-7-fallback(slot={slotIndex},ok={ok})";
'@
$source = Replace-One $source $oldFallback $newFallback 'InputDispatcher fallback'
Set-Content -Path $dispatcher -Value $source -NoNewline

Write-Host 'Auto-discard diagnostics applied (logging only; dispatch decisions unchanged).'
