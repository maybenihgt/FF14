$ErrorActionPreference = 'Stop'

$sourceFile = 'integration-repo/integration/lan-peer/LanPeerDiscovery.cs'
$destinationDir = 'upstream/Mahjong.Plugin.Dalamud/Networking'
New-Item -ItemType Directory -Force -Path $destinationDir | Out-Null
Copy-Item $sourceFile (Join-Path $destinationDir 'LanPeerDiscovery.cs') -Force
$publicSyncSource = 'integration-repo/integration/lan-peer/PublicTableStateSync.cs'
Copy-Item $publicSyncSource (Join-Path $destinationDir 'PublicTableStateSync.cs') -Force
$handSyncSource = 'integration-repo/integration/lan-peer/FourPlayerHandSync.cs'
Copy-Item $handSyncSource (Join-Path $destinationDir 'FourPlayerHandSync.cs') -Force

$configPath = 'upstream/Mahjong.Plugin.Dalamud/Configuration.cs'
$config = Get-Content $configPath -Raw
$configMarker = '    public Guid InstallId { get; init; } = Guid.Empty;'
$configAdd = @'
    public bool LanPeerDiscoveryEnabled { get; init; } = false;

    /// <summary>Local account role. Defaults to small; only explicit selection marks this client as a big account.</summary>
    public string LanPeerAccountType { get; init; } = "小号";

    /// <summary>Opt-in transmission of visible public table data only; concealed hands and legal actions are never sent.</summary>
    public bool PublicStateSyncEnabled { get; init; } = false;

'@
if (-not $config.Contains($configMarker)) { throw 'Configuration insertion marker not found.' }
if (-not $config.Contains('LanPeerDiscoveryEnabled')) {
    $config = $config.Replace($configMarker, $configAdd + $configMarker)
    Set-Content -Path $configPath -Value $config -NoNewline
}

$pluginPath = 'upstream/Mahjong.Plugin.Dalamud/Plugin.cs'
$plugin = Get-Content $pluginPath -Raw
$usingMarker = 'using Mahjong.Plugin.Dalamud.Mortal;'
if (-not $plugin.Contains('using Mahjong.Plugin.Dalamud.Networking;')) {
    if (-not $plugin.Contains($usingMarker)) { throw 'Plugin using insertion marker not found.' }
    $plugin = $plugin.Replace($usingMarker, $usingMarker + [Environment]::NewLine + 'using Mahjong.Plugin.Dalamud.Networking;')
}
$propertyMarker = '    public PublicStateTracker PublicState { get; }'
if (-not $plugin.Contains('public LanPeerDiscovery LanPeers { get; }')) {
    if (-not $plugin.Contains($propertyMarker)) { throw 'Plugin property insertion marker not found.' }
    $plugin = $plugin.Replace($propertyMarker, $propertyMarker + [Environment]::NewLine + '    public LanPeerDiscovery LanPeers { get; }')
}
if (-not $plugin.Contains('public PublicTableStateSync PublicTableSync { get; }')) {
    $plugin = $plugin.Replace('    public LanPeerDiscovery LanPeers { get; }',
        '    public LanPeerDiscovery LanPeers { get; }' + [Environment]::NewLine + '    public PublicTableStateSync PublicTableSync { get; }')
}
if (-not $plugin.Contains('public FourPlayerHandSync HandSync { get; }')) {
    $plugin = $plugin.Replace('    public PublicTableStateSync PublicTableSync { get; }',
        '    public PublicTableStateSync PublicTableSync { get; }' + [Environment]::NewLine + '    public ConsentedHandSync HandSync { get; }')
}
$aggregatorMarker = '        Aggregator = new StateAggregator(AddonReader, Framework, Policy, PublicState.Merge, () => Configuration);'
$syncCreate = @'
        LanPeers = new LanPeerDiscovery(
            () => Configuration.LanPeerDiscoveryEnabled,
            () => Configuration.LanPeerAccountType,
            () => Aggregator.Latest);
        PublicTableSync = new PublicTableStateSync(
            LanPeers.InstanceId,
            () => LanPeers.AccountType,
            () => Configuration.LanPeerDiscoveryEnabled && Configuration.PublicStateSyncEnabled,
            () => Aggregator.Latest);
        HandSync = new FourPlayerHandSync(
            LanPeers,
            () => Configuration.LanPeerDiscoveryEnabled,
            () => Aggregator.Latest);
'@
if (-not $plugin.Contains('LanPeers = new LanPeerDiscovery(')) {
    if (-not $plugin.Contains($aggregatorMarker)) { throw 'Aggregator initialization marker not found.' }
    $plugin = $plugin.Replace($aggregatorMarker, $aggregatorMarker + [Environment]::NewLine + $syncCreate.TrimEnd())
}
$disposeMarker = '        PluginInterface.LanguageChanged -= Loc.SetLanguage;'
if (-not $plugin.Contains('        LanPeers.Dispose();')) {
    if (-not $plugin.Contains($disposeMarker)) { throw 'Plugin dispose marker not found.' }
    $plugin = $plugin.Replace($disposeMarker, $disposeMarker + [Environment]::NewLine + '        HandSync.Dispose();' + [Environment]::NewLine + '        PublicTableSync.Dispose();' + [Environment]::NewLine + '        LanPeers.Dispose();')
}
Set-Content -Path $pluginPath -Value $plugin -NoNewline

$windowPath = 'upstream/Mahjong.Plugin.Dalamud/UI/MainWindow.cs'
$window = Get-Content $windowPath -Raw
$drawOld = @'
        DrawModeCard(cfg);
        ImGui.Dummy(new Vector2(0, 4));
        DrawCollectionCard(cfg);
        ImGui.Dummy(new Vector2(0, 4));
        DrawLiveCard();

        DrawAutoPlayConfirmModal(cfg);
'@
$drawNew = @'
        if (ImGui.BeginTabBar("##mahjong-main-mode-tabs"))
        {
            if (ImGui.BeginTabItem(Loc.T("Single-player", "单人模式")))
            {
                DrawModeCard(cfg);
                ImGui.Dummy(new Vector2(0, 4));
                DrawCollectionCard(cfg);
                ImGui.Dummy(new Vector2(0, 4));
                DrawLiveCard();
                ImGui.EndTabItem();
            }

            if (ImGui.BeginTabItem(Loc.T("Multiplayer", "多人模式")))
            {
                DrawLanPeerCard(cfg);
                ImGui.EndTabItem();
            }

            ImGui.EndTabBar();
        }

        DrawAutoPlayConfirmModal(cfg);
'@
if (-not $window.Contains('if (ImGui.BeginTabBar("##mahjong-main-mode-tabs"))')) {
    if (-not $window.Contains($drawOld)) { throw 'Main window draw block not found.' }
    $window = $window.Replace($drawOld, $drawNew)
}
$methodMarker = '    private void DrawCollectionCard(Configuration cfg)'
$method = @'
    private void DrawLanPeerCard(Configuration cfg)
    {
        using (Theme.BeginCard("lan-four-player-room"))
        {
            Theme.SectionHeader(Loc.T("Four-player table", "四人桌"));
            ImGui.TextWrapped(Loc.T(
                "Join the same UU cloud LAN room on all four PCs. Enable this on each PC; the plugin will list the four clients automatically. No plugin room code is needed.",
                "四台电脑先手动加入同一个 UU 云联机房间，再分别开启这里的节点发现。插件会自动列出四个客户端，不需要额外房间码。"));

            bool enabled = cfg.LanPeerDiscoveryEnabled;
            if (ImGui.Checkbox(Loc.T("Join four-player table / enable discovery", "加入四人桌 / 启用节点发现") + "##lan-peer-enabled", ref enabled))
                plugin.ConfigService.Update(c => c with { LanPeerDiscoveryEnabled = enabled });

            ImGui.Separator();
            ImGui.TextUnformatted(Loc.T("This client account type", "本机账号类型"));
            bool isBig = cfg.LanPeerAccountType == "大号";
            if (ImGui.RadioButton(Loc.T("Small account", "小号") + "##lan-peer-small", !isBig))
                plugin.ConfigService.Update(c => c with { LanPeerAccountType = "小号" });
            ImGui.SameLine();
            if (ImGui.RadioButton(Loc.T("Big account", "大号") + "##lan-peer-big", isBig))
                plugin.ConfigService.Update(c => c with { LanPeerAccountType = "大号" });
            ImGui.Separator();
            if (plugin.HandSync.IsPrivateFourAccountTable)
                Theme.Subtle(Loc.T("Private 2-big / 2-small table verified. Hands are shared automatically.",
                    "已识别 2 大号 + 2 小号的四账号同桌，正在自动共享四家手牌。"));
            else
                Theme.Subtle(Loc.T("Private four-account table not verified. Hand sharing is off; outsider-safe strategy is active.",
                    "尚未确认四个自有账号同桌，手牌共享关闭，已切换为有外人时的策略。"));

            var remoteHands = plugin.HandSync.RemoteHands;
            if (plugin.HandSync.IsPrivateFourAccountTable)
            {
                var handSnapshot = plugin.Aggregator.Latest;
                if (handSnapshot is not null && handSnapshot.Hand.Count is 13 or 14)
                {
                    string localTiles = string.Join(" ", handSnapshot.Hand.Select((tile, index) =>
                        tile.ShortName + (index < handSnapshot.HandIsRed.Count && handSnapshot.HandIsRed[index] ? "*" : "")));
                    ImGui.TextWrapped($"本机 {cfg.LanPeerAccountType} / 大号序号 {plugin.LanPeers.BigAccountOrdinal} | 手牌：{localTiles}");
                }
                foreach (var sharedHand in remoteHands)
                {
                    string tiles = string.Join(" ", sharedHand.HandTiles.Select((id, index) =>
                        new Mahjong.Core.Tile((byte)id).ShortName +
                        (index < sharedHand.HandIsRed.Length && sharedHand.HandIsRed[index] ? "*" : "")));
                    string wind = sharedHand.SeatWind switch { 0 => "东", 1 => "南", 2 => "西", 3 => "北", _ => "?" };
                    ImGui.TextWrapped($"{sharedHand.AccountType} | {wind}家 | {sharedHand.DisplayName} | {tiles}");
                }
                Theme.Subtle(Loc.T(
                    $"Matching remote hands received: {remoteHands.Count}/3",
                    $"已收到匹配的其他手牌：{remoteHands.Count}/3"));
            }
            else
            {
                Theme.Subtle(Loc.T(
                    $"Same-table clients: {plugin.HandSync.SameTableClientCount}/4. Automatic sharing requires exactly 2 big and 2 small clients on the same verified table.",
                    $"同桌客户端：{plugin.HandSync.SameTableClientCount}/4。自动共享要求同一张已验证牌桌上恰好有 2 个大号和 2 个小号。"));
            }
            if (!string.IsNullOrWhiteSpace(plugin.HandSync.LastError))
                Theme.Subtle(plugin.HandSync.LastError);

            Theme.Subtle(Loc.T(
                $"Current role: {cfg.LanPeerAccountType}",
                $"当前身份：{(isBig ? $"大号 {plugin.LanPeers.BigAccountOrdinal}" : "小号")}（默认小号，只有主动选择大号才会标记为大号）"));

            ImGui.Separator();
            var roster = plugin.LanPeers.Roster;
            int visibleCount = Math.Min(4, roster.Count);
            Theme.SectionHeader(Loc.T(
                $"Four-player table members · {visibleCount}/4",
                $"四人桌成员 · {visibleCount}/4"));

            if (!enabled)
            {
                Theme.Subtle(Loc.T(
                    "Not joined yet. Enable discovery after joining the same UU room on this PC.",
                    "尚未加入。请先在本机加入相同 UU 房间，再开启节点发现。"));
            }
            else if (roster.Count == 1)
            {
                Theme.Subtle(Loc.T(
                    "This client is online. Waiting for the other three clients.",
                    "本机已在线，正在等待另外三台客户端。"));
            }

            for (int i = 0; i < 4; i++)
            {
                if (i < visibleCount)
                {
                    var member = roster[i];
                    bool local = member.InstanceId == plugin.LanPeers.InstanceId;
                    string origin = local
                        ? Loc.T("This PC", "本机")
                        : member.Address;
                    string tableStatus = member.MatchKey == plugin.LanPeers.CurrentMatchKey && !string.IsNullOrEmpty(member.MatchKey)
                        ? "当前牌桌" : "非当前牌桌/未识别";
                    int bigOrder = member.AccountType == "大号"
                        ? plugin.LanPeers.SameTableRoster.Where(x => x.AccountType == "大号")
                            .OrderBy(x => x.InstanceId, StringComparer.Ordinal)
                            .TakeWhile(x => x.InstanceId != member.InstanceId).Count() + 1
                        : 0;
                    string role = member.AccountType == "大号" ? $"大号 {bigOrder}" : "小号";
                    ImGui.BulletText($"{i + 1}. {role} | {origin} | {tableStatus} | {member.PluginVersion}");
                }
                else
                {
                    ImGui.TextDisabled(
                        Loc.T($"{i + 1}. Waiting for a client...", $"{i + 1}. 等待客户端加入..."));
                }
            }

            if (roster.Count > 4)
                Theme.Subtle(Loc.T(
                    $"There are {roster.Count - 4} additional plugin instances on this visible subnet; only four are shown in this table list.",
                    $"当前可见子网还有 {roster.Count - 4} 个额外插件实例；四人桌列表只显示前四个。"));

            ImGui.Separator();
            Theme.SectionHeader(Loc.T("Public table-state sync", "公共牌局状态同步"));
            bool syncEnabled = cfg.PublicStateSyncEnabled;
            if (ImGui.Checkbox(Loc.T("Share visible table state with this LAN", "向局域网同步公开牌局状态") + "##public-state-sync", ref syncEnabled))
                plugin.ConfigService.Update(c => c with { PublicStateSyncEnabled = syncEnabled });
            Theme.Subtle(Loc.T(
                "Only public information is sent: scores, visible discards, melds, riichi markers, dora indicators, round and wall count. Your concealed hand, draw, legal actions, recommendations and ura-dora are never transmitted.",
                "只发送公开信息：分数、可见牌河、副露、立直标记、宝牌指示牌、局况和剩余牌墙。绝不发送本机暗手牌、摸牌信息、合法操作、AI 推荐或里宝牌。"));

            if (!enabled && syncEnabled)
                Theme.Subtle(Loc.T("Enable node discovery first; public-state sync stays paused until then.", "请先开启节点发现；在此之前公共状态同步不会运行。"));

            var publicLocalSnapshot = plugin.Aggregator.Latest;
            if (publicLocalSnapshot is null)
                Theme.Subtle(Loc.T("Local table state: waiting for a table.", "本机牌局状态：等待进入牌桌。"));
            else if (!publicLocalSnapshot.PublicStateConsistent)
                Theme.Subtle(Loc.T("Local public state is not verified yet; it will not be broadcast.", "本机公共状态尚未通过一致性校验，不会广播。"));
            else
                Theme.Subtle(Loc.T("Local public state: available.", "本机公共状态：可用。"));

            var sharedStates = plugin.PublicTableSync.RemoteStates;
            Theme.Subtle(Loc.T($"Remote public states received: {sharedStates.Count}", $"已收到其他客户端公共状态：{sharedStates.Count}"));
            foreach (var state in sharedStates)
            {
                string wind = state.RoundWind switch { 0 => "东", 1 => "南", 2 => "西", 3 => "北", _ => "?" };
                string scoreText = string.Join("/", state.Scores);
                if (ImGui.TreeNode($"{state.AccountType} | {state.Address} | {wind}{state.Kyoku}局##public-{state.InstanceId}"))
                {
                    ImGui.Text($"剩余牌墙：{state.WallRemaining}  本场：{state.Honba}  分数：{scoreText}");
                    ImGui.TextWrapped("宝牌指示牌：" + string.Join(" ", state.DoraIndicators.Select(id => new Mahjong.Core.Tile((byte)id).ShortName)));
                    for (int seatIndex = 0; seatIndex < state.Seats.Length; seatIndex++)
                    {
                        var seat = state.Seats[seatIndex];
                        string riverText = string.Join(" ", seat.Discards.Select((id, index) =>
                            new Mahjong.Core.Tile((byte)id).ShortName +
                            (index < seat.DiscardIsRed.Length && seat.DiscardIsRed[index] ? "*" : "") +
                            (index < seat.DiscardWasCalled.Length && seat.DiscardWasCalled[index] ? "×" : "")));
                        string meldText = string.Join(" / ", seat.Melds.Select(m =>
                            (m.Kind switch { 0 => "吃", 1 => "碰", 2 => "暗杠", 3 => "明杠", 4 => "加杠", _ => "副露" }) +
                            "[" + string.Join(" ", m.Tiles.Select(id => new Mahjong.Core.Tile((byte)id).ShortName)) + "]"));
                        ImGui.TextWrapped($"座位 {seatIndex}：河 {riverText} | 副露 {meldText} | 立直 {(seat.Riichi ? "是" : "否")}");
                    }
                    ImGui.TreePop();
                }
            }

            if (!string.IsNullOrWhiteSpace(plugin.PublicTableSync.LastError))
                Theme.Subtle(plugin.PublicTableSync.LastError);
            Theme.Subtle(Loc.T(
                "Public-state packets use UDP 47722. Private hands use UDP 47723 and only activate for the matched 2-big / 2-small table.",
                "公开状态使用 UDP 47722。四家暗手牌使用 UDP 47723，只有识别到 2 大号 + 2 小号同桌时才自动开启。"));

            if (!string.IsNullOrWhiteSpace(plugin.LanPeers.LastError))
                Theme.Subtle(plugin.LanPeers.LastError);

            ImGui.Separator();
            Theme.Subtle(Loc.T(
                "Discovery uses the local IPv4 subnet and UDP 47721. Other plugin users on the same subnet may also be detected; the list is not an authoritative UU room-member list.",
                "节点发现基于本机可见 IPv4 子网和 UDP 47721。同一子网的其他插件用户也可能被发现；列表并不是 UU 房间成员的权威名单。"));
            Theme.Subtle(Loc.T(
                "The game addon snapshot has no player-name field. A private table is recognized conservatively by 4 same-LAN clients with the same match key and exactly 2 big / 2 small roles.",
                "当前游戏快照不含玩家姓名字段。插件通过同一局域网 4 个客户端、相同牌局指纹及恰好 2 大号 + 2 小号进行保守识别。"));
        }
    }

'@
if (-not $window.Contains('    private void DrawLanPeerCard(Configuration cfg)')) {
    if (-not $window.Contains($methodMarker)) { throw 'Main window method insertion marker not found.' }
    $window = $window.Replace($methodMarker, $method + $methodMarker)
}
Set-Content -Path $windowPath -Value $window -NoNewline

Write-Host 'LAN peer discovery, public table-state sync and automatic private four-hand sync overlays applied.'
