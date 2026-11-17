$ErrorActionPreference = 'Stop'

$path = 'upstream/Mahjong.Plugin.Dalamud/UI/MainWindow.cs'
$source = Get-Content $path -Raw
$source = $source.Replace('    private readonly Plugin plugin;', '    private const string BuildUiVersion = "V8.0";' + [Environment]::NewLine + '    private readonly Plugin plugin;')
$source = $source.Replace(': base("Doman Mahjong Solver###domanmahjong-main")', ': base($"Doman Mahjong Solver {BuildUiVersion}###domanmahjong-main")')
$old = 'WindowName = Loc.T("Doman Mahjong Solver", "多玛麻将助手") + "###domanmahjong-main";'
$new = 'WindowName = Loc.T("Doman Mahjong Solver", "多玛麻将助手") + " " + BuildUiVersion + "###domanmahjong-main";'
if (-not $source.Contains($new)) {
    if (-not $source.Contains($old)) { throw 'MainWindow title assignment not found.' }
    $source = $source.Replace($old, $new)
}
if (-not $source.Contains('private const string BuildUiVersion = "V8.0";')) { throw 'Could not set UI build version.' }
Set-Content -Path $path -Value $source -NoNewline
Write-Host 'Plugin window title now displays V8.0.'
