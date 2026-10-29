# Wuwa Tappo automatic background chest collection v1.1
[CmdletBinding()]
param([switch]$Auto)
$ErrorActionPreference = 'Stop'
function Write-Log([string]$Message) {
    Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message)
}
function Get-GameWindow {
    $procs = @(Get-Process -Name WuwaTappo -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { throw '請先開啟 Wuwa Tappo，並讓桌寵顯示在桌面。' }
    $found = @()
    foreach ($proc in $procs) {
        $condition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$proc.Id)
        $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
            [System.Windows.Automation.TreeScope]::Children, $condition)
        foreach ($window in $windows) {
            if ($window.Current.Name -eq 'Wuwa Tappo') { $found += $window }
        }
    }
    if ($found.Count -ne 1) { throw '找不到唯一的 Wuwa Tappo 桌寵視窗；請關閉其他同名程式後重試。' }
    return $found[0]
}
function Get-Buttons($Window) {
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button)
    $items = $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
    foreach ($item in $items) { Write-Output $item }
}
function Get-ElementKey($Element) {
    return ($Element.GetRuntimeId() -join ':')
}
function Get-ButtonSnapshot($Element) {
    $c = $Element.Current
    $r = $c.BoundingRectangle
    $invokeObject = $null
    $supported = $Element.TryGetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern, [ref]$invokeObject)
    return [pscustomobject]@{
        Key = Get-ElementKey $Element
        Width = $r.Width
        Height = $r.Height
        Name = $c.Name
        AutomationId = $c.AutomationId
        Visible = (-not $c.IsOffscreen -and $r.Width -gt 0 -and $r.Height -gt 0)
        Enabled = $c.IsEnabled
        Invoke = $supported
        Element = $Element
    }
}
function Test-SameSize($A, $B) {
    return ([Math]::Abs($A.Width - $B.Width) -le 1 -and
        [Math]::Abs($A.Height - $B.Height) -le 1)
}
function Test-DesktopButton($Button) {
    return ($Button.Visible -and
        -not [double]::IsNaN($Button.Width) -and -not [double]::IsInfinity($Button.Width) -and
        -not [double]::IsNaN($Button.Height) -and -not [double]::IsInfinity($Button.Height) -and
        $Button.Width -gt 0 -and $Button.Height -gt 0 -and
        [string]::IsNullOrEmpty($Button.Name) -and
        [string]::IsNullOrEmpty($Button.AutomationId))
}
function Find-ChestCalibration($Buttons, [string]$WindowKey) {
    # Learn only from exactly one unique matching pair and a distinct third button.
    if ($Buttons.Count -ne 3) { return $null }
    if (@($Buttons | Where-Object { -not (Test-DesktopButton $_) }).Count -gt 0) { return $null }
    if (@($Buttons | Select-Object -ExpandProperty Key -Unique).Count -ne 3) { return $null }
    $pairs = @()
    for ($i = 0; $i -lt 3; $i++) {
        for ($j = $i + 1; $j -lt 3; $j++) {
            if (Test-SameSize $Buttons[$i] $Buttons[$j]) {
                $pairs += [pscustomobject]@{ First = $i; Second = $j }
            }
        }
    }
    if ($pairs.Count -ne 1) { return $null }
    $a = $Buttons[$pairs[0].First]
    $b = $Buttons[$pairs[0].Second]
    $otherIndex = 3 - $pairs[0].First - $pairs[0].Second
    $other = $Buttons[$otherIndex]
    # Keep both learned measurements: a lone settings button can detect scaling changes.
    return [pscustomobject]@{
        WindowKey = $WindowKey
        Width = ($a.Width + $b.Width) / 2
        Height = ($a.Height + $b.Height) / 2
        SettingsKey = $other.Key
        SettingsWidth = $other.Width
        SettingsHeight = $other.Height
    }
}
function Get-ChestCandidates($Calibration, $Buttons) {
    if ($null -eq $Calibration) { return }
    foreach ($button in $Buttons) {
        if ($button.Key -ne $Calibration.SettingsKey -and
            (Test-DesktopButton $button) -and (Test-SameSize $button $Calibration)) {
            Write-Output $button
        }
    }
}
function Test-ChestCalibration($Calibration, $Buttons, [string]$WindowKey) {
    if ($null -eq $Calibration -or $Calibration.WindowKey -ne $WindowKey) { return $false }
    $settings = @($Buttons | Where-Object { $_.Key -eq $Calibration.SettingsKey })
    if ($settings.Count -ne 1 -or -not (Test-DesktopButton $settings[0])) { return $false }
    $expected = [pscustomobject]@{ Width = $Calibration.SettingsWidth; Height = $Calibration.SettingsHeight }
    if (-not (Test-SameSize $settings[0] $expected)) { return $false }
    # Extra emote/panel controls do not invalidate a learned chest size.
    # The stable settings control detects window replacement and scale changes.
    return $true
}

function Update-MenuPause($State, $Pending, [bool]$ShouldPause, [datetime]$Now) {
    if ($ShouldPause) {
        if ($null -eq $State.StartedAt) {
            $State.StartedAt = $Now
            Write-Log '目前無法唯一辨識寶箱，暫停點擊；條件恢復後會自動繼續。'
        }
        return $true
    }
    if ($null -ne $State.StartedAt) {
        if ($null -ne $Pending) {
            # Menu time must not count toward the pending-click timeout.
            $Pending.SentAt = $Pending.SentAt + ($Now - $State.StartedAt)
        }
        $State.StartedAt = $null
        Write-Log '辨識條件已恢復，繼續檢查。'
    }
    return $false
}


$mutex = $null
$ownsMutex = $false
$guard = $null
$probe = $null
try {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -Path (Join-Path $PSScriptRoot 'NativeBackground.cs')
    $mutex = New-Object System.Threading.Mutex($false, 'Local\WuwaTappoUIAAutoChestV1')
    $ownsMutex = $mutex.WaitOne(0)
    if (-not $ownsMutex) { throw '已有自動領取腳本執行中，請先關閉。' }
    Write-Log 'Wuwa Tappo v1.1 背景領取；每 5 秒檢查一次。'
    Write-Log '先關閉表情／設定面板，等兩個寶箱都能領取。辨識完成後會自動背景領取。'
    $calibration = $null
    $lastState = ''
    while ($null -eq $calibration) {
        $window = Get-GameWindow
        $windowKey = '{0}:{1}' -f $window.Current.ProcessId, $window.Current.NativeWindowHandle
        $buttons = @(Get-Buttons $window | ForEach-Object { Get-ButtonSnapshot $_ })
        $calibration = Find-ChestCalibration $buttons $windowKey
        $state = '目前按鈕 {0} 顆；等待唯一的同尺寸寶箱配對。' -f $buttons.Count
        if ($state -ne $lastState) { Write-Log $state; $lastState = $state }
        if ($null -eq $calibration) { Start-Sleep -Seconds 5 }
    }
    Write-Log ('已辨識寶箱：{0} x {1}。開始自動背景領取。' -f $calibration.Width, $calibration.Height)
    $target = [IntPtr]$window.Current.NativeWindowHandle
    while ($true) {
        $window = Get-GameWindow
        $key = '{0}:{1}' -f $window.Current.ProcessId, $window.Current.NativeWindowHandle
        $buttons = @(Get-Buttons $window | ForEach-Object { Get-ButtonSnapshot $_ })
        if (-not (Test-ChestCalibration $calibration $buttons $key)) {
            $calibration = Find-ChestCalibration $buttons $key
            if ($null -eq $calibration) {
                if ($lastState -ne 'relearn') { Write-Log '等待重新辨識：請關閉表情／設定面板，等兩個寶箱都能領取。'; $lastState = 'relearn' }
                Start-Sleep -Seconds 5
                continue
            }
            $target = [IntPtr]$window.Current.NativeWindowHandle
            Write-Log '已重新辨識寶箱尺寸。'
        }
        $candidates = @(Get-ChestCandidates $calibration $buttons)
        if ($candidates.Count -gt 2) {
            if ($lastState -ne 'ambiguous') { Write-Log '符合尺寸的按鈕太多，暫停；條件恢復後自動繼續。'; $lastState = 'ambiguous' }
            Start-Sleep -Seconds 5
            continue
        }
        if ([WuwaBackgroundNative]::IsTargetForeground($target)) {
            if ($lastState -ne 'foreground') { Write-Log '正在操作桌寵，暫停領取；切回其他視窗後自動繼續。'; $lastState = 'foreground' }
            Start-Sleep -Seconds 5
            continue
        }
        $ready = @($candidates | Where-Object { $_.Enabled })
        if ($ready.Count -eq 0) {
            if (-not $Auto) { throw '目前沒有可用寶箱；沒有送出訊息。' }
            Start-Sleep -Seconds 5
            continue
        }
        $lastState = 'ready'
        $button = $ready[0]
        $fresh = Get-ButtonSnapshot $button.Element
        if ($fresh.Key -ne $button.Key -or -not $fresh.Enabled -or
            -not (Test-DesktopButton $fresh) -or -not (Test-SameSize $fresh $calibration)) {
            throw '寶箱狀態剛好改變，沒有送出訊息，請再試一次。'
        }
        $r = $button.Element.Current.BoundingRectangle
        $x = [int][Math]::Floor($r.Left + $r.Width / 2)
        $y = [int][Math]::Floor($r.Top + $r.Height / 2)
        $guard = New-Object WuwaBackgroundNative+WindowGuard($target)
        $probe = New-Object WuwaBackgroundNative+FocusProbe($target)
        Write-Log '背景領取寶箱。'
        $description = [WuwaBackgroundNative]::ClickWebView($target, $x, $y)
        Write-Log ('送出成功：' + $description + '（送出不等於已領取）')
        $gone = $false
        $until = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $until) {
            Start-Sleep -Milliseconds 250
            $guard.Verify()
            if ($probe.TargetSeen) { break }
            $current = @(Get-Buttons $window)
            $remaining = @($current | Where-Object { (Get-ElementKey $_) -eq $button.Key })
            if ($remaining.Count -eq 0) { $gone = $true; break }
        }
        # Observe a little longer for delayed focus changes from reward animation.
        Start-Sleep -Seconds 2
        $probe.Dispose()
        $stolen = $probe.TargetSeen
        $changes = $probe.Changes
        $probe = $null
        $guard.Dispose()
        $guard = $null
        Write-Log ('領取觀察：寶箱按鈕消失={0}；監測到桌寵進入前景={1}；監測到前景變更次數={2}。' -f $gone, $stolen, $changes)
        if ($stolen) { throw '觀察到桌寵進入前景，已停止。' }
        if (-not $gone) { throw '10 秒內沒看到寶箱按鈕消失。此法可能不被 WebView 接受；不重送、不改用舊版點擊。' }
        Write-Log '寶箱按鈕已消失，繼續等待下一次領取。'
        if (-not $Auto) { break }
        Start-Sleep -Seconds 5
    }
} catch {
    Write-Log ('已停止：' + $_.Exception.Message)
    Write-Log '若已送出訊息，請查看原程式是否已領取；不要立即重複操作同一顆。'
    exit 1
} finally {
    if ($null -ne $probe) { $probe.Dispose() }
    if ($null -ne $guard) {
        try { $guard.Dispose(); Write-Log '已還原本次更動的桌寵視窗樣式。' }
        catch { Write-Log '視窗樣式還原失敗；請完整退出 Wuwa Tappo 再開啟。' }
    }
    if ($ownsMutex -and $null -ne $mutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
