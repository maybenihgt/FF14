$ErrorActionPreference = 'Stop'

$readerPath = 'upstream/Mahjong.Plugin.Dalamud/GameState/AddonEmjReader.cs'
$reader = Get-Content $readerPath -Raw
$methodMarker = '    public unsafe StateSnapshot? TryBuildSnapshot()'
$method = @'
    /// <summary>
    /// Maps a logical snapshot-hand tile back through the live addon hand array,
    /// then returns its compact snapshot index. This preserves the true addon slot
    /// (including sparse post-call slots and the distinct red-five identity).
    /// </summary>
    public unsafe int FindSnapshotHandIndexOfTile(Mahjong.Core.Tile target, bool? targetIsRed = null)
    {
        if (ActiveLayout is null || !addon.TryGet(out var unit, out _) || !unit->IsVisible)
            return -1;

        int len = ActiveLayout.Limits.HandSize;
        Span<int> raw = stackalloc int[len];
        byte* basePtr = (byte*)unit;
        for (int i = 0; i < len; i++)
            raw[i] = *(int*)(basePtr + ActiveLayout.Offsets.HandArrayStart + i * 4);

        int textureBase = Variants.HandArrayDecoder.ResolveTextureBase(
            raw, ActiveLayout.TileTextureBase, out _);
        int addonSlot = Variants.HandArrayDecoder.FindAddonSlot(
            raw, textureBase, target.Id, targetIsRed);
        if (addonSlot < 0)
            return -1;

        int compactIndex = 0;
        for (int i = 0; i < addonSlot; i++)
            if (Variants.HandArrayDecoder.DecodeTileId(raw[i], textureBase, out _) >= 0)
                compactIndex++;
        return compactIndex;
    }

'@
if (-not $reader.Contains('FindSnapshotHandIndexOfTile(')) {
    if (-not $reader.Contains($methodMarker)) { throw 'AddonEmjReader hand-index insertion point not found.' }
    $reader = $reader.Replace($methodMarker, $method + $methodMarker)
}
Set-Content -Path $readerPath -Value $reader -NoNewline

$overlayPath = 'upstream/Mahjong.Plugin.Dalamud/UI/HandOverlay.cs'
$overlay = Get-Content $overlayPath -Raw
$old = @'
        int slot = InputDispatcher.FindSlotOfTile(
            choice.DiscardTile.Value,
            snap.Hand,
            snap.HandIsRed,
            choiceIsRed);
'@
$new = @'
        int slot = plugin.AddonReader.FindSnapshotHandIndexOfTile(
            choice.DiscardTile.Value,
            choiceIsRed);
'@
if (-not $overlay.Contains('plugin.AddonReader.FindSnapshotHandIndexOfTile(')) {
    if (-not $overlay.Contains($old)) { throw 'HandOverlay logical-slot mapping not found.' }
    $overlay = $overlay.Replace($old, $new)
}
Set-Content -Path $overlayPath -Value $overlay -NoNewline
Write-Host 'Hand highlight now resolves through live addon slots and compact hand positions.'
