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

$collection = $collection.Replace('Plugin.ClientState.TerritoryType.RowId == TerritoryId', 'Plugin.ClientState.TerritoryType == TerritoryId')

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
            "Feeder mode: discard the drawn tile and pass every Chi/Pon/Kan/Ron/Tsumo prompt.",
            "送分模式：自己摸牌后直接摸切；遇到吃、碰、杠、荣和、自摸一律跳过。"));

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
            bool feederMode = plugin.Configuration.AutoPlayMode == AutoPlayMode.Tsumogiri;
            bool forceTsumogiri = !isTerminalWin && feederMode;
            bool drawnIsRed = false;
            int drawnSlot = -1;
            ActionChoice choice;
            if (isTerminalWin && feederMode)
            {
                // Feeder mode declines a Ron/Tsumo prompt instead of taking the win.
                if (!snap.Legal.Can(ActionFlags.Pass))
                {
                    LastActionDescription = "feeder mode: win prompt has no legal pass action; waiting";
                    fsm.ClearContext();
                    return;
                }
                choice = ActionChoice.Pass("feeder tsumogiri mode: decline Ron/Tsumo");
            }
            else if (forceTsumogiri)
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

# Route our own legal discard turn through the discard scheduler even when
# state-6 exposes self-declare/call-related flags at the same time.
$autoPath = 'upstream/Mahjong.Plugin.Dalamud/Actions/AutoPlayLoop.cs'
$auto = Get-Content $autoPath -Raw
$oldRoute = @'
        if (isCallPrompt)
            ScheduleCallDecision(context);
        else
            ScheduleDiscard(context);
'@
$newRoute = @'
        // A self-discard surface (notably state 6) may expose discard plus self-declare flags.
        // Only route to the opponent-call scheduler when discard is not currently legal.
        if (isCallPrompt && !isDiscardTurn)
            ScheduleCallDecision(context);
        else
            ScheduleDiscard(context);
'@
if ($auto.Contains($oldRoute)) { $auto = $auto.Replace($oldRoute, $newRoute) }
elseif (-not $auto.Contains('if (isCallPrompt && !isDiscardTurn)')) { throw 'Auto-play call/discard route anchor not found.' }
Set-Content -Path $autoPath -Value $auto -NoNewline


# Speed profile: lower the normal humanized action delay and shorten only the safe UI dispatch waits.
$configPath = 'upstream/Mahjong.Plugin.Dalamud/Configuration.cs'
$config = Get-Content $configPath -Raw
$config = $config.Replace('public int HumanizedDelayMs { get; init; } = 1200;', 'public int HumanizedDelayMs { get; init; } = 350;')
if (-not $config.Contains('public int HumanizedDelayMs { get; init; } = 350;')) { throw 'Could not apply faster default HumanizedDelayMs.' }
if ($config.Contains('public const int CurrentSchemaVersion = 4;')) {
    $config = $config.Replace('public const int CurrentSchemaVersion = 4;', 'public const int CurrentSchemaVersion = 5;')
}
elseif (-not $config.Contains('public const int CurrentSchemaVersion = 5;')) {
    throw 'Expected config schema version 4 before speed migration.'
}
Set-Content -Path $configPath -Value $config -NoNewline

$timingPath = 'upstream/Mahjong.Plugin.Dalamud/Actions/HumanTiming.cs'
$timing = Get-Content $timingPath -Raw
$timing = $timing.Replace('double floorMs = 400.0,', 'double floorMs = 120.0,')
$timing = $timing.Replace('double capMs = 2500.0)', 'double capMs = 1200.0)')
if (-not $timing.Contains('double floorMs = 120.0,') -or -not $timing.Contains('double capMs = 1200.0)')) {
    throw 'Could not apply faster HumanTiming bounds.'
}
Set-Content -Path $timingPath -Value $timing -NoNewline

$settingsPath = 'upstream/Mahjong.Plugin.Dalamud/UI/SettingsWindow.cs'
$settings = Get-Content $settingsPath -Raw
$settings = $settings.Replace('ref delay, 400, 3000, "%d ms")', 'ref delay, 150, 1500, "%d ms")')
$settings = $settings.Replace(
    'Loc.T("Average delay before each auto-play click.", "每次自动点击前的平均延迟。")',
    'Loc.T("Median delay before an action. Lower values make your turns faster.", "每次自动操作前的延迟中位数。数值越低，自己的回合出牌越快。")')
if (-not $settings.Contains('ref delay, 150, 1500, "%d ms")')) { throw 'Could not update click-speed slider range.' }
Set-Content -Path $settingsPath -Value $settings -NoNewline

$autoPath = 'upstream/Mahjong.Plugin.Dalamud/Actions/AutoPlayLoop.cs'
$auto = Get-Content $autoPath -Raw
$auto = $auto.Replace('private const int VariantAcceptDelayMs = 500;', 'private const int VariantAcceptDelayMs = 250;')
$auto = $auto.Replace('private const int CallDecisionDelayMs = 700;', 'private const int CallDecisionDelayMs = 300;')
$auto = $auto.Replace('private const int TerminalWinConfirmationDelayMs = 400;', 'private const int TerminalWinConfirmationDelayMs = 250;')
$auto = $auto.Replace('private const int RiichiTsumogiriDelayMs = 700;', 'private const int RiichiTsumogiriDelayMs = 350;')
if (-not $auto.Contains('private const int CallDecisionDelayMs = 300;')) { throw 'Could not shorten call decision delay.' }
Set-Content -Path $autoPath -Value $auto -NoNewline

# Existing SP1.1 configs already use schema v4; migrate their old 1200 ms default to 350 ms.
$pluginPath = 'upstream/Mahjong.Plugin.Dalamud/Plugin.cs'
$plugin = Get-Content $pluginPath -Raw
$oldMigrator = '            new ConfigMigratorV3ToV4(),'
$newMigrator = $oldMigrator + [Environment]::NewLine + '            new ConfigMigratorV4ToV5(),'
if ($plugin.Contains($oldMigrator) -and -not $plugin.Contains('new ConfigMigratorV4ToV5()')) {
    $plugin = $plugin.Replace($oldMigrator, $newMigrator)
}
elseif (-not $plugin.Contains('new ConfigMigratorV4ToV5()')) {
    throw 'ConfigMigratorV3ToV4 registration point not found.'
}
Set-Content -Path $pluginPath -Value $plugin -NoNewline

$migrationPath = 'upstream/Mahjong.Plugin.Dalamud/Composition/ConfigMigratorV4ToV5.cs'
$migration = @'
using Mahjong.Plugin.Game;

namespace Mahjong.Plugin.Dalamud.Composition;

internal sealed class ConfigMigratorV4ToV5 : IConfigMigrator<Configuration>
{
    public int FromVersion => 4;
    public int ToVersion => 5;

    public Configuration Migrate(Configuration input) => input with
    {
        Version = ToVersion,
        HumanizedDelayMs = input.HumanizedDelayMs == 1200
            ? 350
            : Math.Clamp(input.HumanizedDelayMs, 150, 1500),
    };
}
'@
Set-Content -Path $migrationPath -Value $migration

$humanTestPath = 'upstream/tests/Mahjong.Plugin.Dalamud.Tests/HumanTimingTests.cs'
if (Test-Path $humanTestPath) {
    $humanTests = Get-Content $humanTestPath -Raw
    $humanTests = $humanTests.Replace('Assert.InRange(delay.TotalMilliseconds, 400.0, 2500.0);', 'Assert.InRange(delay.TotalMilliseconds, 120.0, 1200.0);')
    Set-Content -Path $humanTestPath -Value $humanTests -NoNewline
}


# Explicitly clear previous-match / previous-hand automation state at verified MJAI boundaries.
$autoPath = 'upstream/Mahjong.Plugin.Dalamud/Actions/AutoPlayLoop.cs'
$auto = Get-Content $autoPath -Raw
$oldEventStart = @'
    private void OnPublicServerEvent(IMjaiEvent evt, ServerHandResult? result)
    {
        if (evt is MjaiEndKyoku && result is not null)
'@
$newEventStart = @'
    private void OnPublicServerEvent(IMjaiEvent evt, ServerHandResult? result)
    {
        // end_game/end_kyoku deliberately stop actions until a fresh start_kyoku.
        // When the next game/hand is positively observed, clear any latches and delayed work
        // left by the previous East 4 / result screen before accepting new decisions.
        if (evt is MjaiStartGame)
            ResetAutomationAtNewBoundary("start_game");
        else if (evt is MjaiStartKyoku)
            ResetAutomationAtNewBoundary("start_kyoku");

        if (evt is MjaiEndKyoku && result is not null)
'@
if ($auto.Contains($oldEventStart)) { $auto = $auto.Replace($oldEventStart, $newEventStart) }
elseif (-not $auto.Contains('ResetAutomationAtNewBoundary("start_kyoku")')) { throw 'Public server event boundary insertion point not found.' }

$helperAnchor = '    private void RecordServerActionOutcome(ServerActionOutcomeTracker.Outcome outcome)'
$helper = @'
    private void ResetAutomationAtNewBoundary(string boundary)
    {
        CancelPending();
        handResultFirstSeenAt = null;
        handResultDispatchedThisInstance = false;
        terminalWinDispatchedAt = null;
        pendingTerminalWin = null;
        terminalWinConfirmation.Reset();
        hasMortalWait = false;
        dismissedExpiredPromptKey = null;
        LastActionDescription = $"new {boundary} observed; previous-hand automation state cleared";
        log.Info($"[AutoPlayLoop] Reset previous-hand automation state at {boundary}.");
    }

'@
if (-not $auto.Contains('private void ResetAutomationAtNewBoundary(')) {
    if (-not $auto.Contains($helperAnchor)) { throw 'Boundary reset helper insertion point not found.' }
    $auto = $auto.Replace($helperAnchor, $helper + $helperAnchor)
}

# Emit one transition log for the AwaitingNextHand gate, so a missing start_kyoku is diagnosable.
$auto = $auto.Replace(
    '    private bool disposed;',
    '    private bool disposed;' + [Environment]::NewLine + '    private bool? lastAwaitingNextHand;')
$oldAwaiting = @'
        if (plugin.PublicState.AwaitingNextHand)
        {
            CheckStuckStateAndEmit(null);
            EmitSkipReason("server result confirmed; waiting for next hand", -1, -1, 0);
            return;
        }
'@
$newAwaiting = @'
        bool awaitingNextHand = plugin.PublicState.AwaitingNextHand;
        if (lastAwaitingNextHand != awaitingNextHand)
        {
            lastAwaitingNextHand = awaitingNextHand;
            log.Info($"[AutoPlayLoop] AwaitingNextHand={awaitingNextHand}; addonState={ReadStateCode()}.");
        }
        if (awaitingNextHand)
        {
            CheckStuckStateAndEmit(null);
            EmitSkipReason("server result confirmed; waiting for next hand", -1, -1, 0);
            return;
        }
'@
if ($auto.Contains($oldAwaiting)) { $auto = $auto.Replace($oldAwaiting, $newAwaiting) }
elseif (-not $auto.Contains('bool awaitingNextHand = plugin.PublicState.AwaitingNextHand;')) { throw 'AwaitingNextHand gate insertion point not found.' }
Set-Content -Path $autoPath -Value $auto -NoNewline


# Tsumogiri policy must never make an open call. Keep legal wins, pass all other
# opponent/self-call prompts, and recover a post-call discard with the normal legal policy.
$autoPath = 'upstream/Mahjong.Plugin.Dalamud/Actions/AutoPlayLoop.cs'
$auto = Get-Content $autoPath -Raw

$oldCallChoice = @'
            if (!TryChoose(snap, out var choice))
            {
                LastActionDescription = "waiting for Mortal call decision";
                fsm.ClearContext();
                return;
            }
'@
$newCallChoice = $oldCallChoice
if ($auto.Contains('tsumogiri mode: decline calls and wait for own draw'))
{
    $auto = $auto.Replace(@'
            ActionChoice choice;
            if (plugin.Configuration.AutoPlayMode == AutoPlayMode.Tsumogiri)
            {
                hasMortalWait = false;
                if (snap.Legal.Can(ActionFlags.Tsumo))
                    choice = ActionChoice.DeclareTsumo("tsumogiri mode: accept legal self-draw win");
                else if (snap.Legal.Can(ActionFlags.Ron))
                    choice = ActionChoice.DeclareRon("tsumogiri mode: accept legal discard win");
                else if (snap.Legal.Can(ActionFlags.Pass))
                    choice = ActionChoice.Pass("tsumogiri mode: decline calls and wait for own draw");
                else
                {
                    LastActionDescription = "tsumogiri mode: no legal pass/win action; waiting without calling";
                    fsm.ClearContext();
                    return;
                }
            }
            else if (!TryChoose(snap, out choice))
            {
                LastActionDescription = "waiting for Mortal call decision";
                fsm.ClearContext();
                return;
            }
'@, $oldCallChoice)
}

Set-Content -Path $autoPath -Value $auto -NoNewline


# Strict feeder mode: pass every opponent call and every Ron/Tsumo confirmation.
# The own-draw discard path and slot-13 validation are patched earlier in this script.
$autoPath = 'upstream/Mahjong.Plugin.Dalamud/Actions/AutoPlayLoop.cs'
$auto = (Get-Content $autoPath -Raw) -replace "\r\n", [string][char]10

$callStart = $auto.IndexOf('    private void ScheduleCallDecision(DispatchContext context)')
$callEnd = $auto.IndexOf('    private void ScheduleTerminalWinConfirmation(', $callStart)
if ($callStart -lt 0 -or $callEnd -lt 0) { throw 'ScheduleCallDecision method boundaries not found.' }
$callBlock = $auto.Substring($callStart, $callEnd - $callStart)
$callPattern = '(?s)            if \(!TryChoose\(snap, out var choice\)\)\s*\{\s*                LastActionDescription = "waiting for Mortal call decision";\s*                fsm\.ClearContext\(\);\s*                return;\s*            \}'
$callReplacement = @'
            ActionChoice choice;
            if (plugin.Configuration.AutoPlayMode == AutoPlayMode.Tsumogiri)
            {
                hasMortalWait = false;
                if (!snap.Legal.Can(ActionFlags.Pass))
                {
                    LastActionDescription = "tsumogiri paused: call prompt has no legal Pass";
                    fsm.ClearContext();
                    return;
                }
                choice = ActionChoice.Pass("strict tsumogiri: pass every call and win prompt");
            }
            else if (!TryChoose(snap, out choice))
            {
                LastActionDescription = "waiting for Mortal call decision";
                fsm.ClearContext();
                return;
            }
'@
$updatedCall = [regex]::Replace($callBlock, $callPattern, $callReplacement.TrimEnd(), 1)
if ($updatedCall -eq $callBlock -and -not $callBlock.Contains('strict tsumogiri: pass every call and win prompt')) {
    throw 'ScheduleCallDecision choice block not found.'
}
$auto = $auto.Substring(0, $callStart) + $updatedCall + $auto.Substring($callEnd)

$terminalStart = $auto.IndexOf('    private void ScheduleTerminalWinConfirmation(')
$terminalEnd = $auto.IndexOf('    private bool TryChoose(', $terminalStart)
if ($terminalStart -lt 0 -or $terminalEnd -lt 0) { throw 'Terminal confirmation method boundaries not found.' }
$terminalBlock = $auto.Substring($terminalStart, $terminalEnd - $terminalStart)
$terminalPattern = '(?s)            var choice = kind == ActionKind\.Ron\s*\? ActionChoice\.DeclareRon\("terminal win confirmation"\)\s*: ActionChoice\.DeclareTsumo\("terminal win confirmation"\);\s*            EmitDecisionFinding\("terminal-win-confirm", snap, choice\);\s*            DispatchCallChoice\(snap, choice\);'
$terminalReplacement = @'
            if (plugin.Configuration.AutoPlayMode == AutoPlayMode.Tsumogiri)
            {
                if (!snap.Legal.Can(ActionFlags.Pass))
                {
                    terminalWinConfirmation.Reset();
                    LastActionDescription = "tsumogiri paused: terminal confirmation has no legal Pass";
                    fsm.ClearContext();
                    return;
                }
                var pass = ActionChoice.Pass("strict tsumogiri: decline terminal win confirmation");
                EmitDecisionFinding("terminal-win-pass", snap, pass);
                DispatchCallChoice(snap, pass);
                terminalWinConfirmation.Reset();
                return;
            }

            var choice = kind == ActionKind.Ron
                ? ActionChoice.DeclareRon("terminal win confirmation")
                : ActionChoice.DeclareTsumo("terminal win confirmation");
            EmitDecisionFinding("terminal-win-confirm", snap, choice);
            DispatchCallChoice(snap, choice);
'@
$updatedTerminal = [regex]::Replace($terminalBlock, $terminalPattern, $terminalReplacement.TrimEnd(), 1)
if ($updatedTerminal -eq $terminalBlock -and -not $terminalBlock.Contains('strict tsumogiri: decline terminal win confirmation')) {
    throw 'Terminal win confirmation choice block not found.'
}
$auto = $auto.Substring(0, $terminalStart) + $updatedTerminal + $auto.Substring($terminalEnd)
Set-Content -Path $autoPath -Value $auto -NoNewline

# Single-player version in the window title.
$window = Get-Content $windowPath -Raw
if (-not $window.Contains('private const string BuildUiVersion')) {
    $window = $window.Replace(
        '    private readonly Plugin plugin;',
        '    private const string BuildUiVersion = "SP1.6";' + [Environment]::NewLine + '    private readonly Plugin plugin;')
}
$window = $window.Replace(
    ': base("Doman Mahjong Solver###domanmahjong-main")',
    ': base($"Doman Mahjong Solver {BuildUiVersion}###domanmahjong-main")')
$oldTitle = 'WindowName = Loc.T("Doman Mahjong Solver", "多玛麻将助手") + "###domanmahjong-main";'
$newTitle = 'WindowName = Loc.T("Doman Mahjong Solver", "多玛麻将助手") + " " + BuildUiVersion + "###domanmahjong-main";'
if ($window.Contains($oldTitle)) { $window = $window.Replace($oldTitle, $newTitle) }
Set-Content -Path $windowPath -Value $window -NoNewline

Write-Host 'Applied single-player options, independent auto-queue, validated tsumogiri and full-match limit.'
