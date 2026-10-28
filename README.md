# Wuwa Tappo 寶箱自動領取

透過 Windows UI Automation 操作 Wuwa Tappo 自己的寶箱按鈕。桌寵可以保持開啟；位置可以移動。每 5 秒檢查，逐顆操作，不移動滑鼠、不讀取登入憑證、不直接呼叫遊戲 API。

這是非官方工具，僅在一組 Windows 環境確認成功。

## 使用方式

1. 下載或 clone 本儲存庫。若下載 ZIP，請先解壓縮。
2. 開啟 Wuwa Tappo，讓桌寵保持可見；關閉背包、設定等面板。
3. 在 `start.bat` 按右鍵，選擇「以系統管理員身分執行」。請先閱讀腳本內容，再使用適當權限執行。
4. 保持命令列視窗開啟。按 Ctrl+C，或關閉該視窗停止。

需要 Windows 10/11 內建 Windows PowerShell 5.1；不需要 Python、Git 或其他套件。`start.bat` 和 `wuwa_live.ps1` 必須在同一個資料夾。啟動指令中的 ExecutionPolicy Bypass 只適用這次 PowerShell 程序，不永久更改執行原則。

## 辨識方式與限制

目前經使用者驗證的桌面有兩顆無名稱、無 AutomationId 的 62×44 寶箱按鈕，以及一顆 38×32 按鈕。工具依主程式視窗、控制項類型、名稱和尺寸篩選，再使用 InvokePattern 操作；它不是依畫面座標或圖片辨識。

- 預設寶箱尺寸是 62×44，容許誤差 1 像素。桌寵縮放、螢幕 DPI 或介面更新可能使辨識失效。
- 保持桌寵可見；縮小、隱藏、螢幕鎖定或休眠時不保證可用。
- 程式正常扣除開箱所需點擊數；工具不會增加或偽造點擊數。
- 不要同時執行其他自動開箱工具，尤其是直接呼叫 API 的版本。
- 工具會操作符合條件的按鈕，沒有 API 層的領取結果驗證。請先觀察第一輪操作是否正確。
- 點擊後會等待該按鈕消失；90 秒未消失就停止，不重複點擊。點擊數不足或網路錯誤時，請回原程式查看提示。
- 額外按鈕超過預期、無法確認主視窗或不支援 InvokePattern 時會停止。

## 只檢查，不領取

在 CMD 執行：

```bat
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "完整路徑\wuwa_live.ps1"
```

可領取時，應看到兩顆寶箱候選且 `Invoke=True`。預設不帶 `-Auto` 不會點擊。

若已確認其他縮放下的實際寶箱按鈕尺寸，可指定：

```bat
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "完整路徑\wuwa_live.ps1" -Auto -ChestWidth 62 -ChestHeight 44
```

請填入實際量得的寶箱尺寸，不要填設定按鈕尺寸。

## 分享

只分享本儲存庫內的腳本與說明。不需要附上 WuwaTappo.exe、Cookies、Token 或 AppData。
