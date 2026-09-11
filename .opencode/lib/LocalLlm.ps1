#requires -Version 7.0
<#
    agent-local-llm 的共用函式庫。local-llm-setup 與 local-llm-model 兩個技能的腳本都 dot-source 這支。

    用 dot-source 的 .ps1 而不是 .psm1：模組有自己的作用域，裡面的函式讀不到呼叫端腳本的
    $Yes 這類參數，Confirm-Step 就得每次多傳一個參數。這支只定義常數與函式、不執行任何流程，
    所以測試可以直接 dot-source，不必像主腳本那樣用 AST 抽函式。

    呼叫端要自己定義 $Yes（Confirm-Step 會讀）。
#>

# ---------------------------------------------------------------- 常數

$OllamaApi      = 'http://localhost:11434'
$OllamaRegistry = 'https://registry.ollama.ai'

# 判定為內顯的名稱特徵（內顯不納入選型）
$IntegratedPattern = '(?i)(UHD|HD Graphics|Iris|Vega|Radeon\(TM\) Graphics|Integrated|Microsoft Basic|Remote Display)'

# ---------------------------------------------------------------- 輸出小工具

function Write-Step  { param([string]$m) Write-Host "`n>> $m" -ForegroundColor Cyan }
function Write-Ok    { param([string]$m) Write-Host "   [OK] $m" -ForegroundColor Green }
function Write-Warn2 { param([string]$m) Write-Host "   [!]  $m" -ForegroundColor Yellow }
function Write-Info  { param([string]$m) Write-Host "   $m" -ForegroundColor Gray }

function Confirm-Step {
    param([string] $Message)
    if ($Yes) { Write-Info "$Message -> 已用 -Yes 自動同意"; return $true }
    $answer = Read-Host "   $Message [Y/n]"
    return ($answer -eq '' -or $answer -match '^[Yy]')
}

function Get-JsonProp {
    <#  StrictMode 下讀不存在的屬性會丟例外，而 Ollama 各版本、各模型的 API 回應欄位並不一致：
        舊版 /api/ps 沒有 context_length、沒設參數的模型 /api/show 不帶 parameters、
        不會 thinking 的模型回應裡沒有 message.reasoning。讀 API 回應一律走這支。 #>
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Format-GB {
    <# 用十進位 GB，和 ollama list 與 registry 網頁上的數字對得起來。 #>
    param([double] $Bytes)
    return ('{0:0.#} GB' -f ($Bytes / 1e9))
}

# ---------------------------------------------------------------- 硬體偵測

function Get-GpuInventory {
    <#  回傳每張顯示卡的 Name / VramGB / Vendor / IsIntegrated。
        NVIDIA 走 nvidia-smi（最準），其餘走登錄檔 qwMemorySize，
        因為 Win32_VideoController.AdapterRAM 是 32-bit，超過 4GB 會失真。 #>
    $result = [System.Collections.Generic.List[object]]::new()

    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        try {
            $lines = & nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null
            foreach ($line in @($lines)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $parts = $line -split ',\s*'
                $result.Add([pscustomobject]@{
                    Name         = $parts[0].Trim()
                    VramGB       = [math]::Round(([double]$parts[1]) / 1024, 1)
                    Vendor       = 'NVIDIA'
                    IsIntegrated = $false
                })
            }
        } catch { }
    }

    $classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    foreach ($sub in (Get-ChildItem $classKey -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty $sub.PSPath -ErrorAction SilentlyContinue
        if (-not $p -or -not $p.PSObject.Properties['DriverDesc']) { continue }
        $name = [string]$p.DriverDesc
        # 已由 nvidia-smi 回報過的就不重複列
        if ($result | Where-Object { $_.Name -eq $name }) { continue }

        $bytes = 0
        if ($p.PSObject.Properties['HardwareInformation.qwMemorySize']) {
            $bytes = [double]$p.'HardwareInformation.qwMemorySize'
        }
        $vendor = switch -Regex ($name) {
            '(?i)nvidia|geforce|quadro|rtx|tesla' { 'NVIDIA'; break }
            '(?i)amd|radeon'                      { 'AMD';    break }
            '(?i)intel|arc'                       { 'Intel';  break }
            default                               { 'Other' }
        }
        $result.Add([pscustomobject]@{
            Name         = $name
            VramGB       = [math]::Round($bytes / 1GB, 1)
            Vendor       = $vendor
            IsIntegrated = ($name -match $IntegratedPattern)
        })
    }
    return $result
}

function Select-UsableGpu {
    <#  Ollama 在 Windows 上只有 NVIDIA(CUDA) 與部分 AMD 獨顯(ROCm) 能真正吃到 GPU。
        內顯、Intel 顯卡、3GB 以下的舊卡都排除，剩下的由大到小排。 #>
    param($Gpus)
    if (-not $Gpus) { return @() }
    return @($Gpus | Where-Object {
        -not $_.IsIntegrated -and $_.VramGB -ge 3 -and $_.Vendor -in @('NVIDIA', 'AMD')
    } | Sort-Object VramGB -Descending)
}

function Get-SystemRamGB {
    if ($IsMacOS) { return [math]::Round(([double](& sysctl -n hw.memsize)) / 1GB, 1) }
    [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
}

function Get-WindowsHardware {
    $gpus  = Get-GpuInventory
    $ramGB = Get-SystemRamGB

    $lines = @()
    if (@($gpus).Count -eq 0) { $lines += '偵測不到任何顯示卡' }
    foreach ($g in $gpus) {
        $kind = if ($g.IsIntegrated) { '內顯' } else { '獨顯' }
        $lines += ('{0,-40} {1,6} GB  {2,-7} {3}' -f $g.Name, $g.VramGB, $g.Vendor, $kind)
    }
    $lines += "系統記憶體：$ramGB GB"

    $usable = @(Select-UsableGpu -Gpus $gpus)
    if ($usable.Count -gt 0) {
        $gpu = $usable[0]
        $reason = "$($gpu.Name)（$($gpu.VramGB) GB VRAM）"
        if ($gpu.Vendor -eq 'AMD') {
            $reason += ' — AMD 走 ROCm，若 Ollama 回報不支援此 gfx 型號會自動退回 CPU'
        }
        return [pscustomobject]@{ Kind = 'GPU'; UsableGB = $gpu.VramGB; RamGB = $ramGB; Reason = $reason; Lines = $lines }
    }
    return [pscustomobject]@{
        Kind = 'CPU'; UsableGB = 0; RamGB = $ramGB
        Reason = "找不到 Ollama 可用的獨立顯卡，改用 CPU（系統記憶體 $ramGB GB）"
        Lines = $lines
    }
}

function Get-MacHardware {
    <#  只支援 Apple Silicon。統一記憶體是 CPU/GPU 共用，Metal 能取用的上限
        由 iogpu.wired_limit_mb 決定，未調整時約為總記憶體的 65~75%。
        這裡取保守比例，寧可低估也不要載入到一半才發現爆掉。 #>
    $arch = (& uname -m).Trim()
    if ($arch -ne 'arm64') {
        throw "偵測到 $arch 架構的 Mac。本腳本只支援 Apple Silicon（M 系列）；Intel Mac 沒有 Ollama 可用的 GPU 加速，跑起來不堪用。"
    }

    $chip  = (& sysctl -n machdep.cpu.brand_string).Trim()
    $ramGB = Get-SystemRamGB
    $ratio = if ($ramGB -gt 36) { 0.80 } else { 0.70 }
    $usableGB = [math]::Round($ramGB * $ratio, 1)

    $lines = @(
        ('{0,-40} {1,6} GB  統一記憶體' -f $chip, $ramGB)
        ("GPU 可取用約 {0} GB（總記憶體的 {1}%）" -f $usableGB, [int]($ratio * 100))
    )
    return [pscustomobject]@{
        Kind = 'GPU'; UsableGB = $usableGB; RamGB = $ramGB
        Reason = "$chip（統一記憶體 $ramGB GB，GPU 可取用約 $usableGB GB）"
        Lines = $lines
    }
}

function Get-HardwareReport {
    if ($IsWindows) { return Get-WindowsHardware }
    if ($IsMacOS)   { return Get-MacHardware }
    throw '不支援的平台：本腳本只支援 Windows 與 Apple Silicon macOS。'
}

function Get-FitEstimate {
    <#  權重大小對上可用顯存的粗估：fits / tight / offload / cpu / unknown。
        只看下載大小，不含 KV cache 與執行時開銷，所以 tight 的門檻抓 85%。
        下載大小也不等於顯存佔用（gemma4:e4b-it-qat 下載 6.1 GB、載入只佔 3.1 GB），
        這只是動手前的預告，實際分配以量測時 ollama ps 的 CPU/GPU 比例為準。 #>
    param([double] $WeightsGiB, [double] $UsableGiB)
    if ($UsableGiB -le 0) { return 'cpu' }
    if ($WeightsGiB -le 0) { return 'unknown' }
    if ($WeightsGiB -gt $UsableGiB) { return 'offload' }
    if ($WeightsGiB -gt $UsableGiB * 0.85) { return 'tight' }
    return 'fits'
}

# ---------------------------------------------------------------- Ollama 服務

function Test-OllamaUp {
    try {
        $null = Invoke-RestMethod -Uri "$OllamaApi/api/version" -TimeoutSec 3
        return $true
    } catch { return $false }
}

function Wait-OllamaUp {
    param([int] $TimeoutSec = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-OllamaUp) { return $true }
        Start-Sleep -Milliseconds 800
    }
    return $false
}

function Invoke-OllamaApi {
    <# 呼叫 Ollama API；給 Body 就 POST。失敗回 $null，要錯誤訊息的呼叫端請自己 try。 #>
    param([string] $Path, $Body = $null, [int] $TimeoutSec = 10)
    try {
        if ($null -eq $Body) { return Invoke-RestMethod -Uri "$OllamaApi$Path" -TimeoutSec $TimeoutSec }
        $json = $Body | ConvertTo-Json -Depth 10
        return Invoke-RestMethod -Uri "$OllamaApi$Path" -Method Post -ContentType 'application/json; charset=utf-8' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec $TimeoutSec
    } catch { return $null }
}

function Restart-OllamaServer {
    <# 環境變數只有在 server 重啟後才會生效。 #>
    Write-Info '重新啟動 Ollama 服務讓設定生效 ...'

    if ($IsMacOS) {
        # 先禮貌地請 GUI app 結束，再確保背景 serve 也收掉
        & osascript -e 'quit app "Ollama"' 2>$null
        & pkill -x ollama 2>$null
        Start-Sleep -Seconds 2
        if (Test-Path '/Applications/Ollama.app') { & open -a Ollama }
        else { Start-Process -FilePath 'ollama' -ArgumentList 'serve' }
    }
    else {
        # llama-server 才是真正佔著顯存的推論行程，殺 ollama 與 ollama app 不會帶走它
        Get-Process -Name 'ollama', 'ollama app', 'llama-server' -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2

        $appExe = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe'
        if (Test-Path $appExe) { Start-Process -FilePath $appExe }
        else { Start-Process -FilePath 'ollama' -ArgumentList 'serve' -WindowStyle Hidden }
    }

    if (Wait-OllamaUp -TimeoutSec 60) { Write-Ok 'Ollama 服務已就緒' }
    else { Write-Warn2 'Ollama 服務在 60 秒內沒回應，請手動確認。' }
}

function Get-PersistentEnv {
    <# 讀取「跨行程可見」的環境變數：Windows 是使用者環境變數，macOS 是 launchctl。 #>
    param([string] $Name)
    if ($IsMacOS) { return "$(& launchctl getenv $Name 2>$null)".Trim() }
    return [Environment]::GetEnvironmentVariable($Name, 'User')
}

# ---------------------------------------------------------------- 實際生效的上下文

function Get-OllamaLogDir {
    if ($IsMacOS) { return (Join-Path $HOME '.ollama/logs') }
    return (Join-Path $env:LOCALAPPDATA 'Ollama')
}

function Read-ContextFromLogText {
    <#  從 Ollama server log 取出最後一次啟動時「真正注入 server」的上下文長度。
        log 每次啟動會寫一行 msg="server config" env="map[... OLLAMA_CONTEXT_LENGTH:131072 ...]"。
        抽成吃字串的純函式，是為了能在沒有 Ollama 的機器上測。 #>
    param([string] $Text)

    if (-not $Text) { return $null }
    $m = [regex]::Matches($Text, 'OLLAMA_CONTEXT_LENGTH:(\d+)')
    if ($m.Count -eq 0) { return $null }
    return [int] $m[$m.Count - 1].Groups[1].Value
}

function Get-OllamaRuntimeContext {
    <#  環境變數只是「我們希望的值」，這裡讀的才是「跑著的 server 實際拿到的值」。
        兩者會不一致 —— Ollama 0.32 的桌面 app 用自己 GUI 設定裡的 context length
        覆蓋環境變數，完全沒有提示，重開機後又會再蓋一次。找不到 log 就回 $null。 #>
    $dir = Get-OllamaLogDir
    if (-not (Test-Path $dir)) { return $null }

    # server.log 是當前的，server-1.log 以後是輪替過的舊檔；由新到舊找第一個讀得到值的
    $logs = @(Get-ChildItem -Path $dir -Filter 'server*.log' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)
    foreach ($log in $logs) {
        try { $v = Read-ContextFromLogText -Text (Get-Content -Path $log.FullName -Raw -ErrorAction Stop) }
        catch { continue }
        if ($v) { return $v }
    }
    return $null
}

function Write-ContextMismatchWarning {
    <#  持久化設定與實際生效值對不上時的說明與修法。
        這是最難查的那種故障：腳本每一步都回報成功，實際跑的卻是另一個值。 #>
    param([int] $Persisted, [int] $Runtime)

    $where = if ($IsMacOS) { 'Ollama.app 的設定畫面' } else { 'Ollama 桌面 app（工作列圖示）的 Settings' }
    Write-Warn2 "上下文對不上：環境變數是 $Persisted，但跑著的 Ollama 實際用 $Runtime"
    Write-Info  '  Ollama 0.32 的桌面 app 會拿自己 GUI 設定裡的 context length 覆蓋環境變數，且不會提示。'
    Write-Info  "  修法一：到 $where 把 context length 也改成 $Persisted（一勞永逸，重開機也不會跑掉）。"
    Write-Info  '  修法二：關掉桌面 app，改用 ollama serve 啟動服務（環境變數才會是老大）。'
}

function Test-RuntimeContext {
    <# 比對持久化設定與實際生效值並回報。回傳 $true 表示一致或無從判斷。 #>
    param([string] $Persisted)

    $runtime = Get-OllamaRuntimeContext
    if (-not $runtime) { return $true }   # 讀不到 log 就不下結論

    if (-not $Persisted) {
        Write-Info "跑著的 Ollama 實際使用的上下文：$runtime（不是來自環境變數，多半是桌面 app 的 GUI 設定）"
        return $true
    }
    if ([int] $Persisted -ne $runtime) {
        Write-ContextMismatchWarning -Persisted ([int] $Persisted) -Runtime $runtime
        return $false
    }
    Write-Ok "實際生效的上下文：$runtime（與環境變數一致）"
    return $true
}

function Get-GlobalContext {
    <# 全域上下文：優先取 server log 的實際注入值，讀不到才退回持久化的環境變數。 #>
    $runtime = Get-OllamaRuntimeContext
    if ($runtime) { return $runtime }
    $persisted = Get-PersistentEnv -Name 'OLLAMA_CONTEXT_LENGTH'
    if ($persisted -match '^\d+$') { return [int] $persisted }
    return $null
}

# ---------------------------------------------------------------- 模型

function ConvertTo-FullTag {
    <# 沒寫 tag 的名稱等同 :latest，ollama list 列出來的也是完整形式。 #>
    param([string] $Tag)
    if ($Tag.LastIndexOf(':') -gt $Tag.LastIndexOf('/')) { return $Tag }
    return "${Tag}:latest"
}

function Get-InstalledModels {
    <# 回傳 Name / SizeBytes 清單。服務沒起來時退回解析 ollama list（拿不到大小）。 #>
    $tags = Invoke-OllamaApi -Path '/api/tags'
    if ($tags) {
        return @(@(Get-JsonProp $tags 'models') | Where-Object { $_ } | ForEach-Object {
            [pscustomobject]@{ Name = [string](Get-JsonProp $_ 'name'); SizeBytes = [long](Get-JsonProp $_ 'size') }
        })
    }
    if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) { return @() }
    try {
        return @((& ollama list) | Select-Object -Skip 1 | ForEach-Object { ($_ -split '\s+')[0] } |
            Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Name = $_; SizeBytes = [long]0 } })
    } catch { return @() }
}

function Get-OllamaModelInfo {
    param([string] $Tag)
    return Invoke-OllamaApi -Path '/api/show' -Body @{ model = $Tag } -TimeoutSec 30
}

function Get-ModelCapabilities {
    <# 回傳字串陣列（completion / tools / thinking / vision …）；舊版 Ollama 沒這欄位時回 $null。 #>
    param($Info)
    $caps = Get-JsonProp $Info 'capabilities'
    if ($null -eq $caps) { return $null }
    return , @(@($caps) | ForEach-Object { [string] $_ })
}

function Read-NumCtxFromParameters {
    <#  /api/show 的 parameters 是一段「名稱  值」逐行對齊的純文字。
        有 num_ctx 代表這顆是用 Modelfile 釘住上下文的，它會蓋過全域 OLLAMA_CONTEXT_LENGTH。 #>
    param([string] $Text)
    if (-not $Text) { return $null }
    $m = [regex]::Match($Text, '(?m)^\s*num_ctx\s+(\d+)\s*$')
    if (-not $m.Success) { return $null }
    return [int] $m.Groups[1].Value
}

function Get-ModelNumCtx {
    param($Info)
    return Read-NumCtxFromParameters -Text ([string](Get-JsonProp $Info 'parameters'))
}

function ConvertTo-RegistryManifestUrl {
    <#  qwen3.8:27b -> https://registry.ollama.ai/v2/library/qwen3.8/manifests/27b
        沒寫 tag 視為 latest、沒有命名空間視為 library。
        hf.co/... 這類別家 registry 的模型回 $null（大小查不到，不影響下載）。 #>
    param([string] $Tag)
    if (-not $Tag) { return $null }

    $full  = ConvertTo-FullTag -Tag $Tag
    $colon = $full.LastIndexOf(':')
    $name  = $full.Substring(0, $colon)
    $ver   = $full.Substring($colon + 1)

    $segments = $name -split '/'
    if ($segments.Count -gt 2) { return $null }
    if ($segments.Count -eq 2 -and $segments[0] -match '\.') { return $null }
    if ($segments.Count -eq 1) { $name = "library/$name" }
    return "$OllamaRegistry/v2/$name/manifests/$ver"
}

function Get-RegistryModelSizeBytes {
    <# 從 registry manifest 加總各 layer 的大小，就是 ollama pull 要下載的量。查不到回 $null。 #>
    param([string] $Tag)
    $url = ConvertTo-RegistryManifestUrl -Tag $Tag
    if (-not $url) { return $null }
    try {
        $m = Invoke-RestMethod -Uri $url -Headers @{ Accept = 'application/vnd.docker.distribution.manifest.v2+json' } -TimeoutSec 15
    } catch { return $null }

    $total = [long] 0
    foreach ($layer in @(Get-JsonProp $m 'layers')) {
        if ($layer) { $total += [long](Get-JsonProp $layer 'size') }
    }
    $cfg = Get-JsonProp $m 'config'
    if ($cfg) { $total += [long](Get-JsonProp $cfg 'size') }
    if ($total -le 0) { return $null }
    return $total
}

function Get-OllamaModelsDir {
    foreach ($scope in 'Process', 'User') {
        $v = [Environment]::GetEnvironmentVariable('OLLAMA_MODELS', $scope)
        if ($v) { return $v }
    }
    return (Join-Path $HOME '.ollama/models')
}

function Get-FreeSpaceBytes {
    param([string] $Path)
    try {
        $full  = [System.IO.Path]::GetFullPath($Path)
        $drive = [System.IO.DriveInfo]::GetDrives() |
            Where-Object { $_.IsReady -and $full.StartsWith($_.RootDirectory.FullName, [System.StringComparison]::OrdinalIgnoreCase) } |
            Sort-Object { $_.RootDirectory.FullName.Length } -Descending |
            Select-Object -First 1
        if ($drive) { return [long] $drive.AvailableFreeSpace }
    } catch { }
    return $null
}

function Install-OllamaModel {
    <#  已存在就跳過。不知道大小時去 registry 查，並先看磁碟夠不夠 ——
        27B 以上動輒 18 GB，下載到一半才發現塞不下最浪費時間。 #>
    param([string] $Tag, $SizeBytes = $null)

    if (@(Get-InstalledModels | ForEach-Object Name) -contains (ConvertTo-FullTag -Tag $Tag)) {
        Write-Ok "模型 $Tag 已存在"
        return
    }

    if (-not $SizeBytes) { $SizeBytes = Get-RegistryModelSizeBytes -Tag $Tag }
    $sizeText = if ($SizeBytes) { "約 $(Format-GB $SizeBytes)" } else { '大小未知' }

    $free = Get-FreeSpaceBytes -Path (Get-OllamaModelsDir)
    if ($SizeBytes -and $free) {
        Write-Info "模型存放處剩餘空間：$(Format-GB $free)"
        if ($free -lt ($SizeBytes + 2e9)) {
            Write-Warn2 "剩餘空間不夠放 $Tag（$sizeText，另需約 2 GB 餘裕）。先清出空間，或用 local-llm-model 的 -Remove 刪掉用不到的模型。"
        }
    }

    if (-not (Confirm-Step "要下載模型 $Tag（$sizeText）嗎？")) { throw '使用者取消下載模型。' }
    & ollama pull $Tag
    if ($LASTEXITCODE -ne 0) {
        throw ("ollama pull $Tag 失敗（exit $LASTEXITCODE）。若上面的訊息說需要較新版本的 Ollama，先升級；" +
               '升級後跑一次 local-llm-setup 的 -Check —— 大版本升級可能把桌面 app 的 context length 打回 32768。')
    }
    Write-Ok "模型 $Tag 下載完成"
}

function Get-DerivedModelTag {
    <#  qwen3.8:27b + 32768 -> qwen3.8:27b-ctx32k（沿用 PC-YI-FY 上 gemma4:12b-ctx16k 的命名）。
        local-llm-model 的 -Remove 靠「<tag>-ctx<數字>」這個形式認出衍生模型。 #>
    param([string] $Tag, [int] $Context)
    $suffix = if ($Context % 1024 -eq 0) { "$($Context / 1024)k" } else { "$Context" }
    return "$(ConvertTo-FullTag -Tag $Tag)-ctx$suffix"
}

function New-ContextModelfile {
    param([string] $Tag, [int] $Context)
    return "FROM $Tag`nPARAMETER num_ctx $Context`n"
}

function New-ContextDerivedModel {
    <#  OLLAMA_CONTEXT_LENGTH 是全域的，num_ctx 又傳不進 OpenAI 相容端點（已實測），
        要讓單一模型用不同上下文只剩 Modelfile 這條路（已實測會蓋過全域）。
        衍生模型共用權重 blob，不另佔磁碟。回傳衍生 tag；使用者取消回 $null。 #>
    param([string] $Tag, [int] $Context)

    $derived = Get-DerivedModelTag -Tag $Tag -Context $Context
    if (@(Get-InstalledModels | ForEach-Object Name) -contains $derived) {
        $existing = Get-ModelNumCtx -Info (Get-OllamaModelInfo -Tag $derived)
        if ($existing -eq $Context) { Write-Ok "衍生模型 $derived 已存在（num_ctx $existing）"; return $derived }
    }

    if (-not (Confirm-Step "要建立衍生模型 $derived（FROM $Tag，num_ctx $Context，不另佔磁碟）嗎？")) { return $null }

    $file = Join-Path ([System.IO.Path]::GetTempPath()) "Modelfile-$(Get-Random)"
    try {
        [System.IO.File]::WriteAllText($file, (New-ContextModelfile -Tag $Tag -Context $Context), (New-Object System.Text.UTF8Encoding($false)))
        & ollama create $derived -f $file
        if ($LASTEXITCODE -ne 0) { throw "ollama create $derived 失敗（exit $LASTEXITCODE）。" }
    } finally {
        Remove-Item -Path $file -ErrorAction SilentlyContinue
    }

    $actual = Get-ModelNumCtx -Info (Get-OllamaModelInfo -Tag $derived)
    if ($actual -eq $Context) { Write-Ok "已建立 $derived（num_ctx $actual）" }
    else { Write-Warn2 "已建立 $derived，但讀回來的 num_ctx 是 $actual，不是 $Context" }
    return $derived
}

function ConvertTo-LoadSummary {
    <# 仿 ollama ps 的 PROCESSOR 欄位：100% GPU、57%/43% CPU/GPU、100% CPU。 #>
    param([long] $SizeBytes, [long] $VramBytes)
    if ($SizeBytes -le 0) { return '未知' }
    $gpu = [int] [math]::Round($VramBytes * 100.0 / $SizeBytes)
    if ($gpu -ge 100) { return '100% GPU' }
    if ($gpu -le 0) { return '100% CPU' }
    return "$(100 - $gpu)%/$gpu% CPU/GPU"
}

function Get-LoadedModels {
    $ps = Invoke-OllamaApi -Path '/api/ps'
    return @(@(Get-JsonProp $ps 'models') | Where-Object { $_ } | ForEach-Object {
        $size = [long](Get-JsonProp $_ 'size')
        $vram = [long](Get-JsonProp $_ 'size_vram')
        [pscustomobject]@{
            Name      = [string](Get-JsonProp $_ 'name')
            SizeBytes = $size
            VramBytes = $vram
            Context   = Get-JsonProp $_ 'context_length'
            Processor = ConvertTo-LoadSummary -SizeBytes $size -VramBytes $vram
        }
    })
}

function Clear-OtherLoadedModels {
    <#  別的模型佔著顯存時，量到的 CPU/GPU 分配與速度都不準。
        PC-YI-SL 就踩過：31B 沒卸載，12B 被擠到部分 CPU。 #>
    param([string] $Tag)

    $others = @(Get-LoadedModels | Where-Object { $_.Name -ne $Tag })
    foreach ($o in $others) {
        if (Confirm-Step "$($o.Name) 正載入中（$($o.Processor)），會擠壓顯存讓結果失真。要先卸載嗎？") {
            $null = & ollama stop $o.Name 2>&1   # 收掉 CLI 的轉圈圈控制字元
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $deadline -and (@(Get-LoadedModels | ForEach-Object Name) -contains $o.Name)) {
                Start-Sleep -Milliseconds 500
            }
            Write-Ok "已卸載 $($o.Name)"
        } else {
            Write-Warn2 "保留 $($o.Name)，接下來的數字會偏低"
        }
    }
}

function ConvertTo-SpeedResult {
    <# /api/generate 的回應換算成 tok/s。duration 欄位的單位是奈秒。 #>
    param($Response)
    $evalCount   = [double](Get-JsonProp $Response 'eval_count')
    $evalNs      = [double](Get-JsonProp $Response 'eval_duration')
    $promptCount = [double](Get-JsonProp $Response 'prompt_eval_count')
    $promptNs    = [double](Get-JsonProp $Response 'prompt_eval_duration')
    $loadNs      = [double](Get-JsonProp $Response 'load_duration')

    $evalTps   = $null
    $promptTps = $null
    if ($evalNs -gt 0)   { $evalTps   = [math]::Round($evalCount / ($evalNs / 1e9), 1) }
    if ($promptNs -gt 0) { $promptTps = [math]::Round($promptCount / ($promptNs / 1e9), 1) }

    return [pscustomobject]@{
        EvalCount  = [int] $evalCount
        EvalTps    = $evalTps
        PromptTps  = $promptTps
        LoadSec    = [math]::Round($loadNs / 1e9, 1)
        DoneReason = [string](Get-JsonProp $Response 'done_reason')
    }
}

function Measure-ModelSpeed {
    <#  走原生 /api/generate、關掉 thinking、固定生成長度，量純生成速度（專案裡 31B 的 3.9 tok/s 就是這樣量的）。
        刻意不帶 options.num_ctx：要量的是 OpenCode 實際會拿到的上下文（全域值或 Modelfile 的 num_ctx），
        自己帶 num_ctx 會讓 Ollama 用另一組設定重新載入，量到的就不是真實情況。 #>
    param([string] $Tag, $Capabilities = $null, [int] $NumPredict = 300, [int] $TimeoutSec = 900)

    $body = @{
        model   = $Tag
        prompt  = '請用繁體中文寫一段約四百字的短文，介紹台灣夜市的飲食文化。'
        stream  = $false
        options = @{ num_predict = $NumPredict }
    }
    # 只對會 thinking 的模型帶 think，避免不支援的模型回錯誤
    if (@($Capabilities) -contains 'thinking') { $body['think'] = $false }

    $json = $body | ConvertTo-Json -Depth 5
    try {
        $resp = Invoke-RestMethod -Uri "$OllamaApi/api/generate" -Method Post -ContentType 'application/json; charset=utf-8' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec $TimeoutSec
    } catch {
        Write-Warn2 "量測請求失敗：$($_.Exception.Message)"
        return $null
    }
    return ConvertTo-SpeedResult -Response $resp
}

function Test-ModelChat {
    <# 走 OpenCode 會用的 /v1/chat/completions 送一則訊息。回傳是否拿到內容。 #>
    param([string] $Tag, [int] $TimeoutSec = 900)

    Write-Info '送出一則測試訊息 ...'
    # 會 thinking 的模型預設先吐一段 reasoning 才給 content。
    # max_tokens 給太小（例如 64）會在 reasoning 階段就用完，content 變成空字串、
    # finish_reason 是 length —— 看起來像成功其實沒答完，所以這裡給寬一點。
    # 逾時也放寬：權重掉到 CPU 的大模型光載入就要一兩分鐘，生成每秒只有幾個 token。
    $body = @{
        model      = $Tag
        messages   = @(@{ role = 'user'; content = '用一句繁體中文回答：你是誰？' })
        max_tokens = 512
    } | ConvertTo-Json -Depth 5

    try {
        $resp = Invoke-RestMethod -Uri "$OllamaApi/v1/chat/completions" -Method Post -ContentType 'application/json; charset=utf-8' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec $TimeoutSec
    } catch {
        Write-Warn2 "測試請求失敗：$($_.Exception.Message)"
        return $false
    }

    $choice  = @(Get-JsonProp $resp 'choices')[0]
    $message = Get-JsonProp $choice 'message'
    $content = "$(Get-JsonProp $message 'content')".Trim()
    $think   = "$(Get-JsonProp $message 'reasoning')".Trim()
    $finish  = Get-JsonProp $choice 'finish_reason'

    $ok = $false
    if ($content) {
        Write-Ok "模型回應：$content"
        if ($think) { Write-Info "（另有 $($think.Length) 字的 thinking 內容，已略過）" }
        $ok = $true
    }
    elseif ($finish -eq 'length') {
        $used = Get-JsonProp (Get-JsonProp $resp 'usage') 'completion_tokens'
        Write-Warn2 "回應被 max_tokens 截斷，content 是空的（thinking 用掉 $used tokens）。模型會動，但這則測試不算通過。"
    }
    else {
        Write-Warn2 "模型沒有回傳 content（finish_reason: $finish）。"
    }

    # ollama ps 的 CONTEXT 欄位是「這次真的載入」的上下文，最有說服力的驗證
    Write-Info '目前載入狀態（CONTEXT 欄位即實際生效的上下文）：'
    & ollama ps | ForEach-Object { Write-Host "     $_" -ForegroundColor Gray }
    return $ok
}

# ---------------------------------------------------------------- OpenCode 設定

function Read-OpenCodeConfig {
    <#
      讀一份 OpenCode 設定成 hashtable。檔案不存在、是空的、或內容壞掉都回空表，
      讓呼叫端不必各自 try/catch。PowerShell 7 的 ConvertFrom-Json 容得下 JSONC
      的註解與尾逗號，所以 .jsonc 也走這支。
    #>
    param([string] $Path)

    if (-not (Test-Path $Path)) { return @{} }
    try {
        $raw = Get-Content -Path $Path -Raw -Encoding UTF8
        if (-not $raw.Trim()) { return @{} }
        $parsed = $raw | ConvertFrom-Json -AsHashtable
        if ($parsed -is [hashtable]) { return $parsed }
        return @{}
    } catch {
        Write-Warn2 "$(Split-Path -Leaf $Path) 解析失敗，當成空設定處理：$($_.Exception.Message)"
        return @{}
    }
}

function Test-HasOllamaProvider {
    param([hashtable] $Config)
    return ($Config.ContainsKey('provider') -and
            $Config['provider'] -is [hashtable] -and
            $Config['provider'].ContainsKey('ollama'))
}

function Resolve-OpenCodeConfig {
    <#
      OpenCode 會把同目錄的 opencode.json 與 opencode.jsonc **兩份都讀進來合併**，
      但本腳本只維護其中一份。兩份並存時若沉默地只寫一份，另一份的舊模型定義會留在
      模型清單裡變成死項目（模型一刪就選了會失敗），而 -Check 也會因為只看一份而
      給出假陰性。所以動手前先盤點：哪幾份存在、哪幾份定義了 provider.ollama。

      回傳 @{ Target; Present; WithOllama; Explicit }
        Target     = 要寫入的那一份
        Present    = 實際存在的設定檔
        WithOllama = 其中已經定義 provider.ollama 的
        Explicit   = 使用者是否用 -ConfigPath 明確指定（指定了就完全照辦，不做推測）
    #>
    param([string] $Path, [bool] $Explicit = $false)

    $dir  = Split-Path -Parent $Path
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $json  = Join-Path $dir "$base.json"
    $jsonc = Join-Path $dir "$base.jsonc"

    # 同目錄的兩個檔名都要盤點，這樣連 -ConfigPath 指到別處時也看得到並存問題
    $present    = @(@($json, $jsonc) | Where-Object { Test-Path $_ } | Select-Object -Unique)
    $withOllama = @($present | Where-Object { Test-HasOllamaProvider (Read-OpenCodeConfig -Path $_) })

    # 明確指定 -ConfigPath 就寫那一份，不做推測（但上面的盤點與警告照樣進行）。
    # 沒指定時：只有 .jsonc 存在就寫 .jsonc（硬生一個 .json 只會讓並存問題更糟），
    # 其餘一律以 .json 為準 —— 它是預設檔名，而且寫回時註解本來就保不住。
    $target =
        if ($Explicit) { $Path }
        elseif ((Test-Path $jsonc) -and -not (Test-Path $json)) { $jsonc }
        else { $json }

    return @{ Target = $target; Present = $present; WithOllama = $withOllama; Explicit = $Explicit }
}

function Write-ConfigLayoutWarning {
    <# 把「兩份並存」這件事講清楚，並指出使用者需要手動處理什麼。 #>
    param($Resolved)

    if ($Resolved.Present.Count -le 1) { return }

    Write-Warn2 'OpenCode 同時讀 opencode.json 與 opencode.jsonc 並合併生效，這台兩份都存在：'
    foreach ($p in $Resolved.Present) {
        $mark = if ($Resolved.WithOllama -contains $p) { '（已定義 provider.ollama）' } else { '' }
        Write-Info "  - $(Split-Path -Leaf $p)$mark"
    }

    $strays = @($Resolved.WithOllama | Where-Object { $_ -ne $Resolved.Target })
    if ($strays) {
        Write-Warn2 "本腳本只會寫 $(Split-Path -Leaf $Resolved.Target)。上列另一份裡的 ollama 模型定義不會被清掉，"
        Write-Warn2 '會在 OpenCode 的模型清單留下重複或已失效的項目 — 請手動移除那一份的 provider.ollama。'
    }
}

function Backup-ConfigFile {
    param([string] $Path)
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = "$Path.bak-$stamp"
    $n = 1
    while (Test-Path $backup) { $backup = "$Path.bak-$stamp-$n"; $n++ }  # 同一秒重跑不覆蓋舊備份
    Copy-Item -Path $Path -Destination $backup
    Write-Info "已備份原設定到 $(Split-Path -Leaf $backup)"
    return $backup
}

function Save-ConfigFile {
    param([string] $Path, [hashtable] $Config)
    if ([System.IO.Path]::GetExtension($Path) -eq '.jsonc') {
        Write-Warn2 '寫入的是 .jsonc：設定會以 ConvertTo-Json 重新輸出，檔案裡的註解會全部消失。'
    }
    $json = $Config | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function New-OpenCodeModelEntry {
    <#  能力旗標照 Ollama /api/show 的 capabilities 設，不寫死。
        對不支援圖片的模型開 attachment、對不會 thinking 的模型開 reasoning，OpenCode 都會照送，
        出錯時看不出原因。讀不到能力（舊版 Ollama）時只開 tool_call —— agent 沒有它就不能用工具。 #>
    param([string] $Tag, [int] $Ctx, $Capabilities = $null)

    $entry = @{
        name  = "$Tag (local)"
        limit = @{ context = $Ctx; output = [math]::Min(16384, [int]($Ctx / 4)) }
    }
    if ($null -eq $Capabilities) {
        $entry['tool_call'] = $true
        return $entry
    }
    $caps = @($Capabilities)
    $entry['tool_call']  = ($caps -contains 'tools')
    $entry['reasoning']  = ($caps -contains 'thinking')
    $entry['attachment'] = ($caps -contains 'vision')
    return $entry
}

function Update-OpenCodeConfig {
    param([string] $Path, [string] $Tag, [int] $Ctx, $Capabilities = $null)

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $config = Read-OpenCodeConfig -Path $Path
    if (Test-Path $Path) { $null = Backup-ConfigFile -Path $Path }

    if (-not $config.ContainsKey('$schema'))   { $config['$schema'] = 'https://opencode.ai/config.json' }
    if (-not $config.ContainsKey('provider'))  { $config['provider'] = @{} }
    if (-not $config['provider'].ContainsKey('ollama')) { $config['provider']['ollama'] = @{} }

    $ollama = $config['provider']['ollama']
    $ollama['npm']     = '@ai-sdk/openai-compatible'
    $ollama['name']    = 'Ollama (local)'
    $ollama['options'] = @{ baseURL = "$OllamaApi/v1" }
    if (-not $ollama.ContainsKey('models')) { $ollama['models'] = @{} }

    $ollama['models'][$Tag] = New-OpenCodeModelEntry -Tag $Tag -Ctx $Ctx -Capabilities $Capabilities

    # 清掉舊寫法：contextLength 不在 OpenCode schema 裡，寫了也不會生效
    foreach ($m in @($ollama['models'].Keys)) {
        $entry = $ollama['models'][$m]
        if ($entry -is [hashtable] -and $entry.ContainsKey('contextLength')) {
            $entry.Remove('contextLength')
            Write-Info "已移除 $m 的無效欄位 contextLength"
        }
    }

    Save-ConfigFile -Path $Path -Config $config
    Write-Ok "已寫入 $Path"
    Write-Info "在 OpenCode 內用 /models 選 [Ollama (local)] 的 $Tag (local)，或設 model 為 ollama/$Tag"
}

function Remove-OpenCodeModels {
    <# 從一份設定移除指定模型；有動到才備份與寫回。回傳實際移除的 tag。 #>
    param([string] $Path, [string[]] $Tags)

    $config = Read-OpenCodeConfig -Path $Path
    if (-not (Test-HasOllamaProvider $config)) { return @() }
    $models = Get-JsonProp $config['provider']['ollama'] 'models'
    if ($models -isnot [hashtable]) { return @() }

    $removed = @($Tags | Where-Object { $models.ContainsKey($_) })
    if (-not $removed) { return @() }

    $null = Backup-ConfigFile -Path $Path
    foreach ($t in $removed) { $models.Remove($t) }
    Save-ConfigFile -Path $Path -Config $config
    return $removed
}

function Get-ConfigModelReferences {
    <#  設定裡把這些模型指定成預設的地方（model、small_model、agent.<名稱>.model）。
        模型刪掉後這些鍵還留著，OpenCode 一開就會選到不存在的模型。 #>
    param([hashtable] $Config, [string[]] $Tags)

    $refs = [System.Collections.Generic.List[string]]::new()
    $check = {
        param([string] $Key, $Value)
        if ($Value -is [string] -and $Value.StartsWith('ollama/') -and ($Tags -contains $Value.Substring(7))) {
            $refs.Add("$Key = $Value")
        }
    }
    foreach ($key in 'model', 'small_model') { & $check $key $Config[$key] }
    if ($Config['agent'] -is [hashtable]) {
        foreach ($name in $Config['agent'].Keys) {
            $agent = $Config['agent'][$name]
            if ($agent -is [hashtable]) { & $check "agent.$name.model" $agent['model'] }
        }
    }
    return @($refs)
}

function Get-ConfiguredModels {
    <# 盤點所有設定檔裡的 ollama 模型：tag -> 清單（File、Limit）。同一顆出現在兩份就有兩筆。 #>
    param($Resolved)

    $map = [ordered]@{}
    foreach ($p in $Resolved.Present) {
        $cfg = Read-OpenCodeConfig -Path $p
        if (-not (Test-HasOllamaProvider $cfg)) { continue }
        $models = Get-JsonProp $cfg['provider']['ollama'] 'models'
        if ($models -isnot [hashtable]) { continue }
        foreach ($m in $models.Keys) {
            $entry = $models[$m]
            $limit = $null
            if ($entry -is [hashtable] -and $entry['limit'] -is [hashtable]) { $limit = $entry['limit']['context'] }
            if (-not $map.Contains($m)) { $map[$m] = [System.Collections.Generic.List[object]]::new() }
            $map[$m].Add([pscustomobject]@{ File = $p; Limit = $limit })
        }
    }
    return $map
}

function Get-RemovalTargets {
    <#  -Remove 要處理的 tag：指定的那顆，加上用 Modelfile 從它衍生的 <tag>-ctx<數字>。
        Ollama 上有的、OpenCode 設定裡有的都算 —— 設定裡的死項目也要一起清。
        衍生的判斷要綁「-ctx 加數字」：刪 gemma4:12b 不能順手把 gemma4:12b-it-qat 也刪掉。 #>
    param([string] $Tag, [string[]] $Installed = @(), [string[]] $Configured = @())

    $full    = ConvertTo-FullTag -Tag $Tag
    $pattern = '^' + [regex]::Escape($full) + '-ctx\d+k?$'
    $all = @(@($Installed) + @($Configured) | Where-Object { $_ } | Select-Object -Unique)
    return @($all | Where-Object { $_ -eq $full -or $_ -match $pattern })
}

function Get-ContextStatus {
    <#  OpenCode 的 limit.context 對上 Ollama 實際會載入的上下文。
        over ：OpenCode 以為還有空間而繼續塞，Ollama 卻只載入較小的值，前文被悄悄截掉 —— 要報警。
        under：OpenCode 比較早開始壓縮對話，浪費一點空間但不會出錯。 #>
    param($Limit, $Effective)
    if (-not $Limit) { return 'missing' }
    if (-not $Effective) { return 'unknown' }
    if ([int] $Limit -gt [int] $Effective) { return 'over' }
    if ([int] $Limit -lt [int] $Effective) { return 'under' }
    return 'ok'
}

function Write-ModelInventory {
    <#  local-llm-setup 的 -Check 與 local-llm-model 的 -List 共用。
        逐一模型列出「OpenCode 以為的上下文」與「Ollama 實際會載入的上下文」。
        全域 OLLAMA_CONTEXT_LENGTH 與 Modelfile 的 num_ctx 並存之後，兩者對不上的機會變多了，
        而對不上時不會有任何錯誤訊息，只會在長對話裡悄悄丟掉前文。 #>
    param([string] $ConfigPath, [bool] $Explicit = $false)

    $resolved = Resolve-OpenCodeConfig -Path $ConfigPath -Explicit $Explicit
    if (-not $resolved.Present) {
        Write-Warn2 "找不到 OpenCode 設定（$ConfigPath）"
    } else {
        Write-ConfigLayoutWarning -Resolved $resolved
        if (-not $resolved.WithOllama) { Write-Warn2 'OpenCode 設定裡沒有 ollama provider' }
    }

    $configured = Get-ConfiguredModels -Resolved $resolved
    $up         = Test-OllamaUp
    $installed  = @()
    $global     = $null
    if ($up) {
        $installed = @(Get-InstalledModels)
        $global    = Get-GlobalContext
        if ($global) { Write-Info "全域上下文 $global（沒有用 Modelfile 釘住 num_ctx 的模型都吃這個）" }
    } else {
        Write-Warn2 'Ollama 服務沒在跑，只列設定檔內容，無法比對實際上下文'
    }

    $names = @(@($installed | ForEach-Object Name) + @($configured.Keys) | Where-Object { $_ } | Select-Object -Unique)
    if (-not $names) { Write-Warn2 '沒有任何模型'; return }

    foreach ($name in $names) {
        $inst    = $installed | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        $entries = if ($configured.Contains($name)) { @($configured[$name]) } else { @() }

        if ($up -and -not $inst) {
            foreach ($e in $entries) {
                Write-Warn2 "$name：在 $(Split-Path -Leaf $e.File) 裡但 Ollama 沒有這顆 — 選了會失敗，建議移除（local-llm-model 的 -Remove）"
            }
            continue
        }

        $size = if ($inst -and $inst.SizeBytes) { "（$(Format-GB $inst.SizeBytes)）" } else { '' }
        $numCtx = $null
        if ($inst) { $numCtx = Get-ModelNumCtx -Info (Get-OllamaModelInfo -Tag $name) }
        $effective = if ($numCtx) { $numCtx } else { $global }
        $effText =
            if ($numCtx)     { "實際上下文 $numCtx（Modelfile num_ctx）" }
            elseif ($global) { "實際上下文 $global（全域）" }
            else             { '實際上下文未知' }

        if (-not $entries) { Write-Info "$name$size：$effText，沒有接進 OpenCode"; continue }

        foreach ($e in $entries) {
            $leaf = Split-Path -Leaf $e.File
            switch (Get-ContextStatus -Limit $e.Limit -Effective $effective) {
                'missing' { Write-Warn2 "$name$size：$leaf 裡沒有有效的 limit.context（contextLength 不是合法欄位，不會生效）" }
                'over'    { Write-Warn2 "$name$size：$leaf 的 limit.context 是 $($e.Limit)，但$effText —— OpenCode 會以為還有空間，長對話的前文會被 Ollama 悄悄截掉" }
                'under'   { Write-Ok    "$name$size：$leaf 的 limit.context $($e.Limit)，$effText（OpenCode 會提早壓縮對話，不會出錯）" }
                'ok'      { Write-Ok    "$name$size：$leaf 的 limit.context $($e.Limit)，$effText" }
                default   { Write-Ok    "$name$size：$leaf 的 limit.context $($e.Limit)" }
            }
        }
    }
}
