$ErrorActionPreference = 'Stop'

function Replace-One([string]$Path, [string]$Old, [string]$New, [string]$Label) {
    $source = Get-Content $Path -Raw
    if (-not $source.Contains($Old)) { throw "Patch anchor not found: $Label ($Path)" }
    $source = $source.Replace($Old, $New)
    Set-Content -Path $Path -Value $source -NoNewline
}

# Configuration: separate the two discard policies and configure a whole-match limit.
$configPath = 'upstream/Mahjong.Plugin.Dalamud/Configuration.cs'
$config = Get-Content $configPath -Raw
$anchor = '    public bool AutoAdvanceAfterHand { get; init; } = false;'
$addition = @'
    public bool AutoAdvanceAfterHand { get; init; } = false;

    /// <summary>Discard policy used only during our own discard turns.</summary>
    public AutoPlayMode AutoPlayMode { get; init; } = AutoPlayMode.Ai;

    /// <summary>Stop both auto-play and auto-queue after this many completed ranked East matches.</summary>
    public bool MatchLimitEnabled { get; init; } = false;
    public int MatchLimit { get; init; } = 5;
    public int CompletedMatchCount { get; init; } = 0;
'@
if (-not $config.Contains('public AutoPlayMode AutoPlayMode')) {
    if (-not $config.Contains($anchor)) { throw 'Configuration AutoAdvanceAfterHand anchor not found.' }
    $config = $config.Replace($anchor, $addition.TrimEnd())
    $config += [Environment]::NewLine + 'public enum AutoPlayMode { Ai = 0, Tsumogiri = 1 }' + [Environment]::NewLine
    Set-Content -Path $configPath -Value $config -NoNewline
}

# Keep the queue option independent. Starting the queue must not arm auto-play.
$collectionPath = 'upstream/Mahjong.Plugin.Dalamud/Actions/ContinuousCollectionLoop.cs'
$collection = Get-Content $collectionPath -Raw
$collection = $collection.Replace('Plugin.ClientState.TerritoryType.RowId == TerritoryId', 'Plugin.ClientState.TerritoryType == TerritoryId')
$oldStartGuard = '        if (!cfg.TosAccepted || !cfg.AutoPlayConfirmed) return "Enable Auto-play in the main window first.";'
$newStartGuard = '        if (!cfg.TosAccepted) return "Accept the plugin terms in the main window first.";'
if ($collection.Contains($oldStartGuard)) { $collection = $collection.Replace($oldStartGuard, $newStartGuard) }
elseif (-not $collection.Contains($newStartGuard)) { throw 'Collection start guard not found.' }

$oldStartConfig = @'
            ContinuousCollection = true, CollectionCharacterId = Plugin.PlayerState.ContentId,
            AutomationArmed = true, SuggestionOnly = false, AutoAdvanceAfterHand = true,
            DebugAutoPacketLogging = true, EnableGameLogging = true,
'@
$newStartConfig = @'
            ContinuousCollection = true, CollectionCharacterId = Plugin.PlayerState.ContentId,
            DebugAutoPacketLogging = true, EnableGameLogging = true,
'@
if ($collection.Contains($oldStartConfig)) { $collection = $collection.Replace($oldStartConfig, $newStartConfig) }
elseif (-not $collection.Contains($newStartConfig)) { throw 'Collection Start config block not found.' }

# Count only the authoritative duty-completed event. One event = one full match.
$collection = $collection.Replace(
    '    private int completionSignal;',
    '    private int completionSignal;' + [Environment]::NewLine +
    '    private int completionCountedThisDuty;' + [Environment]::NewLine +
    '    private bool wasInTargetDuty;')
$oldCompleted = @'
    private void OnDutyCompleted(IDutyStateEventArgs args)
    {
        if (disposed || !engaged || args.TerritoryType.RowId != TerritoryId
            || args.ContentFinderCondition.RowId != DutyId || !Plugin.ClientState.IsLoggedIn
            || plugin.Configuration.CollectionCharacterId != Plugin.PlayerState.ContentId) return;
        Interlocked.Exchange(ref completionSignal, 1);
        log.Information("[Collection] Observed player East-only duty completion");
    }
'@
$newCompleted = @'
    private void OnDutyCompleted(IDutyStateEventArgs args)
    {
        if (disposed || args.TerritoryType.RowId != TerritoryId
            || args.ContentFinderCondition.RowId != DutyId || !Plugin.ClientState.IsLoggedIn
            || !Plugin.PlayerState.IsLoaded) return;

        var cfg = plugin.Configuration;
        if (cfg.CollectionCharacterId != 0 && cfg.CollectionCharacterId != Plugin.PlayerState.ContentId)
            return;

        if (engaged)
            Interlocked.Exchange(ref completionSignal, 1);

        bool tracking = cfg.MatchLimitEnabled || cfg.ContinuousCollection
            || (cfg.AutomationArmed && !cfg.SuggestionOnly);
        if (!tracking || Interlocked.Exchange(ref completionCountedThisDuty, 1) != 0)
            return;

        int completed = cfg.CompletedMatchCount + 1;
        bool limitReached = cfg.MatchLimitEnabled && completed >= Math.Clamp(cfg.MatchLimit, 1, 999);
        plugin.ConfigService.Update(c => c with
        {
            CompletedMatchCount = completed,
            AutomationArmed = limitReached ? false : c.AutomationArmed,
            ContinuousCollection = limitReached ? false : c.ContinuousCollection,
        });
        log.Information($"[Collection] Completed full ranked East match {completed}"
            + (limitReached ? "; match limit reached, auto-play and auto-queue stopped" : ""));
    }
'@
if ($collection.Contains($oldCompleted)) { $collection = $collection.Replace($oldCompleted, $newCompleted) }
elseif (-not $collection.Contains('Completed full ranked East match')) { throw 'Duty completion handler anchor not found.' }

# Reset de-duplication only after a new East-only duty starts.
$oldUpdate = @'
    private void Update(IFramework _)
    {
        if (disposed) return;
        try
        {
            var cfg = plugin.Configuration;
            if (!cfg.ContinuousCollection && !engaged) return;
'@
$newUpdate = @'
    private unsafe void Update(IFramework _)
    {
        if (disposed) return;
        try
        {
            var cfg = plugin.Configuration;
            if (cfg.MatchLimitEnabled || cfg.AutomationArmed || cfg.ContinuousCollection || engaged)
            {
                var game = GameMain.Instance();
                bool inTargetDutyNow = game != null
                    && game->CurrentContentFinderConditionId == DutyId
                    && Plugin.ClientState.TerritoryType.RowId == TerritoryId;
                if (inTargetDutyNow && !wasInTargetDuty)
                    Interlocked.Exchange(ref completionCountedThisDuty, 0);
                wasInTargetDuty = inTargetDutyNow;
            }
            if (!cfg.ContinuousCollection && !engaged) return;
'@
if ($collection.Contains($oldUpdate)) { $collection = $collection.Replace($oldUpdate, $newUpdate) }
elseif (-not $collection.Contains('bool inTargetDutyNow = game != null')) { throw 'Collection Update method anchor not found.' }

$oldAllowed = @'
            AutomationAllowed = cfg.TosAccepted && cfg.AutoPlayConfirmed && cfg.AutomationArmed && !cfg.SuggestionOnly
                && cfg.AutoAdvanceAfterHand,
'@
$newAllowed = @'
            AutomationAllowed = cfg.TosAccepted && (cfg.ContinuousCollection
                || (cfg.AutomationArmed && !cfg.SuggestionOnly && cfg.AutoAdvanceAfterHand)),
'@
if ($collection.Contains($oldAllowed)) { $collection = $collection.Replace($oldAllowed, $newAllowed) }
elseif (-not $collection.Contains('AutomationAllowed = cfg.TosAccepted && (cfg.ContinuousCollection')) {
    throw 'Collection AutomationAllowed gate not found.'
}
Set-Content -Path $collectionPath -Value $collection -NoNewline

# Auto-play UI: AI vs. tsumogiri plus a full-match limit. Queue remains its own card.
$windowPath = 'upstream/Mahjong.Plugin.Dalamud/UI/MainWindow.cs'
$window = Get-Content $windowPath -Raw
$oldPillEnd = @'
            if (ModePill("auto", Loc.T("Auto-play", "自动打牌"), Loc.T("Click for you", "替你点击"), Theme.Accent, current == 2, size))
                RequestMode(2, cfg);
        }
'@
$newPillEnd = @'
            if (ModePill("auto", Loc.T("Auto-play", "自动打牌"), Loc.T("Click for you", "替你点击"), Theme.Accent, current == 2, size))
                RequestMode(2, cfg);

            if (current == 2)
                DrawAutoPlayOptions(cfg);
        }
'@
if ($window.Contains($oldPillEnd)) { $window = $window.Replace($oldPillEnd, $newPillEnd) }
elseif (-not $window.Contains('DrawAutoPlayOptions(cfg);')) { throw 'Mode pill end anchor not found.' }

$methodAnchor = '    private bool autoPlayConfirmPending;'
$method = @'
    private void DrawAutoPlayOptions(Configuration cfg)
    {
        ImGui.Dummy(new Vector2(0, 8));
        Theme.Caption(Loc.T("Auto-play policy", "自动打牌方式"));

        if (ImGui.RadioButton(Loc.T("AI play", "AI打牌") + "##auto-ai",
                cfg.AutoPlayMode == AutoPlayMode.Ai))
            plugin.ConfigService.Update(c => c with { AutoPlayMode = AutoPlayMode.Ai });
        ImGui.SameLine();
        if (ImGui.RadioButton(Loc.T("Tsumogiri", "自动摸切") + "##auto-tsumogiri",
                cfg.AutoPlayMode == AutoPlayMode.Tsumogiri))
            plugin.ConfigService.Update(c => c with { AutoPlayMode = AutoPlayMode.Tsumogiri });

        Theme.Subtle(Loc.T(
            "Tsumogiri changes only your own discard after drawing; calls and win prompts still use the normal AI policy.",
            "自动摸切只改变自己摸牌后的弃牌；鸣牌和和牌提示仍按原有 AI 策略处理。"));

        ImGui.Dummy(new Vector2(0, 6));
        bool limitEnabled = cfg.MatchLimitEnabled;
        if (ImGui.Checkbox(Loc.T("Limit completed matches", "限制完整对局场数") + "##match-limit", ref limitEnabled))
            plugin.ConfigService.Update(c => c with { MatchLimitEnabled = limitEnabled });

        if (limitEnabled)
        {
            int limit = Math.Clamp(cfg.MatchLimit, 1, 100);
            if (ImGui.SliderInt(Loc.T("Target matches", "目标场数") + "##match-limit-value", ref limit, 1, 100))
                plugin.ConfigService.Update(c => c with { MatchLimit = limit });
        }

        Theme.Subtle(Loc.T(
            $"Completed full matches: {cfg.CompletedMatchCount}",
            $"已完成完整对局：{cfg.CompletedMatchCount} 场"));
        if (ImGui.Button(Loc.T("Reset match count", "重置场数") + "##match-count-reset"))
            plugin.ConfigService.Update(c => c with { CompletedMatchCount = 0 });

        ImGui.Dummy(new Vector2(0, 4));
        bool autoAdvance = cfg.AutoAdvanceAfterHand;
        if (ImGui.Checkbox(Loc.T("Auto-advance after each hand", "小局结束后自动进入下一局") + "##auto-advance", ref autoAdvance))
            plugin.ConfigService.Update(c => c with { AutoAdvanceAfterHand = autoAdvance });
    }

'@
$oldHint = 'Theme.Subtle(Loc.T($"Completed this load: {plugin.Collection.CompletedMatches}. No time limit; resumes after reload.", $"本次加载已完成：{plugin.Collection.CompletedMatches} 场。没有时间限制，重载后会继续。"));'
$newHint = 'Theme.Subtle(Loc.T($"Completed full matches: {cfg.CompletedMatchCount}. Match limit stops auto-play and auto-queue together.", $"已完成完整对局：{cfg.CompletedMatchCount} 场。达到上限后同时停止自动打牌和自动排本。"));'
$window = $window.Replace($oldHint, $newHint)
$oldQueueEnd = 'Theme.Subtle(Loc.T("Stop withdraws the queue or finishes the current match. Off stops all play.", "停止会撤销排队，或打完当前这一场。切到“关闭”会停止一切操作。"));'
$newQueueEnd = 'Theme.Subtle(Loc.T("Auto-queue is independent from auto-play and currently targets the novice East-only ranked duty.", "自动排本与自动打牌独立，目前排队目标为新人东风战段位赛。"));'
$window = $window.Replace($oldQueueEnd, $newQueueEnd)

if (-not $window.Contains('private void DrawAutoPlayOptions(Configuration cfg)')) {
    if (-not $window.Contains($methodAnchor)) { throw 'Auto-play options insertion point not found.' }
    $window = $window.Replace($methodAnchor, $method + $methodAnchor)
}

$oldQueueTitle = 'Theme.SectionHeader(Loc.T("Continuous collection · Player East-only", "连续采集 · 玩家东风战"));'
$newQueueTitle = 'Theme.SectionHeader(Loc.T("Auto-queue · Player East-only", "自动排本 · 新人东风战"));'
$window = $window.Replace($oldQueueTitle, $newQueueTitle)
$oldQueueToggle = 'Loc.T("Auto-queue, commence and repeat until stopped", "自动排队、开局并循环，直到手动停止") + "##collection"'
$newQueueToggle = 'Loc.T("Enable independent auto-queue", "启用独立自动排本") + "##collection"'
$window = $window.Replace($oldQueueToggle, $newQueueToggle)

$oldDisabled = @'
            if (!cfg.AutoPlayConfirmed) ImGui.BeginDisabled();
            if (ImGui.Checkbox(Loc.T("Enable independent auto-queue", "启用独立自动排本") + "##collection", ref enabled))
            {
                if (enabled) Plugin.ChatGui.Print("[MjAuto] " + Loc.Status(plugin.Collection.Start()));
                else plugin.Collection.Stop();
            }
            if (!cfg.AutoPlayConfirmed) ImGui.EndDisabled();
'@
$newEnabled = @'
            if (ImGui.Checkbox(Loc.T("Enable independent auto-queue", "启用独立自动排本") + "##collection", ref enabled))
            {
                if (enabled) Plugin.ChatGui.Print("[MjAuto] " + Loc.Status(plugin.Collection.Start()));
                else plugin.Collection.Stop();
            }
'@
if ($window.Contains($oldDisabled)) { $window = $window.Replace($oldDisabled, $newEnabled) }
elseif ($window.Contains('if (!cfg.AutoPlayConfirmed) ImGui.BeginDisabled();')) {
    throw 'Could not decouple the auto-queue UI from AutoPlayConfirmed.'
}
Set-Content -Path $windowPath -Value $window -NoNewline

# Tsumogiri: validate the hand, then discard the physical draw slot 13.
$autoPath = 'upstream/Mahjong.Plugin.Dalamud/Actions/AutoPlayLoop.cs'
$auto = Get-Content $autoPath -Raw
if (-not $auto.Contains('using Mahjong.Core;')) {
    $auto = $auto.Replace('using Mahjong.Engine;', 'using Mahjong.Engine;' + [Environment]::NewLine + 'using Mahjong.Core;')
}
$discardStart = $auto.IndexOf('    private void ScheduleDiscard(DispatchContext context)')
$discardEnd = $auto.IndexOf('    /// <summary>On HookFailed', $discardStart)
if ($discardStart -lt 0 -or $discardEnd -lt 0) { throw 'ScheduleDiscard method boundaries not found.' }
$discardBlock = $auto.Substring($discardStart, $discardEnd - $discardStart)
$oldChoose = @'
            if (!TryChoose(snap, out var choice))
            {
                LastActionDescription = "waiting for Mortal discard";
                fsm.ClearContext();
                return;
            }
'@
$newChoose = @'
            bool forceTsumogiri = !isTerminalWin && plugin.Configuration.AutoPlayMode == AutoPlayMode.Tsumogiri;
            bool drawnIsRed = false;
            int drawnSlot = -1;
            ActionChoice choice;
            if (forceTsumogiri)
            {
                if (!TryChooseTsumogiri(snap, out choice, out drawnSlot, out drawnIsRed, out string tsumogiriError))
                {
                    LastActionDescription = $"tsumogiri paused: {tsumogiriError}";
                    log.Warning($"[AutoPlayLoop] {LastActionDescription}");
                    return;
                }
            }
            else if (!TryChoose(snap, out choice))
            {
                LastActionDescription = "waiting for Mortal discard";
                fsm.ClearContext();
                return;
            }
'@
if ($discardBlock.Contains($oldChoose)) { $discardBlock = $discardBlock.Replace($oldChoose, $newChoose) }
elseif (-not $discardBlock.Contains('bool forceTsumogiri')) { throw 'ScheduleDiscard choice anchor not found.' }

$oldDispatch = @'
            if (isTerminalWin)
                DispatchCallChoice(snap, choice);
            else
                DispatchPolicyChoice(snap, choice);
'@
$newDispatch = @'
            if (isTerminalWin)
                DispatchCallChoice(snap, choice);
            else if (forceTsumogiri)
            {
                var result = plugin.Dispatcher.DispatchDiscard(drawnSlot);
                LastActionDescription = $"auto-tsumogiri {choice.DiscardTile} slot={drawnSlot} → {result}";
                plugin.GameLogger.RecordAction(ActionKind.Discard, choice.DiscardTile, drawnSlot,
                    result.ToString(), choice.Reasoning, drawnIsRed);
                EmitDispatchFinding("tsumogiri", result, tile: choice.DiscardTile, slot: drawnSlot,
                    snap: snap, isRed: drawnIsRed);
                ClearRetryDebounceIfHookFailed(result);
            }
            else
                DispatchPolicyChoice(snap, choice);
'@
if ($discardBlock.Contains($oldDispatch)) { $discardBlock = $discardBlock.Replace($oldDispatch, $newDispatch) }
elseif (-not $discardBlock.Contains('auto-tsumogiri')) { throw 'ScheduleDiscard dispatch anchor not found.' }
$auto = $auto.Substring(0, $discardStart) + $discardBlock + $auto.Substring($discardEnd)

$helperAnchor = '    private void ScheduleCallDecision(DispatchContext context)'
$helper = @'
    private bool TryChooseTsumogiri(
        StateSnapshot snapshot, out ActionChoice choice, out int slot, out bool isRed, out string reason)
    {
        choice = ActionChoice.Pass("tsumogiri not resolved");
        slot = -1;
        isRed = false;
        reason = "not a legal discard turn";
        if (!snapshot.Legal.Can(ActionFlags.Discard))
            return false;

        var rawSlots = plugin.AddonReader.DumpHandArrayRaw();
        if (rawSlots is null || rawSlots.Length <= 13)
        {
            reason = "addon draw slot 13 is unavailable";
            return false;
        }

        int configuredBase = plugin.AddonReader.ActiveLayout?.TileTextureBase ?? 0;
        if (configuredBase == 0)
        {
            reason = "tile texture base is not resolved";
            return false;
        }

        int textureBase = HandArrayDecoder.ResolveTextureBase(rawSlots, configuredBase, out _);
        var decoded = HandArrayDecoder.ReadHandDetailed(rawSlots, textureBase);
        if (decoded.Tiles.Count != snapshot.Hand.Count)
        {
            reason = $"addon hand count {decoded.Tiles.Count} does not match observed hand {snapshot.Hand.Count}";
            return false;
        }

        var expected = new int[34];
        var observed = new int[34];
        foreach (var tile in snapshot.Hand) expected[tile.Id]++;
        foreach (var tile in decoded.Tiles) observed[tile.Id]++;
        for (int i = 0; i < 34; i++)
        {
            if (expected[i] != observed[i])
            {
                reason = "addon tiles do not match the observed concealed hand";
                return false;
            }
        }

        int drawnId = HandArrayDecoder.DecodeTileId(rawSlots[13], textureBase, out isRed);
        if (drawnId < 0)
        {
            reason = "the physical draw slot 13 is empty or undecodable";
            return false;
        }

        var drawn = Tile.FromId(drawnId);
        if (!snapshot.Legal.AllowsDiscard(drawn))
        {
            reason = $"drawn tile {drawn} is not in the current legal discard set";
            return false;
        }

        slot = 13;
        choice = ActionChoice.Discard(drawn, "automatic tsumogiri from addon draw slot 13")
            with { DiscardIsRed = isRed };
        reason = "";
        return true;
    }

'@
if (-not $auto.Contains('private bool TryChooseTsumogiri(')) {
    if (-not $auto.Contains($helperAnchor)) { throw 'Tsumogiri helper insertion point not found.' }
    $auto = $auto.Replace($helperAnchor, $helper + $helperAnchor)
}
Set-Content -Path $autoPath -Value $auto -NoNewline

# Single-player version in the window title.
$window = Get-Content $windowPath -Raw
if (-not $window.Contains('private const string BuildUiVersion')) {
    $window = $window.Replace(
        '    private readonly Plugin plugin;',
        '    private const string BuildUiVersion = "SP1.0";' + [Environment]::NewLine + '    private readonly Plugin plugin;')
}
$window = $window.Replace(
    ': base("Doman Mahjong Solver###domanmahjong-main")',
    ': base($"Doman Mahjong Solver {BuildUiVersion}###domanmahjong-main")')
$oldTitle = 'WindowName = Loc.T("Doman Mahjong Solver", "多玛麻将助手") + "###domanmahjong-main";'
$newTitle = 'WindowName = Loc.T("Doman Mahjong Solver", "多玛麻将助手") + " " + BuildUiVersion + "###domanmahjong-main";'
if ($window.Contains($oldTitle)) { $window = $window.Replace($oldTitle, $newTitle) }
Set-Content -Path $windowPath -Value $window -NoNewline

Write-Host 'Applied single-player options, independent auto-queue, validated tsumogiri and full-match limit.'
