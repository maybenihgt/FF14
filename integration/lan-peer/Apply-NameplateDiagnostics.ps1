$ErrorActionPreference = 'Stop'

$readerPath = 'upstream/Mahjong.Plugin.Dalamud/GameState/AddonEmjReader.cs'
$reader = Get-Content $readerPath -Raw

$propertyMarker = '    public LayoutProfile? ActiveLayout { get; private set; }'
$propertyAdd = @'
    /// <summary>Visible text nodes from the current Mahjong addon, used to identify four in-game nameplates.</summary>
    public IReadOnlyList<string> LastTextNodeCandidates { get; private set; } = Array.Empty<string>();

    private long lastTextNodeScanTicks;
'@
if (-not $reader.Contains('LastTextNodeCandidates')) {
    if (-not $reader.Contains($propertyMarker)) { throw 'AddonEmjReader property insertion point not found.' }
    $reader = $reader.Replace($propertyMarker, $propertyMarker + [Environment]::NewLine + $propertyAdd.TrimEnd())
}

$methodMarker = '    public unsafe StateSnapshot? TryBuildSnapshot()'
$method = @'
    private static unsafe IReadOnlyList<string> ReadVisibleTextNodeCandidates(AtkUnitBase* unit)
    {
        if (unit == null || unit->RootNode == null)
            return Array.Empty<string>();

        var output = new List<string>();
        var visited = new HashSet<nint>();
        int budget = 1200;
        CollectVisibleTextNodes(unit->RootNode, output, visited, ref budget);
        return output;
    }

    private static unsafe void CollectVisibleTextNodes(
        AtkResNode* first,
        List<string> output,
        HashSet<nint> visited,
        ref int budget)
    {
        for (AtkResNode* node = first; node != null && budget > 0; node = node->NextSiblingNode)
        {
            nint address = (nint)node;
            if (!visited.Add(address))
                continue;

            budget--;
            AtkTextNode* textNode = node->GetAsAtkTextNode();
            if (textNode != null && node->IsVisible())
            {
                string value = textNode->NodeText.ToString().Trim();
                if (!string.IsNullOrWhiteSpace(value))
                {
                    if (value.Length > 80)
                        value = value[..80];
                    output.Add($"{node->NodeId} @ {node->X:0},{node->Y:0}  {value}");
                }
            }

            if (node->ChildNode != null)
                CollectVisibleTextNodes(node->ChildNode, output, visited, ref budget);
        }
    }

'@
if (-not $reader.Contains('ReadVisibleTextNodeCandidates')) {
    if (-not $reader.Contains($methodMarker)) { throw 'AddonEmjReader method insertion point not found.' }
    $reader = $reader.Replace($methodMarker, $method + $methodMarker)
}

$buildAnchor = @'
        if (!unit->IsVisible)
            return null;

        var variant = selector.Resolve(unit, resolvedName);
'@
$buildReplacement = @'
        if (!unit->IsVisible)
            return null;

        long scanNow = DateTime.UtcNow.Ticks;
        if (scanNow - lastTextNodeScanTicks >= TimeSpan.FromMilliseconds(500).Ticks)
        {
            lastTextNodeScanTicks = scanNow;
            LastTextNodeCandidates = ReadVisibleTextNodeCandidates(unit);
        }

        var variant = selector.Resolve(unit, resolvedName);
'@
if (-not $reader.Contains('LastTextNodeCandidates = ReadVisibleTextNodeCandidates(unit);')) {
    if (-not $reader.Contains($buildAnchor)) { throw 'AddonEmjReader snapshot hook insertion point not found.' }
    $reader = $reader.Replace($buildAnchor, $buildReplacement)
}
Set-Content -Path $readerPath -Value $reader -NoNewline

$windowPath = 'upstream/Mahjong.Plugin.Dalamud/UI/MainWindow.cs'
$window = Get-Content $windowPath -Raw
$windowAnchor = @'
            if (!string.IsNullOrWhiteSpace(plugin.HandSync.LastError))
                Theme.Subtle(plugin.HandSync.LastError);
'@
$windowReplacement = @'
            if (!string.IsNullOrWhiteSpace(plugin.HandSync.LastError))
                Theme.Subtle(plugin.HandSync.LastError);

            ImGui.Separator();
            Theme.SectionHeader(Loc.T(
                $"In-game text nodes · {plugin.AddonReader.LastTextNodeCandidates.Count}",
                $"游戏内文本节点 · {plugin.AddonReader.LastTextNodeCandidates.Count}"));
            Theme.Subtle(Loc.T(
                "Diagnostic scan of visible Emj text nodes. The four character-name labels can be identified here before enabling name-based table matching.",
                "这里列出 Emj 界面中可见文本；先用它定位四个角色名文本节点，再接入角色名同桌校验。"));
            foreach (var candidate in plugin.AddonReader.LastTextNodeCandidates.Take(48))
                ImGui.BulletText(candidate);
'@
if (-not $window.Contains('In-game text nodes')) {
    if (-not $window.Contains($windowAnchor)) { throw 'LAN UI text-node diagnostic insertion point not found.' }
    $window = $window.Replace($windowAnchor, $windowReplacement)
}
Set-Content -Path $windowPath -Value $window -NoNewline

Write-Host 'Visible Mahjong addon text-node diagnostics applied.'
