# Wuwa Tappo simultaneous UI Automation helper, Windows PowerShell 5.1.
# Default: inspect only. -Auto: invoke recognized chest buttons.
# Does not read credentials, call game APIs, move the mouse, or change files.
[CmdletBinding()]
param(
    [switch]$Auto
)
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
    if (-not $a.Invoke -or -not $b.Invoke) { return $null }
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
function Test-ChestCalibration($Calibration, $Buttons, [string]$WindowKey) {
    if ($null -eq $Calibration -or $Calibration.WindowKey -ne $WindowKey) { return $false }
    if ($Buttons.Count -lt 1 -or $Buttons.Count -gt 3) { return $false }
    if (@($Buttons | Where-Object { -not (Test-DesktopButton $_) }).Count -gt 0) { return $false }
    $settings = @($Buttons | Where-Object { $_.Key -eq $Calibration.SettingsKey })
    if ($settings.Count -ne 1) { return $false }
    $expected = [pscustomobject]@{ Width = $Calibration.SettingsWidth; Height = $Calibration.SettingsHeight }
    if (-not (Test-SameSize $settings[0] $expected)) { return $false }
    foreach ($button in $Buttons) {
        if ($button.Key -eq $Calibration.SettingsKey) { continue }
        if (-not (Test-SameSize $button $Calibration)) { return $false }
    }
    return $true
}

$mutex = $null
$hasMutex = $false
try {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    if ($Auto) {
        $mutex = New-Object System.Threading.Mutex($false, 'Local\WuwaTappoUIAAutoChestV1')
        $hasMutex = $mutex.WaitOne(0)
        if (-not $hasMutex) { throw '已有一個同時執行版正在運作，請先關閉另一個。' }
    }
    Write-Log ('模式：' + $(if ($Auto) { '自動領取；由原程式正常處理開箱與扣點。' } else { '只檢查，不點擊。' }))
    Write-Log '首次辨識會等待三顆按鈕：兩顆同尺寸寶箱，加上一顆不同尺寸的設定按鈕。'
    Write-Log '請關閉背包／設定等面板，保持桌寵可見；等兩個寶箱都可領取，先不要手動領取。'
    Write-Log '尺寸只記在這次執行中；移動位置不影響，偵測到縮放或介面變化會重新辨識。'
    if ($Auto) { Write-Log '每 5 秒檢查；Ctrl+C 或關閉這個 CMD 可停止。請勿同時執行舊版 API 自動領取。' }
    $pending = $null
    $calibration = $null
    $lastState = ''
    while ($true) {
        $window = Get-GameWindow
        $windowKey = '{0}:{1}' -f $window.Current.ProcessId, $window.Current.NativeWindowHandle
        $buttons = @(Get-Buttons $window | ForEach-Object { Get-ButtonSnapshot $_ })
        if ($buttons.Count -gt 3) {
            throw '偵測到額外按鈕，已停止；請關閉背包、設定等面板，再重新啟動。'
        }
        if ($null -ne $calibration -and -not (Test-ChestCalibration $calibration $buttons $windowKey)) {
            Write-Log '尺寸、設定按鈕或視窗狀態已改變，清除舊尺寸，等待兩個寶箱重新辨識。'
            $calibration = $null
        }
        if ($null -eq $calibration) {
            $calibration = Find-ChestCalibration $buttons $windowKey
            if ($null -ne $calibration) {
                Write-Log ('已自動辨識寶箱尺寸：{0} x {1}。' -f $calibration.Width, $calibration.Height)
            }
        }
        $candidates = @()
        if ($null -ne $calibration) {
            $candidates = @($buttons | Where-Object {
                $_.Key -ne $calibration.SettingsKey -and
                (Test-DesktopButton $_) -and (Test-SameSize $_ $calibration)
            })
        }
        $state = if ($null -eq $calibration) {
            '按鈕 {0} 顆；等待三顆可見按鈕中恰有兩顆同尺寸，暫不點擊。' -f $buttons.Count
        } else {
            '按鈕 {0} 顆；符合寶箱尺寸 {1} 顆。' -f $buttons.Count, $candidates.Count
        }
        if ($state -ne $lastState) { Write-Log $state; $lastState = $state }
        if (-not $Auto) {
            foreach ($button in $buttons) {
                Write-Host ('尺寸={0}x{1} | 寶箱候選={2} | Enabled={3} | Invoke={4}' -f
                    $button.Width, $button.Height,
                    ($candidates.Key -contains $button.Key), $button.Enabled, $button.Invoke)
            }
            break
        }
        if ($null -ne $pending) {
            $stillPresent = @($buttons | Where-Object { $_.Key -eq $pending.Key })
            if ($stillPresent.Count -eq 0) {
                Write-Log '剛才的寶箱按鈕已消失；繼續等待下一顆。'
                $pending = $null
            } elseif (((Get-Date) - $pending.SentAt).TotalSeconds -gt 90) {
                throw '點擊後 90 秒內按鈕仍未消失，已停止且不重複點擊。請查看是否點擊數不足或有錯誤提示。'
            }
        }
        if ($null -eq $pending) {
            # Re-find controls each cycle; never retain screen coordinates.
            foreach ($button in $candidates) {
                $element = $button.Element
                $c = $element.Current
                if (-not $c.IsEnabled -or $c.IsOffscreen) { continue }
                # Revalidate size and identity immediately before invoking.
                $fresh = Get-ButtonSnapshot $element
                if ($fresh.Key -ne $button.Key -or -not (Test-DesktopButton $fresh) -or
                    -not (Test-SameSize $fresh $calibration)) { continue }
                $invokeObject = $null
                if (-not $element.TryGetCurrentPattern(
                    [System.Windows.Automation.InvokePattern]::Pattern, [ref]$invokeObject)) {
                    throw '寶箱按鈕不支援 Invoke 操作；未點擊，也不會改用滑鼠亂點。'
                }
                $key = $fresh.Key
                # Mark pending before dispatch: any exception stops without retries.
                $pending = @{ Key = $key; SentAt = Get-Date }
                Write-Log '已找到可操作的寶箱，送出一次原程式按鈕操作。'
                ([System.Windows.Automation.InvokePattern]$invokeObject).Invoke()
                break
            }
        }
        Start-Sleep -Seconds 5
    }
} catch {
    Write-Log ('已停止：' + $_.Exception.Message)
    if ($Auto) { Write-Log '若剛送出按鈕操作，請查看程式是否已領取；腳本不會自動重試。' }
    exit 1
} finally {
    if ($hasMutex -and $null -ne $mutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
