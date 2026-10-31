# Wuwa Tappo automatic background chest collection v1.1.2
[CmdletBinding()]
param([switch]$Auto, [ValidateSet('UpperFirst','LowerFirst')][string]$Order = 'UpperFirst')
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
    Start-Transcript -Path (Join-Path $PSScriptRoot ('wuwa-live-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))) | Out-Null
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -Path (Join-Path $PSScriptRoot 'NativeBackground.cs')
    $mutex = New-Object System.Threading.Mutex($false, 'Local\WuwaTappoUIAAutoChestV1')
    $ownsMutex = $mutex.WaitOne(0)
    if (-not $ownsMutex) { throw '已有自動領取腳本執行中，請先關閉。' }
    Write-Log ('Wuwa Tappo v1.1.2 背景領取；順序={0}；每 5 秒檢查。' -f $Order)
    Write-Log '先關閉表情／設定面板，等兩個寶箱都能領取。辨識完成後會自動背景領取。'
    $attempt = 0
    $batchClicks = 0
    $nextChestKey = $null
    $previousDispatchClock = $null
    $positionLabels = @{}
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
        if ($null -ne $guard) {
            $guard.Verify()
            if ($probe.TargetSeen) { throw '兩顆之間觀察到桌寵進入前景，停止本輪。' }
            if (-not (Test-ChestCalibration $calibration $buttons $key)) { throw '兩顆之間視窗或尺寸改變，停止本輪並還原。' }
        }
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
        if ($null -ne $guard -and ($candidates.Count -gt 2 -or [WuwaBackgroundNative]::IsTargetForeground($target))) { throw '兩顆之間辨識條件改變或桌寵進入前景，停止本輪並還原。' }
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
        if ($lastState -in @('foreground', 'ambiguous', 'relearn')) {
            Write-Log '已恢復自動領取，繼續每 5 秒檢查寶箱。'
        }
        $lastState = 'monitoring'
        $ready = @($candidates | Where-Object { $_.Enabled })
        if ($null -ne $guard -and @($ready | Where-Object { $_.Key -eq $nextChestKey }).Count -ne 1) { throw '預定的下一顆寶箱已不可用，停止本輪並還原。' }
        if ($ready.Count -eq 0) {
            if (-not $Auto) { throw '目前沒有可用寶箱；沒有送出訊息。' }
            Start-Sleep -Seconds 5
            continue
        }
        $lastState = 'ready'
        # Label both positions before either disappears; retain labels for the lone chest.
        if ($candidates.Count -eq 2) {
            $ordered = @($candidates | Sort-Object { $_.Element.Current.BoundingRectangle.Top })
            $positionLabels[$ordered[0].Key] = '上方'
            $positionLabels[$ordered[1].Key] = '下方'
        }
        $sortedReady = @($ready | Sort-Object { $_.Element.Current.BoundingRectangle.Top })
        $button = $sortedReady[0]
        if ($Order -eq 'LowerFirst') { $button = $sortedReady[-1] }
        if ($null -ne $guard) { $button = @($ready | Where-Object { $_.Key -eq $nextChestKey })[0] }

        $fresh = Get-ButtonSnapshot $button.Element
        if ($fresh.Key -ne $button.Key -or -not $fresh.Enabled -or
            -not (Test-DesktopButton $fresh) -or -not (Test-SameSize $fresh $calibration)) {
            throw '寶箱狀態剛好改變，沒有送出訊息，請再試一次。'
        }
        $r = $button.Element.Current.BoundingRectangle
        $x = [int][Math]::Floor($r.Left + $r.Width / 2)
        $y = [int][Math]::Floor($r.Top + $r.Height / 2)
        # Begin observation before applying the style guard, and keep it through restoration.
        if ($null -eq $guard) {
            $probe = New-Object WuwaBackgroundNative+FocusProbe($target)
            $probe.Mark('apply-guard')
            $guard = New-Object WuwaBackgroundNative+WindowGuard($target)
            $batchClicks = 0
        } else {
            $guard.Verify()
            Write-Log ('距上一顆送出已過 {0:N1} 秒；防啟用樣式持續有效。' -f $previousDispatchClock.Elapsed.TotalSeconds)
        }
        $probe.Mark('dispatch')
        $batchClicks++
        $attempt++
        $position = $positionLabels[$button.Key]
        if (-not $position) { $position = '位置未知' }
        Write-Log ('第 {0} 次送出；寶箱={1}；螢幕座標={2},{3}。' -f $attempt, $position, $x, $y)
        $previousDispatchClock = [System.Diagnostics.Stopwatch]::StartNew()
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
        # Allow transient WebView changes to settle while retaining the same guard.
        if ($gone -and -not $probe.TargetSeen -and $Auto -and $batchClicks -eq 1) {
            Write-Log '第一顆已消失；保留防啟用樣式，最多 60 秒持續重查另一顆。'
            $probe.Mark('retry-second-guarded')
            $retryClock = [System.Diagnostics.Stopwatch]::StartNew()
            $retryState = ''
            $nextChestKey = $null
            while ($retryClock.Elapsed.TotalSeconds -lt 60) {
                $guard.Verify()
                if ($probe.TargetSeen -or [WuwaBackgroundNative]::IsTargetForeground($target)) {
                    throw '等待另一顆時桌寵進入前景，停止本輪並還原。'
                }
                $scanWindow = Get-GameWindow
                $scanKey = '{0}:{1}' -f $scanWindow.Current.ProcessId, $scanWindow.Current.NativeWindowHandle
                if ($scanKey -ne $key) { throw '等待另一顆時桌寵視窗已更換，停止本輪並還原。' }
                $currentSnapshots = @(Get-Buttons $scanWindow | ForEach-Object { Get-ButtonSnapshot $_ })
                $valid = Test-ChestCalibration $calibration $currentSnapshots $scanKey
                $allMatches = @(Get-ChestCandidates $calibration $currentSnapshots)
                $remainingReady = @($allMatches | Where-Object { $_.Enabled -and $_.Key -ne $button.Key })
                $oldStillPresent = @($currentSnapshots | Where-Object { $_.Key -eq $button.Key }).Count -gt 0
                $reason = '等待另一顆出現或啟用'
                if (-not $valid) { $reason = '設定按鈕身分／尺寸或可見狀態未通過辨識' }
                elseif ($oldStillPresent) { $reason = '剛領取的按鈕再次出現，等待介面穩定' }
                elseif ($allMatches.Count -gt 2 -or $remainingReady.Count -gt 1) { $reason = '有多個候選，無法唯一確認另一顆' }
                elseif ($remainingReady.Count -eq 1) { $reason = '已找到唯一可用的另一顆' }
                $details = @($currentSnapshots | ForEach-Object {
                    'id={0},size={1}x{2},visible={3},enabled={4},settings={5},previous={6}' -f $_.Key,$_.Width,$_.Height,$_.Visible,$_.Enabled,($_.Key -eq $calibration.SettingsKey),($_.Key -eq $button.Key)
                }) -join ' | '
                $state = '校準={0};總按鈕={1};尺寸候選={2};另一顆可用={3};原因={4}; {5}' -f $valid,$currentSnapshots.Count,$allMatches.Count,$remainingReady.Count,$reason,$details
                if ($state -ne $retryState) {
                    Write-Log ('重查（{0:N1} 秒）：{1}' -f $retryClock.Elapsed.TotalSeconds,$state)
                    $retryState = $state
                }
                # Match the previous B short interval, but validate at the end of
                # the wait rather than trusting a single immediate snapshot.
                if ($valid -and -not $oldStillPresent -and $allMatches.Count -le 2 -and $remainingReady.Count -eq 1 -and $previousDispatchClock.Elapsed.TotalSeconds -ge 7) {
                    $nextChestKey = $remainingReady[0].Key
                    break
                }
                Start-Sleep -Milliseconds 250
            }
            if ($null -ne $nextChestKey) {
                Write-Log ('另一顆已確認，接續領取；距前次送出 {0:N1} 秒。' -f $previousDispatchClock.Elapsed.TotalSeconds)
                continue
            }
            Write-Log '重查滿 60 秒仍無法唯一確認另一顆；本輪結束。'
        }
        $nextChestKey = $null
        $probe.Mark('guarded-wait')
        Write-Log '本輪操作結束，保留防啟用樣式 15 秒後再還原。'
        $holdUntil = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $holdUntil) {
            $guard.Verify()
            Start-Sleep -Milliseconds 250
        }
        $beforeRestoreSeen = $probe.TargetSeen
        $beforeRestoreChanges = $probe.Changes
        Write-Log ('還原前：桌寵進入前景={0}；前景變更={1}。' -f $beforeRestoreSeen, $beforeRestoreChanges)
        $probe.Mark('restore-style')
        $guard.Dispose()
        $guard = $null
        $probe.Mark('after-restore')
        Write-Log '視窗樣式已還原；繼續監測 5 秒。'
        Start-Sleep -Seconds 5
        $probe.Dispose()
        $stolen = $probe.TargetSeen
        $changes = $probe.Changes
        foreach ($entry in $probe.GetEvents()) { Write-Log ('焦點軌跡：' + $entry) }
        $probe = $null
        Write-Log ('第 {0} 次結果；寶箱={1}；按鈕消失={2}；桌寵進入前景={3}；前景變更={4}；還原後新增變更={5}。' -f $attempt, $position, $gone, $stolen, $changes, ($changes - $beforeRestoreChanges))
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
    if ($null -ne $guard) {
        try { $guard.Dispose(); Write-Log '已還原本次更動的桌寵視窗樣式。' }
        catch { Write-Log '視窗樣式還原失敗；請完整退出 Wuwa Tappo 再開啟。' }
    }
    if ($null -ne $probe) {
        $probe.Dispose()
        foreach ($entry in $probe.GetEvents()) { Write-Log ('焦點軌跡：' + $entry) }
    }
    try { Stop-Transcript | Out-Null } catch { }
    if ($ownsMutex -and $null -ne $mutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
