# Applies diagnostic-only instrumentation to the CN single-player build.
$ErrorActionPreference = 'Stop'

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
if (-not $source.Contains($oldDecision)) { throw 'AutoPlayLoop decision diagnostic anchor not found.' }
$source = $source.Replace($oldDecision, $newDecision)

$oldFinding = @'
            ["path"] = plugin.Dispatcher.LastDispatchPath,
            ["cur_state"] = snap?.AddonStateCode,
'@
$newFinding = @'
            ["path"] = plugin.Dispatcher.LastDispatchPath,
            ["callback_results"] = plugin.Dispatcher.LastDiscardCallbackResults,
            ["cur_state"] = snap?.AddonStateCode,
'@
if (-not $source.Contains($oldFinding)) { throw 'AutoPlayLoop dispatch finding anchor not found.' }
$source = $source.Replace($oldFinding, $newFinding)

$oldPending = @'
        plugin.GameLogger.RecordActionOutcome(pending.ActionId, pending.Label, status, pending.LastDispatchPath);
'@
$newPending = @'
        plugin.GameLogger.RecordActionOutcome(pending.ActionId, pending.Label, status, pending.LastDispatchPath);
        log.Info($"[AutoPlayDiag] outcome actionId={pending.ActionId} label={pending.Label} status={status} callbackObserved={pending.CallbackObserved} path={pending.LastDispatchPath} beforeState={pending.StateAtDispatch} beforeHand={pending.HandAtDispatch} afterState={snap?.AddonStateCode} afterHand={snap?.Hand.Count}");
'@
if (-not $source.Contains($oldPending)) { throw 'AutoPlayLoop dispatch outcome anchor not found.' }
$source = $source.Replace($oldPending, $newPending)

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
if (-not $source.Contains($oldMatch)) { throw 'AutoPlayLoop tile matching anchor not found.' }
$source = $source.Replace($oldMatch, $newMatch)

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
if (-not $source.Contains($oldDispatch)) { throw 'AutoPlayLoop discard dispatch anchor not found.' }
$source = $source.Replace($oldDispatch, $newDispatch)
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
if (-not $source.Contains($oldProperty)) { throw 'InputDispatcher diagnostic property anchor not found.' }
$source = $source.Replace($oldProperty, $newProperty)

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
if (-not $source.Contains($oldStart)) { throw 'InputDispatcher discard start anchor not found.' }
$source = $source.Replace($oldStart, $newStart)

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
if (-not $source.Contains($oldHandshake)) { throw 'InputDispatcher two-callback handshake anchor not found.' }
$source = $source.Replace($oldHandshake, $newHandshake)

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
if (-not $source.Contains($oldList)) { throw 'InputDispatcher list-widget anchor not found.' }
$source = $source.Replace($oldList, $newList)

$oldFallback = @'
        bool ok = unit->FireCallback(2, values, true);
        LastDiscardPath = $"opcode-7-fallback(slot={slotIndex},ok={ok})";
'@
$newFallback = @'
        bool ok = unit->FireCallback(2, values, true);
        LastDiscardCallbackResults = $"opcode7={ok};slot={slotIndex}";
        LastDiscardPath = $"opcode-7-fallback(slot={slotIndex},ok={ok})";
'@
if (-not $source.Contains($oldFallback)) { throw 'InputDispatcher fallback anchor not found.' }
$source = $source.Replace($oldFallback, $newFallback)
Set-Content -Path $dispatcher -Value $source -NoNewline

Write-Host 'Auto-discard diagnostics applied (logging only; dispatch decisions unchanged).'
