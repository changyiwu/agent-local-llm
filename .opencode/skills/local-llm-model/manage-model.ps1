#requires -Version 7.0
<#
.SYNOPSIS
    在已經設定好 Ollama 的電腦上加入、試跑、移除單一模型，並同步 OpenCode 設定。

.DESCRIPTION
    和 local-llm-setup 分工：那支處理「一台電腦做一次」的事（裝 Ollama、全域上下文、GUI 覆蓋），
    這支處理「會一直重複」的事（拉新模型、給它專屬上下文、量速度、不要了刪乾淨）。
    任何 Ollama registry 上的模型都能用，不限 Gemma。

    所有會改動系統的步驟（下載模型、建立衍生模型、卸載其他模型、改 opencode.json、刪模型）
    都會先詢問；加 -Yes 才會全程不問。

.EXAMPLE
    pwsh -NoProfile -File .\manage-model.ps1
    列出本機模型、各自實際會載入的上下文、OpenCode 設定是否對得上。

.EXAMPLE
    pwsh -NoProfile -File .\manage-model.ps1 -Add qwen3.8:27b -Context 32768
    下載 qwen3.8:27b、建立 num_ctx 32768 的衍生模型 qwen3.8:27b-ctx32k、寫進 OpenCode、量速度。

.EXAMPLE
    pwsh -NoProfile -File .\manage-model.ps1 -Bench gemma4:12b
    量生成速度與 CPU/GPU 分配。

.EXAMPLE
    pwsh -NoProfile -File .\manage-model.ps1 -Remove gemma4:31b-it-qat
    刪掉模型與它的衍生模型，並從所有 OpenCode 設定檔移除。
#>
[CmdletBinding(DefaultParameterSetName = 'List')]
param(
    # 下載（還沒有的話）並接進 OpenCode 的模型 tag（例：qwen3.8:27b）
    [Parameter(Mandatory, ParameterSetName = 'Add')]
    [string] $Add,

    # 量測生成速度與 CPU/GPU 分配的模型 tag
    [Parameter(Mandatory, ParameterSetName = 'Bench')]
    [string] $Bench,

    # 要從 Ollama 與 OpenCode 設定移除的模型 tag（連同 <tag>-ctx<n> 衍生模型）
    [Parameter(Mandatory, ParameterSetName = 'Remove')]
    [string] $Remove,

    # 列出本機模型與上下文比對（不給任何參數時的預設動作）
    [Parameter(ParameterSetName = 'List')]
    [switch] $List,

    # 只給這顆模型的上下文：用 Modelfile 建衍生模型，不動全域 OLLAMA_CONTEXT_LENGTH
    [Parameter(ParameterSetName = 'Add')]
    [ValidateRange(2048, 1048576)]
    [int] $Context,

    # 加入後不量速度（量測會把模型載入，大模型要好幾分鐘）
    [Parameter(ParameterSetName = 'Add')]
    [switch] $NoBench,

    # 量測次數
    [Parameter(ParameterSetName = 'Add')]
    [Parameter(ParameterSetName = 'Bench')]
    [ValidateRange(1, 10)]
    [int] $Runs = 2,

    # OpenCode 全域設定檔位置
    [string] $ConfigPath = (Join-Path $HOME '.config/opencode/opencode.json'),

    # 全程不詢問，直接執行
    [switch] $Yes
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ConfigPathExplicit = $PSBoundParameters.ContainsKey('ConfigPath')

$LibPath = Join-Path $PSScriptRoot '../../lib/LocalLlm.ps1'
if (-not (Test-Path $LibPath)) {
    throw "找不到共用函式庫 $LibPath。這個技能要放在 agent-local-llm 專案裡使用，不能單獨把技能資料夾複製出去。"
}
. $LibPath

# ---------------------------------------------------------------- 動作

function Assert-OllamaReady {
    if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
        throw '找不到 ollama。這台還沒設定過，先用 local-llm-setup 技能跑一次。'
    }
    if (-not (Test-OllamaUp)) {
        throw "Ollama 服務沒在跑（$OllamaApi 連不上）。先開啟 Ollama 桌面 app 或執行 ollama serve。"
    }
}

function Invoke-ModelBench {
    param([string] $Tag, [int] $Times)

    $Tag = ConvertTo-FullTag -Tag $Tag
    if (@(Get-InstalledModels | ForEach-Object Name) -notcontains $Tag) {
        throw "Ollama 上沒有 $Tag。先用 -Add 加入。"
    }
    $caps = Get-ModelCapabilities -Info (Get-OllamaModelInfo -Tag $Tag)

    try { Write-Info "硬體：$((Get-HardwareReport).Reason)" } catch { }
    Clear-OtherLoadedModels -Tag $Tag

    Write-Info "生成 300 tokens × $Times 次（關閉 thinking）。權重掉到 CPU 的大模型一次可能要好幾分鐘 ..."
    $results  = @()
    $warmedUp = $false
    while ($results.Count -lt $Times) {
        $r = Measure-ModelSpeed -Tag $Tag -Capabilities $caps
        if (-not $r) { break }
        # 只丟一次，免得模型每次都重新載入時無限重量
        if ((Test-ColdRun $r) -and -not $warmedUp) {
            $warmedUp = $true
            Write-Info "暖機：生成 $($r.EvalTps) tok/s，含 $($r.LoadSec) 秒載入。冷載入後第一次的數字偏低，不列入，另外補量一次"
            continue
        }
        $results += $r
        $load = if (Test-ColdRun $r) { "，又重新載入了一次（$($r.LoadSec) 秒），這個數字可能偏低" } else { '' }
        Write-Ok "第 $($results.Count) 次：生成 $($r.EvalTps) tok/s（$($r.EvalCount) tokens），讀提示 $($r.PromptTps) tok/s$load"
    }
    if ($results.Count -gt 1) {
        Write-Ok "平均生成 $(Get-AverageEvalTps -Results $results) tok/s（$($results.Count) 次）"
    }

    $loaded = Get-LoadedModels | Where-Object { $_.Name -eq $Tag } | Select-Object -First 1
    if ($loaded) {
        Write-Ok "載入狀態：$($loaded.Processor)，上下文 $($loaded.Context)"
        if ($loaded.Processor -ne '100% GPU') {
            Write-Warn2 '有部分層在 CPU 上跑。密集模型每個 token 都要穿過 CPU 那段，速度會掉一個數量級（MoE 影響小得多）。'
            Write-Info  '  想讓更多層回到 GPU：用 -Add <原模型> -Context <較小值> 建衍生模型，KV cache 少佔一點顯存，再量一次。'
        }
    }
    Write-Info "量完要換回常用模型：ollama stop $Tag"
}

function Invoke-ModelAdd {
    param([string] $Tag, [int] $Ctx)

    $Tag = ConvertTo-FullTag -Tag $Tag

    Write-Step '評估'
    $hw = $null
    try { $hw = Get-HardwareReport; Write-Info "硬體：$($hw.Reason)" }
    catch { Write-Warn2 "讀不到硬體資訊：$($_.Exception.Message)" }

    $inst = @(Get-InstalledModels) | Where-Object { $_.Name -eq $Tag } | Select-Object -First 1
    $sizeBytes = if ($inst -and $inst.SizeBytes) { $inst.SizeBytes } else { Get-RegistryModelSizeBytes -Tag $Tag }
    if ($sizeBytes) { Write-Info "模型大小：$(Format-GB $sizeBytes)" }
    else { Write-Warn2 "查不到 $Tag 的大小（不在 Ollama registry，或 tag 打錯）" }

    $fit = 'unknown'
    if ($hw -and $sizeBytes) {
        $weights = [math]::Round($sizeBytes / 1GB, 1)
        $fit = Get-FitEstimate -WeightsGiB ($sizeBytes / 1GB) -UsableGiB $hw.UsableGB
        switch ($fit) {
            'offload' { Write-Warn2 "權重約 $weights GB，大於可用顯存 $($hw.UsableGB) GB，一定有部分層跑在 CPU。密集模型會慢一個數量級（16GB 卡跑 gemma4:31b-it-qat 只剩 3.9 tok/s），MoE 影響小得多。" }
            'tight'   { Write-Warn2 "權重約 $weights GB，接近可用顯存 $($hw.UsableGB) GB，加上 KV cache 可能有幾層掉到 CPU。" }
            'fits'    { Write-Ok    "權重約 $weights GB，塞得進可用顯存 $($hw.UsableGB) GB。" }
            'cpu'     { Write-Warn2 '沒有 Ollama 可用的 GPU，會用 CPU 跑，非常慢。' }
        }
        if ($fit -ne 'cpu') { Write-Info '  （下載大小不等於顯存佔用，這只是粗估；實際分配看最後量測的 CPU/GPU 比例）' }
    }

    $global = Get-GlobalContext
    if ($Ctx) {
        $g = if ($global) { $global } else { '未知' }
        Write-Info "上下文：$Ctx，用 Modelfile 只套在這顆模型（全域 $g 不動）"
    }
    elseif ($global) {
        Write-Info "上下文：沿用全域 $global"
        if ($fit -in 'offload', 'tight' -and $global -gt 32768) {
            Write-Warn2 "全域 $global 也會套在這顆模型上，KV cache 會再擠掉一些層。建議加 -Context 32768 只給它較小的上下文。"
        }
    }
    else {
        throw '讀不到全域上下文（server log 與 OLLAMA_CONTEXT_LENGTH 都沒有），請用 -Context 指定這顆模型的上下文。'
    }

    Write-Step '下載模型'
    Install-OllamaModel -Tag $Tag -SizeBytes $sizeBytes

    $caps = Get-ModelCapabilities -Info (Get-OllamaModelInfo -Tag $Tag)
    if ($null -eq $caps) {
        Write-Warn2 '這版 Ollama 沒回報模型能力，OpenCode 設定只開 tool_call'
    } else {
        Write-Info "模型能力：$($caps -join ', ')"
        if ($caps -notcontains 'tools') {
            Write-Warn2 "$Tag 不支援工具呼叫 —— 在 OpenCode 裡只能聊天，agent 讀不了檔也改不了程式"
        }
    }

    $useTag = $Tag
    $useCtx = $global
    if ($Ctx) {
        Write-Step '建立專屬上下文的衍生模型'
        $derived = New-ContextDerivedModel -Tag $Tag -Context $Ctx
        if (-not $derived) { throw '使用者取消建立衍生模型。' }
        $useTag = $derived
        $useCtx = $Ctx
    }

    Write-Step '寫入 OpenCode 設定'
    $resolved = Resolve-OpenCodeConfig -Path $ConfigPath -Explicit $ConfigPathExplicit
    Write-ConfigLayoutWarning -Resolved $resolved
    if (Confirm-Step "要把 $useTag（limit.context $useCtx）加進 $($resolved.Target) 嗎？（會先自動備份）") {
        Update-OpenCodeConfig -Path $resolved.Target -Tag $useTag -Ctx $useCtx -Capabilities $caps
    } else {
        Write-Warn2 '略過 OpenCode 設定'
    }

    Write-Step '驗證'
    Clear-OtherLoadedModels -Tag $useTag
    $null = Test-ModelChat -Tag $useTag

    if (-not $NoBench) {
        Write-Step '量測速度'
        Invoke-ModelBench -Tag $useTag -Times $Runs
    }
}

function Invoke-ModelRemove {
    param([string] $Tag)

    $up = Test-OllamaUp
    $installed = @()
    if ($up) { $installed = @(Get-InstalledModels | ForEach-Object Name) }
    else { Write-Warn2 'Ollama 服務沒在跑，這次只清 OpenCode 設定，模型檔不會刪' }

    $resolved   = Resolve-OpenCodeConfig -Path $ConfigPath -Explicit $ConfigPathExplicit
    $configured = Get-ConfiguredModels -Resolved $resolved
    $targets    = @(Get-RemovalTargets -Tag $Tag -Installed $installed -Configured @($configured.Keys))
    if (-not $targets) { Write-Warn2 "Ollama 與 OpenCode 設定裡都找不到 $Tag"; return }

    Write-Step '要移除的項目'
    foreach ($t in $targets) {
        $places = @()
        if ($installed -contains $t) { $places += 'Ollama' }
        if ($configured.Contains($t)) { $places += @($configured[$t] | ForEach-Object { Split-Path -Leaf $_.File }) }
        Write-Info "$t（$($places -join '、')）"
    }
    Write-Info '衍生模型與原模型共用權重，全部刪掉才會真的釋出磁碟空間。'

    if (-not (Confirm-Step '確定要全部移除嗎？')) { Write-Warn2 '已取消'; return }

    $loaded = @(Get-LoadedModels | ForEach-Object Name)
    foreach ($t in @($targets | Where-Object { $installed -contains $_ })) {
        if ($loaded -contains $t) { $null = & ollama stop $t 2>&1 }   # 收掉 CLI 的轉圈圈控制字元
        & ollama rm $t
        if ($LASTEXITCODE -ne 0) { Write-Warn2 "ollama rm $t 失敗（exit $LASTEXITCODE）" }
        else { Write-Ok "已從 Ollama 刪除 $t" }
    }

    foreach ($p in $resolved.Present) {
        $leaf    = Split-Path -Leaf $p
        $removed = @(Remove-OpenCodeModels -Path $p -Tags $targets)
        if ($removed) { Write-Ok "已從 $leaf 移除：$($removed -join '、')" }
        foreach ($ref in @(Get-ConfigModelReferences -Config (Read-OpenCodeConfig -Path $p) -Tags $targets)) {
            Write-Warn2 "$leaf 的 $ref 還指著剛刪掉的模型，OpenCode 會選到不存在的模型 —— 請改成別的模型"
        }
    }
}

function Invoke-ModelList {
    Write-Step '本機模型與 OpenCode 設定'
    Write-ModelInventory -ConfigPath $ConfigPath -Explicit $ConfigPathExplicit

    Format-LoadedModelLines -Models (Get-LoadedModels) | ForEach-Object { Write-Info $_ }
}

# ---------------------------------------------------------------- 主流程

if (-not ($IsWindows -or $IsMacOS)) { throw '本腳本只支援 Windows 與 Apple Silicon macOS。' }

Write-Host ''
Write-Host '=== OpenCode x 本機模型：模型管理 ===' -ForegroundColor Magenta

switch ($PSCmdlet.ParameterSetName) {
    'Add'    { Assert-OllamaReady; Invoke-ModelAdd -Tag $Add -Ctx $Context }
    'Bench'  { Assert-OllamaReady; Invoke-ModelBench -Tag $Bench -Times $Runs }
    'Remove' { Invoke-ModelRemove -Tag $Remove }
    default  { Invoke-ModelList }
}
