# Synthetic foreground transitions; no native desktop APIs or chest input are used.
$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
public static class WuwaBackgroundNative {
    public static int ForegroundChecks;
    public static int ForegroundRemaining;
    public static bool Alive = true;
    public static bool IsWindow(IntPtr target) { return Alive; }
    public static bool IsTargetForeground(IntPtr target) {
        ForegroundChecks++;
        return ForegroundRemaining-- > 0;
    }
    public class WindowGuard {
        public static int Created;
        public static int Disposed;
        public WindowGuard(IntPtr target) { Created++; }
        public void Dispose() { Disposed++; }
    }
}
public class ProbeStub {
    public bool TargetSeen;
    public int Resets;
    public void ResetTargetSeen() { TargetSeen = false; Resets++; }
}
'@
$path = Join-Path (Split-Path $PSScriptRoot -Parent) 'wuwa_live.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$node = $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Wait-ForBackground'},$true)
. ([scriptblock]::Create($node[0].Extent.Text))
$script:messages = @()
function Write-Log([string]$Message) { $script:messages += $Message }
# Avoid elapsed wall time in simulated foreground waits.
function Start-Sleep { param($Milliseconds) }
$checks = 0
function Assert($Value,$Label) { if (-not $Value) { throw "FAIL: $Label" }; $script:checks++ }
$guard = $null
$duration = Wait-ForBackground ([IntPtr]1) ([ref]$guard) $null
Assert ($duration -eq [timespan]::Zero -and $messages.Count -eq 0) 'background scan continues without pause'
$guard = New-Object WuwaBackgroundNative+WindowGuard([IntPtr]1)
$probe = New-Object ProbeStub
$probe.TargetSeen = $true
[WuwaBackgroundNative]::ForegroundRemaining = 3
$duration = Wait-ForBackground ([IntPtr]1) ([ref]$guard) $probe
Assert ($messages.Count -eq 2) 'one pause and one resume message'
Assert ([WuwaBackgroundNative+WindowGuard]::Disposed -eq 1) 'guard released for manual pet interaction'
Assert ($null -ne $guard -and [WuwaBackgroundNative+WindowGuard]::Created -eq 2) 'guard reacquired on return to background'
Assert ($probe.Resets -eq 1 -and -not $probe.TargetSeen) 'historical focus does not permanently block scanning'
Assert ($duration -ge [timespan]::Zero) 'pause duration available for confirmation timeout adjustment'
$messages = @(); $guard = $null
[WuwaBackgroundNative]::ForegroundRemaining = 2
$duration = Wait-ForBackground ([IntPtr]1) ([ref]$guard) $null
Assert ($messages.Count -eq 2 -and $null -eq $guard) 'focus after restoration pauses without reapplying guard'
$probe.TargetSeen = $true
[WuwaBackgroundNative]::ForegroundRemaining = 0
$messages = @()
$duration = Wait-ForBackground ([IntPtr]1) ([ref]$guard) $probe
Assert ($probe.Resets -eq 2 -and $messages.Count -eq 2) 'brief historical focus resumes when already background'
[WuwaBackgroundNative]::Alive = $false
[WuwaBackgroundNative]::ForegroundRemaining = 2
$failed = $false
try { $null = Wait-ForBackground ([IntPtr]1) ([ref]$guard) $null } catch { $failed = $true }
Assert $failed 'closed target does not resume against another window'
Write-Output ("PASS: {0} focus pause/resume checks." -f $checks)
