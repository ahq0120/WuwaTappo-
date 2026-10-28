# Wuwa Tappo simultaneous UI Automation helper, Windows PowerShell 5.1.
# Default: inspect only. -Auto: invoke recognized chest buttons.
# Does not read credentials, call game APIs, move the mouse, or change files.
[CmdletBinding()]
param(
    [switch]$Auto,
    [double]$ChestWidth = 62,
    [double]$ChestHeight = 44
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

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
function Is-Chest($Element) {
    $c = $Element.Current
    $r = $c.BoundingRectangle
    return ([string]::IsNullOrEmpty($c.Name) -and
        [string]::IsNullOrEmpty($c.AutomationId) -and
        -not $c.IsOffscreen -and $r.Width -gt 0 -and $r.Height -gt 0 -and
        [Math]::Abs($r.Width - $ChestWidth) -le 1 -and
        [Math]::Abs($r.Height - $ChestHeight) -le 1)
}
function Get-ElementKey($Element) {
    return ($Element.GetRuntimeId() -join ':')
}

$mutex = $null
$hasMutex = $false
try {
    if ($ChestWidth -lt 20 -or $ChestHeight -lt 20 -or
        $ChestWidth / $ChestHeight -lt 1.25 -or $ChestWidth / $ChestHeight -gt 1.65) {
        throw '寶箱尺寸不合理。預設是你提供的 62 x 44；勿填入設定按鈕的尺寸。'
    }
    if ($Auto) {
        $mutex = New-Object System.Threading.Mutex($false, 'Local\WuwaTappoUIAAutoChestV1')
        $hasMutex = $mutex.WaitOne(0)
        if (-not $hasMutex) { throw '已有一個同時執行版正在運作，請先關閉另一個。' }
    }
    Write-Log ('模式：' + $(if ($Auto) { '自動領取；由原程式正常處理開箱與扣點。' } else { '只檢查，不點擊。' }))
    Write-Log ('辨識條件：Wuwa Tappo 主視窗內、無名稱的 {0} x {1} 按鈕。' -f $ChestWidth, $ChestHeight)
    Write-Log '請關閉背包／設定等面板，保持桌寵可見。位置可以移動；縮放改變需重新確認尺寸。'
    if ($Auto) { Write-Log '每 5 秒檢查；Ctrl+C 或關閉這個 CMD 可停止。請勿同時執行舊版 API 自動領取。' }
    $pending = $null
    $lastState = ''
    while ($true) {
        $window = Get-GameWindow
        $buttons = @(Get-Buttons $window)
        # The verified desktop has one settings button, plus up to two chests.
        # Pause instead of acting inside an unexpected panel.
        if ($buttons.Count -gt 3) {
            throw '偵測到額外按鈕，已停止；請關閉背包、設定等面板，再重新啟動。'
        }
        $candidates = @($buttons | Where-Object { Is-Chest $_ })
        if ($candidates.Count -gt 2) { throw '符合尺寸的按鈕超過兩顆，無法確認寶箱，已停止。' }
        $state = '按鈕 {0} 顆；符合寶箱尺寸 {1} 顆。' -f $buttons.Count, $candidates.Count
        if ($state -ne $lastState) { Write-Log $state; $lastState = $state }
        if (-not $Auto) {
            foreach ($button in $buttons) {
                $c = $button.Current
                $invokeObject = $null
                $supported = $button.TryGetCurrentPattern(
                    [System.Windows.Automation.InvokePattern]::Pattern, [ref]$invokeObject)
                Write-Host ('尺寸={0}x{1} | 寶箱候選={2} | Enabled={3} | Invoke={4}' -f
                    $c.BoundingRectangle.Width, $c.BoundingRectangle.Height,
                    (Is-Chest $button), $c.IsEnabled, $supported)
            }
            break
        }
        if ($null -ne $pending) {
            $stillPresent = @($buttons | Where-Object { (Get-ElementKey $_) -eq $pending.Key })
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
                $c = $button.Current
                if (-not $c.IsEnabled -or $c.IsOffscreen) { continue }
                $invokeObject = $null
                if (-not $button.TryGetCurrentPattern(
                    [System.Windows.Automation.InvokePattern]::Pattern, [ref]$invokeObject)) {
                    throw '寶箱按鈕不支援 Invoke 操作；未點擊，也不會改用滑鼠亂點。'
                }
                $key = Get-ElementKey $button
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
