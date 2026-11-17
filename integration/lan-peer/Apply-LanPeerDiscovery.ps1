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

    /// <summary>One of MAIN_A, MAIN_B, ALT_C or ALT_D. This is a display label, not an account credential.</summary>
    public string LanPeerAccountLabel { get; init; } = "MAIN_A";

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
            () => Configuration.LanPeerAccountLabel);
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
        using (Theme.BeginCard("lan-peer-discovery"))
        {
            Theme.SectionHeader(Loc.T("UU LAN peers", "UU 局域网节点"));
            ImGui.TextWrapped(Loc.T(
                "Join the same UU cloud LAN room on each PC. The plugin discovers peers automatically; no separate plugin room code is needed.",
                "每台电脑手动加入同一个 UU 云联机房间即可。插件会自动发现节点，不需要额外的插件房间码。"));

            bool enabled = cfg.LanPeerDiscoveryEnabled;
            if (ImGui.Checkbox(Loc.T("Enable peer discovery", "启用节点发现") + "##lan-peer-enabled", ref enabled))
                plugin.ConfigService.Update(c => c with { LanPeerDiscoveryEnabled = enabled });

            ImGui.TextUnformatted(Loc.T("This client label", "本机账号标签"));
            if (ImGui.Button("MAIN_A##lan-peer-label-a")) plugin.ConfigService.Update(c => c with { LanPeerAccountLabel = "MAIN_A" });
            ImGui.SameLine();
            if (ImGui.Button("MAIN_B##lan-peer-label-b")) plugin.ConfigService.Update(c => c with { LanPeerAccountLabel = "MAIN_B" });
            ImGui.SameLine();
            if (ImGui.Button("ALT_C##lan-peer-label-c")) plugin.ConfigService.Update(c => c with { LanPeerAccountLabel = "ALT_C" });
            ImGui.SameLine();
            if (ImGui.Button("ALT_D##lan-peer-label-d")) plugin.ConfigService.Update(c => c with { LanPeerAccountLabel = "ALT_D" });
            Theme.Subtle(Loc.T($"Selected label: {cfg.LanPeerAccountLabel}", $"当前标签：{cfg.LanPeerAccountLabel}"));

            ImGui.Separator();
            var peers = plugin.LanPeers.Peers;
            Theme.Subtle(Loc.T($"Discovered peers: {peers.Count}", $"已发现节点：{peers.Count}"));
            if (peers.Count == 0)
                Theme.Subtle(Loc.T(
                    "No peers yet. Enable discovery on each PC and allow inbound UDP 47721 on the Windows Private firewall profile. UU must forward IPv4 broadcast traffic.",
                    "尚未发现节点。请在每台电脑启用节点发现，并允许 Windows 专用网络的 UDP 47721 入站；UU 网络需要支持转发 IPv4 广播。"));
            foreach (var peer in peers)
                ImGui.BulletText($"{peer.AccountLabel}  |  {peer.Address}  |  {peer.LastSeenUtc.ToLocalTime():HH:mm:ss}");

            if (!string.IsNullOrWhiteSpace(plugin.LanPeers.LastError))
                Theme.Subtle(plugin.LanPeers.LastError);

            Theme.Subtle(Loc.T(
                "Discovery is limited to the same local IPv4 subnet. Other plugin users on that subnet may also appear. Only instance ID, account label, plugin version and timestamp are broadcast; these presence packets are not cryptographically authenticated.",
                "发现范围是本机可见的 IPv4 子网。同一子网内其他启用插件的用户也可能出现。广播内容只有实例 ID、账号标签、插件版本和时间戳；在线广播不提供密码学身份认证。"));
            Theme.Subtle(Loc.T(
                "Peers expire after 8 seconds without a heartbeat. Some virtual-LAN adapters or firewall settings may block UDP broadcast.",
                "节点连续 8 秒没有心跳就会消失。部分虚拟网卡或防火墙设置可能阻止 UDP 广播。"));
        }
    }

'@'@
if (-not $window.Contains('    private void DrawLanPeerCard(Configuration cfg)')) {
    if (-not $window.Contains($methodMarker)) { throw 'Main window method insertion marker not found.' }
    $window = $window.Replace($methodMarker, $method + $methodMarker)
}
Set-Content -Path $windowPath -Value $window -NoNewline

Write-Host 'LAN peer discovery overlay applied. No app room code; same-subnet presence only; no game-state payload is defined.'
