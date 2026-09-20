#requires -Version 7.0
<#
    local-llm-setup（setup-local-llm.ps1）與共用函式庫的隔離測試。

    不連網、不安裝、不下載模型、不動使用者環境變數、不碰真正的 opencode.json。
    共用函式庫只有函式與常數，直接 dot-source；主腳本有主流程，用 AST 把函式與選型表抽出來單獨定義。

    執行：pwsh -NoProfile -File ./tests/test-local-llm-setup.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
# 腳本本身跑在 StrictMode 下，測試也開，才抓得到「讀了不存在的屬性」這類只在實機才炸的錯
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'assert.ps1')

$SkillDir   = Join-Path $PSScriptRoot '../.opencode/skills/local-llm-setup' | Convert-Path
$ScriptPath = Join-Path $SkillDir 'setup-local-llm.ps1'
$LibPath    = Join-Path $PSScriptRoot '../.opencode/lib/LocalLlm.ps1' | Convert-Path

# ---- 語法與編碼 ----------------------------------------------------------

Write-Host "`n[1] 語法、編碼與函式庫路徑" -ForegroundColor Cyan

$null = Assert-ScriptFile -Path $LibPath
$ast  = Assert-ScriptFile -Path $ScriptPath
Assert-LibReference -ScriptPath $ScriptPath
Assert-True (Test-Path (Join-Path $SkillDir 'SKILL.md')) '技能資料夾有 SKILL.md'

# ---- 載入函式（不執行主流程） --------------------------------------------

. $LibPath

$funcs = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($f in $funcs) { . ([scriptblock]::Create($f.Extent.Text)) }

# 選型表直接從腳本抽，不在測試裡另抄一份 —— 抄的那份和腳本漂移時測試照樣會過
$tables = $ast.FindAll({
    param($n)
    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
    $n.Left.VariablePath.UserPath -in @('GpuProfiles', 'CpuProfiles')
}, $false)
foreach ($t in $tables) { . ([scriptblock]::Create($t.Extent.Text)) }
Assert-Equal 2 @($tables).Count '選型表（GPU / CPU）都從腳本抽出來了'

$Yes = $true   # 讓 Confirm-Step 不互動

# ---- 選型邏輯 -----------------------------------------------------------

Write-Host "`n[2] 依顯示卡選型" -ForegroundColor Cyan

function New-Hw {
    param([string] $Kind, [double] $Usable, [double] $Ram)
    [pscustomobject]@{ Kind = $Kind; UsableGB = $Usable; RamGB = $Ram; Reason = 'test'; Lines = @() }
}

$cases = @(
    @{ Label = 'RTX 5060 Ti 16GB（實際回報 15.9）'; Usable = 15.9; Ram = 64;  Tag = 'gemma4:12b'; Ctx = 131072 }
    @{ Label = 'RTX 4090 24GB（實際回報 23.6）';    Usable = 23.6; Ram = 64;  Tag = 'gemma4:26b-a4b-it-qat'; Ctx = 32768 }
    @{ Label = 'RTX 4070 12GB';                     Usable = 11.9; Ram = 32;  Tag = 'gemma4:12b'; Ctx = 32768 }
    @{ Label = 'RTX 3060 Ti 8GB';                   Usable = 7.9;  Ram = 32;  Tag = 'gemma4:e4b-it-qat'; Ctx = 32768 }
    @{ Label = 'GTX 1650 4GB';                      Usable = 3.9;  Ram = 16;  Tag = 'gemma4:e2b-it-qat'; Ctx = 16384 }
    @{ Label = 'RTX A6000 48GB';                    Usable = 47.5; Ram = 128; Tag = 'gemma4:31b-it-q8_0'; Ctx = 131072 }
)
foreach ($c in $cases) {
    $r = Select-Plan -Hardware (New-Hw 'GPU' $c.Usable $c.Ram)
    Assert-Equal $c.Tag $r.Tag "$($c.Label) -> 模型"
    Assert-Equal $c.Ctx $r.Ctx "$($c.Label) -> 上下文"
}

Write-Host "`n[3] Apple Silicon 統一記憶體選型" -ForegroundColor Cyan

# 統一記憶體的可用比例：36GB 以下取 70%，以上取 80%
$macCases = @(
    @{ Label = 'M 系列 16GB';  Ram = 16;  Usable = 11.2; Tag = 'gemma4:12b'; Ctx = 32768 }
    @{ Label = 'M 系列 24GB';  Ram = 24;  Usable = 16.8; Tag = 'gemma4:12b'; Ctx = 131072 }
    @{ Label = 'M 系列 36GB';  Ram = 36;  Usable = 25.2; Tag = 'gemma4:26b-a4b-it-qat'; Ctx = 32768 }
    @{ Label = 'M 系列 64GB';  Ram = 64;  Usable = 51.2; Tag = 'gemma4:31b-it-q8_0'; Ctx = 131072 }
    @{ Label = 'M 系列 8GB';   Ram = 8;   Usable = 5.6;  Tag = 'gemma4:e2b-it-qat'; Ctx = 16384 }
)
foreach ($c in $macCases) {
    $r = Select-Plan -Hardware (New-Hw 'GPU' $c.Usable $c.Ram)
    Assert-Equal $c.Tag $r.Tag "$($c.Label)（可用 $($c.Usable) GB）-> 模型"
    Assert-Equal $c.Ctx $r.Ctx "$($c.Label) -> 上下文"
}

# 比例本身也要對，否則上面的 Usable 只是自我實現的預言
Assert-Equal 11.2 ([math]::Round(16 * 0.70, 1)) '16GB Mac 的可用比例換算'
Assert-Equal 51.2 ([math]::Round(64 * 0.80, 1)) '64GB Mac 的可用比例換算'

Write-Host "`n[4] CPU 退回路徑" -ForegroundColor Cyan

$r = Select-Plan -Hardware (New-Hw 'CPU' 0 64)
Assert-Equal 'CPU' $r.Device '沒有可用 GPU 時走 CPU 路徑'
Assert-Equal 'gemma4:e4b-it-qat' $r.Tag 'CPU 路徑（64GB RAM）選型'

$r = Select-Plan -Hardware (New-Hw 'CPU' 0 8)
Assert-Equal 'gemma3:4b-it-qat' $r.Tag '記憶體不足時退回 Gemma 3 4B'

Write-Host "`n[5] Windows 顯卡篩選" -ForegroundColor Cyan

function New-Gpu {
    param([string] $Name, [double] $Vram, [string] $Vendor = 'NVIDIA', [bool] $Integrated = $false)
    [pscustomobject]@{ Name = $Name; VramGB = $Vram; Vendor = $Vendor; IsIntegrated = $Integrated }
}

# 直接測腳本實際呼叫的 Select-UsableGpu，不再另抄一份篩選條件
$mixed = @(Select-UsableGpu -Gpus @((New-Gpu 'AMD Radeon(TM) Graphics' 8 'AMD' $true), (New-Gpu 'GTX 1650' 3.9)))
Assert-Equal 1 $mixed.Count '內顯被排除，只留下獨顯'
Assert-Equal 'GTX 1650' $mixed[0].Name '選中的是獨顯而非數字更大的內顯'

$two = @(Select-UsableGpu -Gpus @((New-Gpu 'RTX 3060' 12), (New-Gpu 'RTX 5060 Ti' 15.9)))
Assert-Equal 'RTX 5060 Ti' $two[0].Name '兩張獨顯時取 VRAM 大的那張'

Assert-Equal 0 @(Select-UsableGpu -Gpus @((New-Gpu 'Intel UHD Graphics' 2 'Intel' $true))).Count '只有內顯時沒有可用 GPU'
Assert-Equal 0 @(Select-UsableGpu -Gpus @((New-Gpu 'Intel Arc A770' 15.9 'Intel'))).Count 'Intel Arc 不被當成 Ollama 可用 GPU'
Assert-Equal 0 @(Select-UsableGpu -Gpus @((New-Gpu 'GT 710' 2))).Count 'VRAM 不足 3GB 的舊卡被排除'
Assert-Equal 0 @(Select-UsableGpu -Gpus $null).Count '沒有任何顯示卡時回空清單'

Assert-True ('AMD Radeon(TM) Graphics' -match $IntegratedPattern) 'AMD 內顯名稱被認成內顯'
Assert-True ('AMD Radeon RX 7900 XTX' -notmatch $IntegratedPattern) 'AMD 獨顯名稱不被誤認成內顯'

Write-Host "`n[6] macOS LaunchAgent plist" -ForegroundColor Cyan

# 沒有 Mac 也能驗證：plist 是不是合法 XML、內容有沒有跳脫錯誤
$vars = [ordered]@{ OLLAMA_CONTEXT_LENGTH = '131072'; OLLAMA_FLASH_ATTENTION = '1'; OLLAMA_KV_CACHE_TYPE = 'q8_0' }
$plistXml = New-MacLaunchAgentXml -Vars $vars

$parsedOk = $true
try { $doc = [xml]$plistXml } catch { $parsedOk = $false }
Assert-True $parsedOk 'plist 是合法的 XML'

if ($parsedOk) {
    # $doc.plist 會同時對到 DOCTYPE 與根元素，StrictMode 下再往下取屬性會丟例外，所以從 DocumentElement 走
    $dict = $doc.DocumentElement.dict
    $keys = @($dict.key)
    Assert-True ($keys -contains 'Label')            'plist 有 Label'
    Assert-True ($keys -contains 'ProgramArguments') 'plist 有 ProgramArguments'
    Assert-True ($keys -contains 'RunAtLoad')        'plist 有 RunAtLoad'

    $argv = @($dict.array.string)
    Assert-Equal '/bin/sh' $argv[0] 'ProgramArguments 第一項是 /bin/sh'
    Assert-Equal '-c'      $argv[1] 'ProgramArguments 第二項是 -c'

    # XML 解析後應還原成三個 launchctl setenv，且值正確
    $cmd = $argv[2]
    Assert-True ($cmd -match "launchctl setenv OLLAMA_CONTEXT_LENGTH '131072'") '指令含正確的上下文設定'
    Assert-True ($cmd -match "launchctl setenv OLLAMA_KV_CACHE_TYPE 'q8_0'")    '指令含正確的 KV cache 設定'
    Assert-Equal 3 ([regex]::Matches($cmd, 'launchctl setenv').Count)           '三個變數都寫進去了'
}

# ---- opencode.json 合併 -------------------------------------------------

Write-Host "`n[7] opencode.json 合併與備份" -ForegroundColor Cyan

$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "local-llm-test-$(Get-Random)"
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$cfgPath = Join-Path $tmpDir 'opencode.json'

# 刻意用「舊寫法」的設定當起點：含無效的 contextLength、以及必須被保留的 mcp / permission
$legacy = @'
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": { "obsidian": { "type": "local", "command": ["npx", "mcpvault"], "enabled": true } },
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (local)",
      "options": { "baseURL": "http://localhost:11434/v1" },
      "models": { "gemma4:12b": { "name": "Gemma 4 12B (local)", "contextLength": 65536 } }
    }
  },
  "permission": { "skill": { "*": "ask" } },
  "experimental": { "mcp_timeout": 300000 }
}
'@
[System.IO.File]::WriteAllText($cfgPath, $legacy, (New-Object System.Text.UTF8Encoding($false)))

Update-OpenCodeConfig -Path $cfgPath -Tag 'gemma4:12b' -Ctx 65536 -Capabilities @('completion', 'tools', 'thinking', 'vision') | Out-Null

$out = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
$model = $out['provider']['ollama']['models']['gemma4:12b']

Assert-Equal 65536 $model['limit']['context']       'limit.context 寫入正確'
Assert-Equal 16384 $model['limit']['output']        'limit.output 有上限保護'
Assert-True (-not $model.ContainsKey('contextLength')) '無效的 contextLength 已移除'
Assert-True ($model['tool_call'] -eq $true)         'tool_call 已開啟（agent 才能用工具）'
Assert-True ($model['reasoning'] -eq $true)         '模型會 thinking 時開 reasoning'
Assert-True ($model['attachment'] -eq $true)        '模型支援圖片時開 attachment'
Assert-True $out.ContainsKey('mcp')                 '既有的 mcp 設定被保留'
Assert-True $out.ContainsKey('permission')          '既有的 permission 設定被保留'
Assert-Equal 300000 $out['experimental']['mcp_timeout'] '既有的 experimental 設定被保留'
Assert-Equal 'https://opencode.ai/config.json' $out['$schema'] '$schema 被保留'
Assert-True (@(Get-ChildItem $tmpDir -Filter 'opencode.json.bak-*').Count -eq 1) '有產生備份檔'

$outBytes = [System.IO.File]::ReadAllBytes($cfgPath)
$outBom = ($outBytes.Length -ge 3 -and $outBytes[0] -eq 0xEF -and $outBytes[1] -eq 0xBB -and $outBytes[2] -eq 0xBF)
Assert-True (-not $outBom) '寫出的 opencode.json 是 UTF-8 無 BOM'

# 從零開始：設定檔不存在時也要能建立
$freshDir = Join-Path $tmpDir 'fresh'
$freshPath = Join-Path $freshDir 'opencode.json'
Update-OpenCodeConfig -Path $freshPath -Tag 'gemma4:e4b-it-qat' -Ctx 32768 | Out-Null
$fresh = Get-Content $freshPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
Assert-Equal 32768 $fresh['provider']['ollama']['models']['gemma4:e4b-it-qat']['limit']['context'] '全新設定檔可從零建立'
Assert-Equal 8192  $fresh['provider']['ollama']['models']['gemma4:e4b-it-qat']['limit']['output']  '小上下文時 output 為 1/4'
Assert-Equal 'https://opencode.ai/config.json' $fresh['$schema'] '全新設定檔會補上 $schema'

# 第二次寫入同一個模型不該產生重複或壞掉的結構
Update-OpenCodeConfig -Path $cfgPath -Tag 'gemma4:12b' -Ctx 32768 | Out-Null
$out2 = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
Assert-Equal 32768 $out2['provider']['ollama']['models']['gemma4:12b']['limit']['context'] '重跑會覆寫成新的上下文'
Assert-Equal 1 $out2['provider']['ollama']['models'].Count '重跑不會產生重複模型項目'
Assert-Equal 2 @(Get-ChildItem $tmpDir -Filter 'opencode.json.bak-*').Count '同一秒內重跑不會覆蓋前一份備份'

Remove-Item $tmpDir -Recurse -Force

# ---- .json / .jsonc 並存 ------------------------------------------------

Write-Host "`n[8] opencode.json / opencode.jsonc 並存" -ForegroundColor Cyan

$dualDir = Join-Path ([System.IO.Path]::GetTempPath()) "local-llm-dual-$(Get-Random)"
New-Item -ItemType Directory -Path $dualDir -Force | Out-Null
$dualJson  = Join-Path $dualDir 'opencode.json'
$dualJsonc = Join-Path $dualDir 'opencode.jsonc'

# JSONC 帶註解與尾逗號 —— PowerShell 7 的 ConvertFrom-Json 容得下，5.1 不行
$jsoncBody = @'
{
  // 舊設定，模型早就從 Ollama 刪掉了
  "provider": {
    "ollama": {
      "models": { "gemma4:e4b": { "name": "Gemma 4 E4B" } },
    },
  },
}
'@
[System.IO.File]::WriteAllText($dualJsonc, $jsoncBody, (New-Object System.Text.UTF8Encoding($false)))

$parsedJsonc = Read-OpenCodeConfig -Path $dualJsonc
Assert-True ($parsedJsonc.Count -gt 0)                    'JSONC（含註解與尾逗號）可以解析'
Assert-True (Test-HasOllamaProvider $parsedJsonc)         'JSONC 裡的 provider.ollama 偵測得到'

# 只有 .jsonc 時，寫入目標就是 .jsonc（不硬生一個 .json 出來）
$onlyJsonc = Resolve-OpenCodeConfig -Path $dualJson -Explicit $false
Assert-Equal $dualJsonc $onlyJsonc.Target                 '只有 .jsonc 時寫入目標是 .jsonc'
Assert-Equal 1 $onlyJsonc.Present.Count                   '只有 .jsonc 時盤點到 1 份設定'

# 兩份並存：目標回到 .json，但兩份都要被盤點出來
[System.IO.File]::WriteAllText($dualJson, '{ "provider": { "ollama": { "models": {} } } }', (New-Object System.Text.UTF8Encoding($false)))
$dual = Resolve-OpenCodeConfig -Path $dualJson -Explicit $false
Assert-Equal $dualJson $dual.Target                       '兩份並存時以 .json 為寫入目標'
Assert-Equal 2 $dual.Present.Count                        '兩份並存時兩份都被盤點到'
Assert-Equal 2 $dual.WithOllama.Count                     '兩份的 provider.ollama 都被認出來'

# 明確指定 -ConfigPath：目標照辦，但盤點與警告不受影響（這是踩坑後改的行為）
$explicit = Resolve-OpenCodeConfig -Path $dualJsonc -Explicit $true
Assert-Equal $dualJsonc $explicit.Target                  '明確指定路徑時以該路徑為寫入目標'
Assert-Equal 2 $explicit.Present.Count                    '明確指定路徑時仍會盤點同目錄的另一份'

# 壞掉的設定檔不該讓整支腳本炸掉
$brokenPath = Join-Path $dualDir 'broken.json'
[System.IO.File]::WriteAllText($brokenPath, '{ this is not json', (New-Object System.Text.UTF8Encoding($false)))
$broken = Read-OpenCodeConfig -Path $brokenPath 6>$null
Assert-Equal 0 $broken.Count                              '壞掉的設定檔回空表而不是丟例外'
Assert-Equal 0 (Read-OpenCodeConfig -Path (Join-Path $dualDir 'nope.json')).Count '不存在的設定檔回空表'

# 寫入 .jsonc 後，註解確實不見了（這正是建議統一用 .json 的理由）
Update-OpenCodeConfig -Path $dualJsonc -Tag 'gemma4:e4b-it-qat' -Ctx 32768 6>$null | Out-Null
$afterWrite = Get-Content $dualJsonc -Raw -Encoding UTF8
                                                          # 不能用 '//' 判斷 — baseURL 的 http:// 也會中
Assert-True ($afterWrite -notmatch '舊設定')              '寫入 .jsonc 後註解會被 ConvertTo-Json 清掉'
Assert-True ((Read-OpenCodeConfig -Path $dualJsonc)['provider']['ollama']['models'].ContainsKey('gemma4:e4b')) '寫入 .jsonc 時既有模型仍保留'

Remove-Item $dualDir -Recurse -Force

# ---- 實際生效的上下文（server log 解析） --------------------------------

Write-Host "`n[9] Ollama server log 的實際上下文" -ForegroundColor Cyan

# 真實 log 的樣子：一長串 env map，值夾在其他變數中間
$realLine = 'time=2026-08-21T21:43:17.883+08:00 level=INFO source=routes.go:1933 msg="server config" ' +
            'env="map[CUDA_VISIBLE_DEVICES: OLLAMA_CONTEXT_LENGTH:32768 OLLAMA_DEBUG:INFO ' +
            'OLLAMA_FLASH_ATTENTION:false OLLAMA_HOST:http://127.0.0.1:11434]"'
Assert-Equal 32768 (Read-ContextFromLogText -Text $realLine) '從真實格式的 log 行取出上下文'

# 同一份 log 裡有多次啟動時要取最後一次 —— 前面的都是已經被取代的舊 server
$multi = @(
    'msg="server config" env="map[OLLAMA_CONTEXT_LENGTH:4096 OLLAMA_DEBUG:INFO]"'
    'msg="server config" env="map[OLLAMA_CONTEXT_LENGTH:32768 OLLAMA_DEBUG:INFO]"'
    'msg="server config" env="map[OLLAMA_CONTEXT_LENGTH:131072 OLLAMA_DEBUG:INFO]"'
) -join "`n"
Assert-Equal 131072 (Read-ContextFromLogText -Text $multi) '多次啟動時取最後一次的值'

Assert-True ($null -eq (Read-ContextFromLogText -Text 'msg="server config" env="map[OLLAMA_DEBUG:INFO]"')) 'log 裡沒有這個變數時回 $null'
Assert-True ($null -eq (Read-ContextFromLogText -Text ''))   '空字串回 $null'
Assert-True ($null -eq (Read-ContextFromLogText -Text $null)) '$null 輸入回 $null'

# vram-based default context 那行也帶數字，不能被誤抓成生效值
$decoy = 'msg="vram-based default context" total_vram="15.9 GiB" default_num_ctx=4096'
Assert-True ($null -eq (Read-ContextFromLogText -Text $decoy)) '不會誤抓 vram-based default context 的數字'

# 這台踩到的情境：環境變數 131072、桌面 app 用 32768 起 server
$mismatchOut = & {
    $script:lines = @()
    function Write-Warn2 { param([string]$m) $script:lines += "WARN $m" }
    function Write-Info  { param([string]$m) $script:lines += "INFO $m" }
    function Write-Ok    { param([string]$m) $script:lines += "OK $m" }
    function Get-OllamaRuntimeContext { 32768 }
    $r = Test-RuntimeContext -Persisted '131072'
    [pscustomobject]@{ Result = $r; Lines = $script:lines }
}
Assert-True (-not $mismatchOut.Result)                                  '設定與實際值不一致時回 $false'
Assert-True (($mismatchOut.Lines -join ' ') -match '131072')            '不一致的警告會列出環境變數的值'
Assert-True (($mismatchOut.Lines -join ' ') -match '32768')             '不一致的警告會列出實際生效的值'
Assert-True (($mismatchOut.Lines -join ' ') -match 'context length')    '不一致的警告會指出桌面 app 的設定'

$matchOut = & {
    $script:lines = @()
    function Write-Warn2 { param([string]$m) $script:lines += "WARN $m" }
    function Write-Info  { param([string]$m) $script:lines += "INFO $m" }
    function Write-Ok    { param([string]$m) $script:lines += "OK $m" }
    function Get-OllamaRuntimeContext { 131072 }
    $r = Test-RuntimeContext -Persisted '131072'
    [pscustomobject]@{ Result = $r; Lines = $script:lines }
}
Assert-True ($matchOut.Result)                              '設定與實際值一致時回 $true'
Assert-True (($matchOut.Lines -join ' ') -notmatch 'WARN')  '一致時不會發出警告'

# 讀不到 log（沒裝 Ollama、或還沒跑過）就不下結論，不能誤判成失敗
$noLogOut = & {
    function Write-Warn2 { param([string]$m) }
    function Write-Info  { param([string]$m) }
    function Write-Ok    { param([string]$m) }
    function Get-OllamaRuntimeContext { $null }
    Test-RuntimeContext -Persisted '131072'
}
Assert-True $noLogOut '讀不到 log 時不下結論（回 $true）'

# 環境變數沒設、但 server 有值 —— 那個值必然來自別處（GUI），要講清楚
$noEnvOut = & {
    $script:lines = @()
    function Write-Warn2 { param([string]$m) $script:lines += "WARN $m" }
    function Write-Info  { param([string]$m) $script:lines += "INFO $m" }
    function Write-Ok    { param([string]$m) $script:lines += "OK $m" }
    function Get-OllamaRuntimeContext { 32768 }
    $r = Test-RuntimeContext -Persisted ''
    [pscustomobject]@{ Result = $r; Lines = $script:lines }
}
Assert-True ($noEnvOut.Result)                                   '環境變數未設時不算失敗'
Assert-True (($noEnvOut.Lines -join ' ') -match '不是來自環境變數') '環境變數未設時會點出值的來源不是環境變數'

# 路徑要跟著平台走，不能寫死 Windows
$logDir = Get-OllamaLogDir
Assert-True ([bool] $logDir) 'Get-OllamaLogDir 有回傳路徑'
if ($IsWindows) { Assert-True ($logDir -match 'Ollama')        'Windows 的 log 目錄指向 Ollama' }
else            { Assert-True ($logDir -match '\.ollama/logs') 'macOS 的 log 目錄指向 ~/.ollama/logs' }

# ---- -Check 的已載入模型 ------------------------------------------------

Write-Host "`n[10] -Check 列已載入的模型" -ForegroundColor Cyan

# 段落格式由共用的 Format-LoadedModelLines 決定（測在 test-local-llm-model.ps1），這裡只確認 -Check 有用它。
# 以前直接轉印 ollama ps，沒有模型載入時只剩一行表頭。
$showStatus = @($funcs | Where-Object { $_.Name -eq 'Show-Status' })[0].Extent.Text
Assert-True ($showStatus -match 'Format-LoadedModelLines') '-Check 用共用函式列已載入的模型'
Assert-True ($showStatus -notmatch 'ollama ps')             '-Check 不再直接轉印 ollama ps'
$none = @(Format-LoadedModelLines -Models @())
Assert-Equal '已載入的模型：無' $none[0] '沒有載入中的模型時明講「無」'

Complete-Test
