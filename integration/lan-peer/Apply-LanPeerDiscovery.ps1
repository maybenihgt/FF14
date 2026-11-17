$ErrorActionPreference = 'Stop'

$sourceFile = 'integration-repo/integration/lan-peer/LanPeerDiscovery.cs'
$destinationDir = 'upstream/Mahjong.Plugin.Dalamud/Networking'
New-Item -ItemType Directory -Force -Path $destinationDir | Out-Null
Copy-Item $sourceFile (Join-Path $destinationDir 'LanPeerDiscovery.cs') -Force

$configPath = 'upstream/Mahjong.Plugin.Dalamud/Configuration.cs'
$config = Get-Content $configPath -Raw
$configMarker = '    public Guid InstallId { get; init; } = Guid.Empty;'
$configAdd = @'
    public bool LanPeerDiscoveryEnabled { get; init; } = false;

    /// <summary>Local account role. Defaults to small; only explicit selection marks this client as a big account.</summary>
    public string LanPeerAccountType { get; init; } = "小号";

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
$configServiceMarker = '        ConfigService = Services.GetRequiredService<IConfigService<Configuration>>();'
$createPeers = @'
        LanPeers = new LanPeerDiscovery(
            () => Configuration.LanPeerDiscoveryEnabled,
            () => Configuration.LanPeerAccountType);
'@
if (-not $plugin.Contains('LanPeers = new LanPeerDiscovery(')) {
    if (-not $plugin.Contains($configServiceMarker)) { throw 'Plugin service initialization marker not found.' }
    $plugin = $plugin.Replace($configServiceMarker, $configServiceMarker + [Environment]::NewLine + $createPeers.TrimEnd())
}
$disposeMarker = '        PluginInterface.LanguageChanged -= Loc.SetLanguage;'
if (-not $plugin.Contains('        LanPeers.Dispose();')) {
    if (-not $plugin.Contains($disposeMarker)) { throw 'Plugin dispose marker not found.' }
    $plugin = $plugin.Replace($disposeMarker, $disposeMarker + [Environment]::NewLine + '        LanPeers.Dispose();')
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
            Theme.Subtle(Loc.T(
                $"Current role: {cfg.LanPeerAccountType}",
                $"当前身份：{(isBig ? "大号" : "小号")}（默认小号，只有主动选择大号才会标记为大号）"));

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
                    ImGui.BulletText(
                        $"{i + 1}. {member.AccountType}  |  {origin}  |  {member.PluginVersion}");
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

            if (!string.IsNullOrWhiteSpace(plugin.LanPeers.LastError))
                Theme.Subtle(plugin.LanPeers.LastError);

            ImGui.Separator();
            Theme.Subtle(Loc.T(
                "Discovery uses the local IPv4 subnet and UDP 47721. Other plugin users on the same subnet may also be detected; the list is not an authoritative UU room-member list.",
                "节点发现基于本机可见 IPv4 子网和 UDP 47721。同一子网的其他插件用户也可能被发现；列表并不是 UU 房间成员的权威名单。"));
            Theme.Subtle(Loc.T(
                "Important: this is the four-client presence roster only. The actual Mahjong match is still run inside FFXIV; this build does not synchronize live hands, discards, scores or actions between clients.",
                "注意：这里目前是四客户端在线名单。真正的麻将对局仍由 FF14 游戏内运行；本版本还不会跨客户端同步实时手牌、牌河、分数或操作。"));
        }
    }

'@
if (-not $window.Contains('    private void DrawLanPeerCard(Configuration cfg)')) {
    if (-not $window.Contains($methodMarker)) { throw 'Main window method insertion marker not found.' }
    $window = $window.Replace($methodMarker, $method + $methodMarker)
}
Set-Content -Path $windowPath -Value $window -NoNewline

Write-Host 'LAN peer discovery overlay applied. No app room code; same-subnet presence only; no game-state payload is defined.'
