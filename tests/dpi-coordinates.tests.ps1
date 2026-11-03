# Geometry cases run without a Windows desktop; native input is never called.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Add-Type -Path (Join-Path $root 'NativeBackground.cs')
$script:checks = 0
function Assert($Value, $Label) { if (-not $Value) { throw "FAIL: $Label" }; $script:checks++ }
function Rect($Left,$Top,$Right,$Bottom) {
    $r = New-Object WuwaBackgroundNative+RECT
    $r.Left=$Left; $r.Top=$Top; $r.Right=$Right; $r.Bottom=$Bottom
    return $r
}
# Physical desktop coordinates must not be divided by 125% or 150%.
$r = Rect 5000 1300 5300 1500
Assert ([WuwaBackgroundNative]::ContainsPhysicalPoint($r,5193,1432)) 'reported secondary-monitor point is contained'
Assert (-not [WuwaBackgroundNative]::ContainsPhysicalPoint($r,4154,1146)) '125 percent logical point cannot be mixed with physical rect'
Assert (-not [WuwaBackgroundNative]::ContainsPhysicalPoint($r,3462,955)) '150 percent logical point cannot be mixed with physical rect'
$r = Rect -1920 -1080 0 0
Assert ([WuwaBackgroundNative]::ContainsPhysicalPoint($r,-1800,-900)) 'left and upper monitors accept negative screen coordinates'
Assert ([WuwaBackgroundNative]::ContainsPhysicalPoint($r,-1920,-1080)) 'top-left included'
Assert (-not [WuwaBackgroundNative]::ContainsPhysicalPoint($r,0,-10)) 'right edge excluded'
Assert (-not [WuwaBackgroundNative]::ContainsPhysicalPoint($r,-10,0)) 'bottom edge excluded'
Assert (-not [WuwaBackgroundNative]::ContainsPhysicalPoint((Rect 0 0 0 10),0,5)) 'empty rect excluded'
# Fail-closed scope: failure to set DPI awareness must not silently use mixed coordinates.
$native = Get-Content -Raw (Join-Path $root 'NativeBackground.cs')
Assert ($native.Contains('if (previous == IntPtr.Zero) throw')) 'DPI setup failure prevents dispatch'
$source = Get-Content -Raw (Join-Path $root 'wuwa_live.ps1')
Assert ($source.IndexOf('$dpiScope = New-Object WuwaBackgroundNative+PhysicalCoordinates') -lt $source.IndexOf('Add-Type -AssemblyName UIAutomationClient')) 'DPI scope starts before UI Automation initialization'
Assert ($source.Contains('$dpiScope.Dispose()')) 'DPI scope restored during cleanup'
Write-Output "PASS: $checks DPI coordinate checks; no native desktop input used."
