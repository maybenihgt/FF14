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

    /// <summary>Shared random LAN room secret. Only an HMAC is transmitted; the secret itself is never sent.</summary>
    public string LanPeerRoomCode { get; init; } = "";

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
            () => Configuration.LanPeerAccountLabel,
            () => Configuration.LanPeerRoomCode);
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
if (-not $window.Contains('using System.Security.Cryptography;')) {
    $window = $window.Replace('using System.Numerics;', 'using System.Numerics;' + [Environment]::NewLine + 'using System.Security.Cryptography;')
}
$drawMarker = '        DrawModeCard(cfg);'
if (-not $window.Contains('        DrawLanPeerCard(cfg);')) {
    if (-not $window.Contains($drawMarker)) { throw 'Main window draw insertion marker not found.' }
    $window = $window.Replace($drawMarker, $drawMarker + [Environment]::NewLine + '        ImGui.Dummy(new Vector2(0, 4));' + [Environment]::NewLine + '        DrawLanPeerCard(cfg);')
}
$methodMarker = '    private void DrawCollectionCard(Configuration cfg)'
$method = @'
    private void DrawLanPeerCard(Configuration cfg)
    {
        using (Theme.BeginCard("lan-peer-discovery"))
        {
            Theme.SectionHeader(Loc.T("UU LAN peers", "UU 局域网节点"));
            ImGui.TextWrapped(Loc.T(
                "Discovers other plugin instances on the same virtual LAN. Only account label, plugin version and online presence are exchanged; game state and tiles are never sent.",
                "自动发现同一虚拟局域网内的插件实例。只交换账号标签、插件版本和在线状态，不发送游戏状态或手牌。"));

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

            ImGui.TextUnformatted(Loc.T("Shared room code (same on every PC; 12+ characters)", "共享房间码（所有电脑必须一致，至少 12 个字符）"));
            string roomCode = cfg.LanPeerRoomCode;
            ImGui.SetNextItemWidth(-1);
            if (ImGui.InputText("##lan-peer-room-code", ref roomCode, 128))
                plugin.ConfigService.Update(c => c with { LanPeerRoomCode = roomCode.Trim() });
            if (ImGui.Button(Loc.T("Generate and copy room code", "生成并复制房间码") + "##lan-peer-generate"))
            {
                string generated = Convert.ToHexString(RandomNumberGenerator.GetBytes(16));
                plugin.ConfigService.Update(c => c with { LanPeerRoomCode = generated });
                ImGui.SetClipboardText(generated);
            }

            ImGui.Separator();
            var peers = plugin.LanPeers.Peers;
            Theme.Subtle(Loc.T($"Discovered peers: {peers.Count}", $"已发现节点：{peers.Count}"));
            if (peers.Count == 0)
                Theme.Subtle(Loc.T("No peers yet. Enable discovery on both PCs, use the same room code, and allow inbound UDP 47721 on the private network.", "尚未发现其他节点。请在两台电脑启用发现、填写相同房间码，并允许专用网络的 UDP 47721 入站。"));
            foreach (var peer in peers)
                ImGui.BulletText($"{peer.AccountLabel}  |  {peer.Address}  |  {peer.LastSeenUtc.ToLocalTime():HH:mm:ss}");

            if (!string.IsNullOrWhiteSpace(plugin.LanPeers.LastError))
                Theme.Subtle(plugin.LanPeers.LastError);
            Theme.Subtle(Loc.T("Peers expire after 8 seconds without a heartbeat. UDP broadcast may be blocked by some VPN adapters or firewall profiles.", "节点连续 8 秒没有心跳就会消失。部分虚拟网卡或防火墙配置可能会阻止 UDP 广播。"));
        }
    }

'@
if (-not $window.Contains('    private void DrawLanPeerCard(Configuration cfg)')) {
    if (-not $window.Contains($methodMarker)) { throw 'Main window method insertion marker not found.' }
    $window = $window.Replace($methodMarker, $method + $methodMarker)
}
Set-Content -Path $windowPath -Value $window -NoNewline

Write-Host 'LAN peer discovery overlay applied. Protocol exchanges authenticated presence only; no game-state payload is defined.'
