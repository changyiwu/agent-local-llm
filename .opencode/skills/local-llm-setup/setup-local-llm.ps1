#requires -Version 7.0
<#
.SYNOPSIS
    在新電腦上一次設定好「OpenCode 呼叫本機模型（Ollama）」。

.DESCRIPTION
    流程：偵測顯示卡 -> 選出適合的主力模型 -> 安裝 Ollama -> 拉模型
          -> 設定 Ollama 全域上下文長度 -> 寫入 OpenCode 設定 -> 連線煙霧測試。

    自動選型只會選實測過的 Gemma。要加入、試跑或移除其他模型（Qwen 等），
    改用 local-llm-model 技能的 manage-model.ps1，它不會動到全域上下文。

    所有會改動系統的步驟（安裝軟體、下載模型、設定使用者環境變數、
    覆寫 opencode.json）都會先詢問；加 -Yes 才會全程不問。

.EXAMPLE
    pwsh -NoProfile -File .\setup-local-llm.ps1 -Plan
    只印出偵測結果與建議方案，不做任何改動。

.EXAMPLE
    pwsh -NoProfile -File .\setup-local-llm.ps1
    互動式完整設定。

.EXAMPLE
    pwsh -NoProfile -File .\setup-local-llm.ps1 -Check
    檢查現況：環境變數、實際生效的上下文、每顆模型的 limit.context 與實際值。
#>
[CmdletBinding()]
param(
    # 指定 Ollama 模型 tag，跳過自動選型（例：gemma4:12b）
    [string] $Model,

    # 指定全域上下文長度（token），跳過自動建議
    [int] $Context,

    # KV cache 量化型別；q8_0 可讓相同 VRAM 塞下約兩倍上下文，品質損失很小
    [ValidateSet('f16', 'q8_0', 'q4_0')]
    [string] $KvCache,

    # OpenCode 全域設定檔位置
    [string] $ConfigPath = (Join-Path $HOME '.config/opencode/opencode.json'),

    # 只偵測並印出計畫，不做任何改動
    [switch] $Plan,

    # 只檢查目前狀態（含實際生效的上下文），不做任何改動
    [switch] $Check,

    # 跳過 Ollama 安裝步驟（已自行安裝時使用）
    [switch] $SkipInstall,

    # 全程不詢問，直接執行
    [switch] $Yes
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# 使用者明確指定 -ConfigPath 就完全照辦；沒指定才由腳本判斷 .json / .jsonc 該寫哪份
$ConfigPathExplicit = $PSBoundParameters.ContainsKey('ConfigPath')

$LibPath = Join-Path $PSScriptRoot '../../lib/LocalLlm.ps1'
if (-not (Test-Path $LibPath)) {
    throw "找不到共用函式庫 $LibPath。這個技能要放在 agent-local-llm 專案裡使用，不能單獨把技能資料夾複製出去。"
}
. $LibPath

# ---------------------------------------------------------------- 選型表

$WingetId     = 'Ollama.Ollama'
$InstallerUrl = 'https://ollama.com/download/OllamaSetup.exe'

# 顯示卡 VRAM(GB) -> 建議的 Gemma 版本與上下文。由大到小比對，取第一個符合的。
# 只放實測過或同家族推得出來的 Gemma；其他家族沒實測，不讓腳本自動選中。
# SizeGB 為 Ollama registry 上的下載大小；Ctx 為 f16 KV cache 下的保守值。
# MinVram 刻意壓在標稱值以下（16GB 卡實際回報約 15.9GB，24GB 卡約 23.6GB）。
$GpuProfiles = @(
    @{ MinVram = 46;  Tag = 'gemma4:31b-it-q8_0';    SizeGB = 34;  Ctx = 131072; Note = '31B 8-bit，48GB 專業卡，品質最接近原始權重' }
    @{ MinVram = 31;  Tag = 'gemma4:31b-it-qat';     SizeGB = 19;  Ctx = 65536;  Note = '31B QAT，32GB 顯卡' }
    @{ MinVram = 23;  Tag = 'gemma4:26b-a4b-it-qat'; SizeGB = 16;  Ctx = 32768;  Note = '26B MoE（僅啟用 4B），24GB 顯卡上比 31B 密集模型快很多' }
    # 16GB 這階的 131072 是實測值（RTX 5060 Ti 16GB / gemma4:12b）：
    # 4096 佔 8181 MiB、65536 佔 9550 MiB、131072 佔 10291 MiB、262144 佔 12467 MiB，全程 100% GPU。
    # Gemma 用滑動視窗注意力，KV cache 幾乎不隨上下文線性成長，所以可以放很大。
    # 取 131072 而非上限 262144，是為了留 3.7GB 給桌面環境波動；VRAM 一不足就會掉層到 CPU。
    @{ MinVram = 15;  Tag = 'gemma4:12b';            SizeGB = 7.6; Ctx = 131072; Note = '12B Q4_K_M，16GB 顯卡最穩的組合' }
    @{ MinVram = 9.5; Tag = 'gemma4:12b';            SizeGB = 7.6; Ctx = 32768;  Note = '12B Q4_K_M，上下文收斂以免溢位到 RAM' }
    @{ MinVram = 6.5; Tag = 'gemma4:e4b-it-qat';     SizeGB = 6.1; Ctx = 32768;  Note = 'E4B QAT，8GB 顯卡' }
    @{ MinVram = 0;   Tag = 'gemma4:e2b-it-qat';     SizeGB = 4.3; Ctx = 16384;  Note = 'E2B QAT，6GB 以下顯卡的保底選擇' }
)

# 沒有可用獨立顯卡時，改看系統記憶體（純 CPU 推論，速度慢很多）
$CpuProfiles = @(
    @{ MinRam = 32; Tag = 'gemma4:e4b-it-qat'; SizeGB = 6.1; Ctx = 16384; Note = 'CPU 推論，回應會很慢' }
    @{ MinRam = 16; Tag = 'gemma4:e2b-it-qat'; SizeGB = 4.3; Ctx = 8192;  Note = 'CPU 推論，回應會很慢' }
    @{ MinRam = 0;  Tag = 'gemma3:4b-it-qat';  SizeGB = 4.0; Ctx = 8192;  Note = '記憶體不足以跑 Gemma 4，退回 Gemma 3 4B' }
)

function Select-Plan {
    <# 依硬體報告挑出模型與上下文；回傳含 Tag / Ctx / Reason 的物件。 #>
    param($Hardware)

    if ($Hardware.Kind -eq 'GPU') {
        $picked = $GpuProfiles | Where-Object { $Hardware.UsableGB -ge $_.MinVram } | Select-Object -First 1
        return [pscustomobject]@{
            Tag = $picked.Tag; Ctx = $picked.Ctx; SizeGB = $picked.SizeGB
            Note = $picked.Note; Reason = $Hardware.Reason; Device = 'GPU'
        }
    }

    $picked = $CpuProfiles | Where-Object { $Hardware.RamGB -ge $_.MinRam } | Select-Object -First 1
    return [pscustomobject]@{
        Tag = $picked.Tag; Ctx = $picked.Ctx; SizeGB = $picked.SizeGB
        Note = $picked.Note; Reason = $Hardware.Reason; Device = 'CPU'
    }
}

# ---------------------------------------------------------------- 安裝與全域設定

function Install-Ollama {
    if (Get-Command ollama -ErrorAction SilentlyContinue) {
        Write-Ok "Ollama 已安裝（$((& ollama --version) -join ' ')）"
        return
    }
    if ($SkipInstall) { throw '找不到 ollama，且指定了 -SkipInstall。' }
    if (-not (Confirm-Step '尚未安裝 Ollama，要現在安裝嗎？')) { throw '使用者取消安裝。' }

    if ($IsMacOS) {
        if (-not (Get-Command brew -ErrorAction SilentlyContinue)) {
            throw '找不到 Homebrew。請先安裝 Homebrew，或自行到 https://ollama.com/download 下載 macOS 版後再跑一次。'
        }
        Write-Info '透過 Homebrew 安裝 ollama cask ...'
        & brew install --cask ollama
        if ($LASTEXITCODE -ne 0) { throw "brew install --cask ollama 失敗（exit $LASTEXITCODE）。" }
        if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
            throw '安裝完成但仍找不到 ollama，請重開終端機後再跑一次。'
        }
        Write-Ok 'Ollama 安裝完成'
        return
    }

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Info "透過 winget 安裝 $WingetId ..."
        & winget install --id $WingetId --exact --source winget --accept-package-agreements --accept-source-agreements
    }
    else {
        Write-Warn2 "沒有 winget，改用官方安裝檔：$InstallerUrl"
        if (-not (Confirm-Step '要下載並執行 OllamaSetup.exe 嗎？')) { throw '使用者取消下載。' }
        $tmp = Join-Path $env:TEMP 'OllamaSetup.exe'
        Invoke-WebRequest -Uri $InstallerUrl -OutFile $tmp
        Start-Process -FilePath $tmp -Wait
    }

    # 安裝後 PATH 尚未在本 session 生效，補上預設安裝路徑
    $ollamaDir = Join-Path $env:LOCALAPPDATA 'Programs\Ollama'
    if (Test-Path $ollamaDir) { $env:Path = "$ollamaDir;$env:Path" }
    if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
        throw '安裝完成但仍找不到 ollama，請重開終端機後再跑一次。'
    }
    Write-Ok 'Ollama 安裝完成'
}

function Set-PersistentEnv {
    param([string] $Name, [string] $Value)
    if ($IsMacOS) {
        # 立即生效，Ollama 的 GUI app 重啟後就讀得到；但活不過重開機，
        # 所以後面還會寫一個 LaunchAgent 補上持久性。
        & launchctl setenv $Name $Value
    } else {
        [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    }
    Set-Item -Path "Env:$Name" -Value $Value
}

function New-MacLaunchAgentXml {
    <# 產生 LaunchAgent 的 plist 內容。抽成獨立函式是為了能在沒有 Mac 的機器上測試。 #>
    param([System.Collections.Specialized.OrderedDictionary] $Vars, [string] $Label = 'ai.ollama.env')

    # 值只會是數字或 f16/q8_0/q4_0 這類字面量，但仍做 XML 跳脫以免將來擴充時出錯
    $esc = { param($s) [System.Security.SecurityElement]::Escape("$s") }
    $cmd = (@($Vars.Keys | ForEach-Object { "launchctl setenv $_ '$($Vars[$_])'" }) -join '; ')

    return @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$(& $esc $Label)</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>-c</string>
        <string>$(& $esc $cmd)</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
"@
}

function Write-MacLaunchAgent {
    <#  launchctl setenv 不會活過重開機。寫一個登入時執行的 LaunchAgent 重設這些變數，
        否則使用者重開機後上下文會悄悄掉回 Ollama 的動態預設值。 #>
    param([System.Collections.Specialized.OrderedDictionary] $Vars)

    $label    = 'ai.ollama.env'
    $agentDir = Join-Path $HOME 'Library/LaunchAgents'
    $plist    = Join-Path $agentDir "$label.plist"

    if (-not (Confirm-Step "要建立 LaunchAgent（$plist）讓設定活過重開機嗎？")) {
        Write-Warn2 '略過 LaunchAgent — 這些變數會在下次重開機後失效'
        return
    }

    if (-not (Test-Path $agentDir)) { New-Item -ItemType Directory -Path $agentDir -Force | Out-Null }

    $xml = New-MacLaunchAgentXml -Vars $Vars -Label $label
    [System.IO.File]::WriteAllText($plist, $xml, (New-Object System.Text.UTF8Encoding($false)))

    $uid = "$(& id -u)".Trim()
    & launchctl bootout "gui/$uid/$label" 2>$null      # 舊的先卸載，忽略「本來就沒有」的錯誤
    & launchctl bootstrap "gui/$uid" $plist 2>$null
    Write-Ok "LaunchAgent 已建立：$plist"
    Write-Info "要移除：launchctl bootout gui/$uid/$label && rm '$plist'"
}

function Set-OllamaContext {
    param([int] $Ctx, [string] $KvCacheType)

    $wanted = [ordered]@{ OLLAMA_CONTEXT_LENGTH = "$Ctx" }
    if ($KvCacheType) {
        # KV cache 量化需要 flash attention 才會生效
        $wanted['OLLAMA_FLASH_ATTENTION'] = '1'
        $wanted['OLLAMA_KV_CACHE_TYPE']   = $KvCacheType
    }

    $target  = if ($IsMacOS) { 'launchctl 環境變數' } else { '使用者環境變數' }
    $changed = $false
    foreach ($name in $wanted.Keys) {
        $current = Get-PersistentEnv -Name $name
        if ($current -eq $wanted[$name]) { Write-Ok "$name 已是 $($wanted[$name])"; continue }
        $was = if ($current) { $current } else { '未設定' }
        if (-not (Confirm-Step "要把${target} $name 設為 $($wanted[$name]) 嗎？（原值：$was）")) {
            Write-Warn2 "略過 $name"
            continue
        }
        Set-PersistentEnv -Name $name -Value $wanted[$name]
        Write-Ok "$name = $($wanted[$name])"
        $changed = $true
    }

    if ($changed -and $IsMacOS) { Write-MacLaunchAgent -Vars $wanted }
    return $changed
}

# ---------------------------------------------------------------- 檢查

function Show-Status {
    Write-Step '目前狀態'
    if (Get-Command ollama -ErrorAction SilentlyContinue) {
        Write-Ok "ollama：$((& ollama --version) -join ' ')"
    } else { Write-Warn2 'ollama：未安裝' }

    if (Test-OllamaUp) { Write-Ok "服務：$OllamaApi 可連線" } else { Write-Warn2 '服務：未啟動' }

    $envHints = [ordered]@{
        OLLAMA_CONTEXT_LENGTH  = '未設定 — Ollama 會依 VRAM 自行決定，未滿 23GB 只給 4096，跑 agent 一定不夠'
        OLLAMA_FLASH_ATTENTION = '未設定（選用；搭配 KV cache 量化時才需要）'
        OLLAMA_KV_CACHE_TYPE   = '未設定（選用；設 q8_0 可用相同 VRAM 塞下約兩倍上下文）'
    }
    foreach ($n in $envHints.Keys) {
        $v = Get-PersistentEnv -Name $n
        if ($v) { Write-Ok "$n = $v" } else { Write-Warn2 "$n $($envHints[$n])" }
    }

    # 環境變數設對了不代表 Ollama 真的吃到 —— 桌面 app 會用 GUI 設定蓋掉它
    $null = Test-RuntimeContext -Persisted (Get-PersistentEnv -Name 'OLLAMA_CONTEXT_LENGTH')

    if ($IsMacOS) {
        $plist = Join-Path $HOME 'Library/LaunchAgents/ai.ollama.env.plist'
        if (Test-Path $plist) { Write-Ok 'LaunchAgent 存在，設定可活過重開機' }
        else { Write-Warn2 '沒有 LaunchAgent — launchctl 的設定會在重開機後失效' }
    }

    Write-Step '模型與 OpenCode 設定'
    Write-ModelInventory -ConfigPath $ConfigPath -Explicit $ConfigPathExplicit

    if (Test-OllamaUp) {
        Format-LoadedModelLines -Models (Get-LoadedModels) | ForEach-Object { Write-Info $_ }
    }
}

# ---------------------------------------------------------------- 主流程

if (-not ($IsWindows -or $IsMacOS)) { throw '本腳本只支援 Windows 與 Apple Silicon macOS。' }

Write-Host ''
Write-Host '=== OpenCode x 本機模型（Ollama）設定精靈 ===' -ForegroundColor Magenta

if ($Check) { Show-Status; return }

Write-Step '偵測硬體'
$hw = Get-HardwareReport
foreach ($line in $hw.Lines) { Write-Info $line }

Write-Step '選擇方案'
$auto = Select-Plan -Hardware $hw
$tag  = if ($Model)   { $Model }   else { $auto.Tag }
$ctx  = if ($Context) { $Context } else { $auto.Ctx }

Write-Info "依據　：$($auto.Reason)"
if ($Model) { Write-Info "模型　：$tag（由 -Model 指定）" }
else        { Write-Info "模型　：$tag　約 $($auto.SizeGB) GB — $($auto.Note)" }
if ($Context) { Write-Info "上下文：$ctx tokens（由 -Context 指定，全域生效）" }
else          { Write-Info "上下文：$ctx tokens（全域生效）" }
if ($KvCache) { Write-Info "KV cache：$KvCache（可用相同 VRAM 塞下更長上下文）" }
if ($auto.Device -eq 'CPU') { Write-Warn2 '純 CPU 推論會非常慢，只建議拿來確認流程能通。' }

if ($Plan) {
    Write-Host "`n（-Plan 模式，未做任何改動）" -ForegroundColor Magenta
    return
}

Write-Step '安裝 Ollama'
Install-Ollama
if (-not (Test-OllamaUp)) { Restart-OllamaServer }

Write-Step '設定上下文長度'
$envChanged = Set-OllamaContext -Ctx $ctx -KvCacheType $KvCache

Write-Step '下載模型'
# 自動選型的大小來自選型表；-Model 指定的就交給 Install-OllamaModel 去 registry 查
$sizeBytes = if ($Model) { $null } else { $auto.SizeGB * 1e9 }
Install-OllamaModel -Tag $tag -SizeBytes $sizeBytes

if ($envChanged) {
    Write-Step '套用環境變數'
    Restart-OllamaServer
}

Write-Step '寫入 OpenCode 設定'
$caps = Get-ModelCapabilities -Info (Get-OllamaModelInfo -Tag $tag)
$resolved = Resolve-OpenCodeConfig -Path $ConfigPath -Explicit $ConfigPathExplicit
Write-ConfigLayoutWarning -Resolved $resolved
if (Confirm-Step "要更新 $($resolved.Target) 嗎？（會先自動備份）") {
    Update-OpenCodeConfig -Path $resolved.Target -Tag $tag -Ctx $ctx -Capabilities $caps
} else {
    Write-Warn2 '略過 OpenCode 設定'
}

Write-Step '驗證'
$null = Test-ModelChat -Tag $tag

# 每一步都回報成功、實際生效的卻是別的值 —— 這是最難查的故障，所以收尾前一定要對一次
$ctxOk = Test-RuntimeContext -Persisted (Get-PersistentEnv -Name 'OLLAMA_CONTEXT_LENGTH')

if ($ctxOk) {
    Write-Host "`n完成。" -ForegroundColor Magenta
    Write-Info '上下文由 Ollama 伺服器決定，腳本已重啟它並套用設定，上面的 CONTEXT 欄位就是實際生效值。'
    Write-Info '若日後自行從舊的終端機執行 ollama serve，記得那個 shell 可能還沒有新的環境變數 — 開新終端機即可。'
    Write-Info '要再加入或試跑其他模型，用 local-llm-model 技能（不會動到這裡設的全域上下文）。'
} else {
    Write-Host "`n設定已寫入，但實際生效的上下文不是預期值 —— 請照上面的修法處理後再跑一次 -Check。" -ForegroundColor Yellow
}
