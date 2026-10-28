# Run with: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\calibration.tests.ps1
# These synthetic snapshots exercise detection only; no desktop or game is accessed.
$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path $PSScriptRoot -Parent) 'wuwa_live.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
$names = @('Test-SameSize', 'Test-DesktopButton', 'Find-ChestCalibration', 'Test-ChestCalibration')
foreach ($name in $names) {
    $node = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        Where-Object { $_.Name -eq $name }
    if (@($node).Count -ne 1) { throw "Function not found: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
$script:checks = 0
function Assert-True($Value, [string]$Label) {
    if (-not $Value) { throw "FAIL: $Label" }
    $script:checks++
}
function Button([string]$Key, [double]$Width, [double]$Height) {
    return [pscustomobject]@{
        Key = $Key; Width = $Width; Height = $Height
        Visible = $true; Name = ''; AutomationId = ''; Enabled = $true; Invoke = $true
    }
}
$a = Button 'left' 62 44
$b = Button 'right' 62 44
$s = Button 'settings' 38 32
foreach ($order in @(@($a,$b,$s),@($a,$s,$b),@($b,$a,$s),@($b,$s,$a),@($s,$a,$b),@($s,$b,$a))) {
    $c = Find-ChestCalibration $order 'window1'
    Assert-True ($null -ne $c -and $c.Width -eq 62 -and $c.Height -eq 44 -and $c.SettingsKey -eq 'settings') 'order-independent unique pair'
}
$c = Find-ChestCalibration @($a,$b,$s) 'window1'
Assert-True (Test-ChestCalibration $c @($a,$b,$s) 'window1') 'both chests after learning'
Assert-True (Test-ChestCalibration $c @($b,$s) 'window1') 'one chest after learning'
Assert-True (Test-ChestCalibration $c @($s) 'window1') 'countdown with settings only'
Assert-True ($null -eq (Find-ChestCalibration @($a,$s) 'window1')) 'one chest cannot initialize'
Assert-True ($null -eq (Find-ChestCalibration @($a,$b) 'window1')) 'two buttons cannot initialize'
Assert-True ($null -eq (Find-ChestCalibration @($a,$b,(Button 'other' 62 44)) 'window1')) 'three identical sizes are ambiguous'
Assert-True ($null -eq (Find-ChestCalibration @($a,(Button 'b' 80 50),$s) 'window1')) 'all different sizes cannot initialize'
Assert-True ($null -eq (Find-ChestCalibration @((Button 'a' 60 40),(Button 'b' 61 40),(Button 'c' 62 40)) 'window1')) 'overlapping tolerance matches are ambiguous'
Assert-True ($null -eq (Find-ChestCalibration @($a,$b,$s,(Button 'extra' 20 20)) 'window1')) 'extra panel buttons cannot initialize'
Assert-True (-not (Test-ChestCalibration $c @($a,$b,$s) 'window2')) 'new window requires learning'
Assert-True (-not (Test-ChestCalibration $c @($a,$b,(Button 'new-settings' 38 32)) 'window1')) 'changed settings identity requires learning'
Assert-True (-not (Test-ChestCalibration $c @((Button 'settings' 48 40)) 'window1')) 'scale change detected during countdown'
Assert-True (-not (Test-ChestCalibration $c @((Button 'left' 90 60),$s) 'window1')) 'lone resized chest invalidates old dimensions'
$scaled = @((Button 'left' 93 66),(Button 'right' 93 66),(Button 'settings' 57 48))
$sc = Find-ChestCalibration $scaled 'window1'
Assert-True ($null -ne $sc -and $sc.Width -eq 93 -and $sc.Height -eq 66) 'different scale learns automatically'
Assert-True (Test-ChestCalibration $sc @($scaled[0],$scaled[2]) 'window1') 'one chest at new scale remains recognized'
$hidden = Button 'right' 62 44; $hidden.Visible = $false
Assert-True ($null -eq (Find-ChestCalibration @($a,$hidden,$s) 'window1')) 'hidden button cannot initialize'
$unsupported = Button 'right' 62 44; $unsupported.Invoke = $false
Assert-True ($null -eq (Find-ChestCalibration @($a,$unsupported,$s) 'window1')) 'unsupported chest cannot initialize'
$named = Button 'right' 62 44; $named.Name = 'Other action'
Assert-True ($null -eq (Find-ChestCalibration @($a,$named,$s) 'window1')) 'named panel action cannot initialize'
Assert-True ($null -eq (Find-ChestCalibration @($a,$a,$s) 'window1')) 'duplicate elements cannot initialize'
Assert-True ($null -eq (Find-ChestCalibration @((Button 'left' ([double]::NaN) 44),$b,$s) 'window1')) 'invalid rectangle cannot initialize'
Assert-True (-not (Test-ChestCalibration $c @() 'window1')) 'hidden window invalidates calibration'
Write-Output ("PASS: {0} detection checks; script syntax valid." -f $script:checks)
