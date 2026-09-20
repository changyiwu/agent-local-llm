#requires -Version 7.0
<#
    local-llm-model（manage-model.ps1）與它用到的共用函式的隔離測試。

    不連網、不下載、不建立或刪除模型、不碰真正的 opencode.json。
    會打 Ollama 或 registry 的函式只測它們背後的純函式（URL 組裝、回應換算、比對規則）。

    執行：pwsh -NoProfile -File ./tests/test-local-llm-model.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'assert.ps1')

$SkillDir   = Join-Path $PSScriptRoot '../.opencode/skills/local-llm-model' | Convert-Path
$ScriptPath = Join-Path $SkillDir 'manage-model.ps1'
$LibPath    = Join-Path $PSScriptRoot '../.opencode/lib/LocalLlm.ps1' | Convert-Path

# ---- 語法、編碼、參數組 --------------------------------------------------

Write-Host "`n[1] 語法、編碼與參數組" -ForegroundColor Cyan

$null = Assert-ScriptFile -Path $ScriptPath
Assert-LibReference -ScriptPath $ScriptPath
Assert-True (Test-Path (Join-Path $SkillDir 'SKILL.md')) '技能資料夾有 SKILL.md'

# 只讀參數定義，不執行腳本
$cmd  = Get-Command -Name $ScriptPath
$sets = @($cmd.ParameterSets | ForEach-Object Name)
foreach ($s in 'Add', 'Bench', 'Remove', 'List') { Assert-True ($sets -contains $s) "有 $s 參數組" }
Assert-Equal 'List' (@($cmd.ParameterSets | Where-Object IsDefault)[0].Name) '不給參數時預設是列清單'

$ctxSets = @($cmd.Parameters['Context'].ParameterSets.Keys)
Assert-True ($ctxSets.Count -eq 1 -and $ctxSets[0] -eq 'Add') '-Context 只能跟 -Add 一起用'
$runSets = @($cmd.Parameters['Runs'].ParameterSets.Keys)
Assert-True ($runSets -contains 'Add' -and $runSets -contains 'Bench' -and $runSets -notcontains 'Remove') '-Runs 只給 -Add 與 -Bench'

. $LibPath
$Yes = $true

# ---- tag 與 registry ----------------------------------------------------

Write-Host "`n[2] tag 正規化與 registry 網址" -ForegroundColor Cyan

Assert-Equal 'qwen3.8:27b'    (ConvertTo-FullTag -Tag 'qwen3.8:27b') '有 tag 的名稱不變'
Assert-Equal 'qwen3.8:latest' (ConvertTo-FullTag -Tag 'qwen3.8')     '沒寫 tag 補 :latest（名稱裡的點不能被當成分隔）'
Assert-Equal 'user/model:latest' (ConvertTo-FullTag -Tag 'user/model') '命名空間裡的斜線不影響判斷'

$reg = 'https://registry.ollama.ai/v2'
Assert-Equal "$reg/library/qwen3.8/manifests/27b"     (ConvertTo-RegistryManifestUrl -Tag 'qwen3.8:27b') '官方模型走 library 命名空間'
Assert-Equal "$reg/library/gemma4/manifests/latest"   (ConvertTo-RegistryManifestUrl -Tag 'gemma4')      '沒寫 tag 查 latest'
Assert-Equal "$reg/someone/mymodel/manifests/q4"      (ConvertTo-RegistryManifestUrl -Tag 'someone/mymodel:q4') '使用者命名空間照原樣'
Assert-True ($null -eq (ConvertTo-RegistryManifestUrl -Tag 'hf.co/unsloth/Qwen3-GGUF:Q4_K_M')) 'hf.co 這類別家 registry 不查（回 $null）'
Assert-True ($null -eq (ConvertTo-RegistryManifestUrl -Tag ''))  '空字串回 $null'

Assert-Equal '17.7 GB' (Format-GB 17739000000) '大小用十進位 GB，和 ollama list 對得起來'

# ---- 衍生模型 -----------------------------------------------------------

Write-Host "`n[3] Modelfile 衍生模型" -ForegroundColor Cyan

Assert-Equal 'qwen3.8:27b-ctx32k'    (Get-DerivedModelTag -Tag 'qwen3.8:27b' -Context 32768)  '32768 命名成 ctx32k'
Assert-Equal 'gemma4:12b-ctx16k'     (Get-DerivedModelTag -Tag 'gemma4:12b' -Context 16384)   '和 PC-YI-FY 上既有的 gemma4:12b-ctx16k 同名'
Assert-Equal 'qwen3.8:27b-ctx128k'   (Get-DerivedModelTag -Tag 'qwen3.8:27b' -Context 131072) '131072 命名成 ctx128k'
Assert-Equal 'qwen3.8:latest-ctx32k' (Get-DerivedModelTag -Tag 'qwen3.8' -Context 32768)      '沒寫 tag 時先補 latest'
Assert-Equal 'qwen3.8:27b-ctx50000'  (Get-DerivedModelTag -Tag 'qwen3.8:27b' -Context 50000)  '不是 1024 倍數時直接寫數字'

$mf = New-ContextModelfile -Tag 'qwen3.8:27b' -Context 32768
Assert-True ($mf -match '(?m)^FROM qwen3\.8:27b$')          'Modelfile 的 FROM 指向原模型'
Assert-True ($mf -match '(?m)^PARAMETER num_ctx 32768$')    'Modelfile 釘住 num_ctx'

# /api/show 的 parameters 實際長相（NB-YI 上 gemma4:e4b-it-qat，沒有 num_ctx）
$plain = "temperature                    1`ntop_k                          64`ntop_p                          0.95"
Assert-True ($null -eq (Read-NumCtxFromParameters -Text $plain)) '沒釘 num_ctx 的模型回 $null（吃全域）'
$pinned = "num_ctx                        16384`r`ntemperature                    1"
Assert-Equal 16384 (Read-NumCtxFromParameters -Text $pinned)    '釘了 num_ctx 的模型讀得到值（含 CRLF）'
Assert-True ($null -eq (Read-NumCtxFromParameters -Text $null))  '沒有 parameters 欄位時回 $null'
Assert-True ($null -eq (Get-ModelNumCtx -Info ([pscustomobject]@{ license = 'x' }))) '回應裡沒有 parameters 欄位時不會丟例外'

# ---- 能力旗標 -----------------------------------------------------------

Write-Host "`n[4] OpenCode 能力旗標依 /api/show 決定" -ForegroundColor Cyan

$full = New-OpenCodeModelEntry -Tag 'qwen3.8:27b-ctx32k' -Ctx 32768 -Capabilities @('completion', 'vision', 'tools', 'thinking')
Assert-True ($full['tool_call'] -and $full['reasoning'] -and $full['attachment']) '全能力模型三個旗標都開'
Assert-Equal 'qwen3.8:27b-ctx32k (local)' $full['name'] '顯示名稱帶 (local)'
Assert-Equal 8192 $full['limit']['output'] 'output 為上下文的 1/4'

$chatOnly = New-OpenCodeModelEntry -Tag 'x:1b' -Ctx 8192 -Capabilities @('completion')
Assert-True ($chatOnly['tool_call'] -eq $false)  '不支援 tools 的模型不開 tool_call'
Assert-True ($chatOnly['reasoning'] -eq $false)  '不會 thinking 的模型不開 reasoning'
Assert-True ($chatOnly['attachment'] -eq $false) '不支援圖片的模型不開 attachment'

$unknown = New-OpenCodeModelEntry -Tag 'x:1b' -Ctx 8192 -Capabilities $null
Assert-True ($unknown['tool_call'] -eq $true)          '讀不到能力時仍開 tool_call'
Assert-True (-not $unknown.ContainsKey('reasoning'))   '讀不到能力時不猜 reasoning'

$caps = Get-ModelCapabilities -Info ([pscustomobject]@{ capabilities = @('completion') })
Assert-True ($caps -is [array] -and $caps.Count -eq 1)  '只有一個能力時仍回陣列'
Assert-True ($null -eq (Get-ModelCapabilities -Info ([pscustomobject]@{ license = 'x' }))) '舊版 Ollama 沒有 capabilities 欄位時回 $null'

# ---- 量測換算 -----------------------------------------------------------

Write-Host "`n[5] 量測結果換算" -ForegroundColor Cyan

Assert-Equal '100% GPU'         (ConvertTo-LoadSummary -SizeBytes 3115602410 -VramBytes 3115602410) '全部在顯存'
Assert-Equal '57%/43% CPU/GPU'  (ConvertTo-LoadSummary -SizeBytes 100 -VramBytes 43)                '部分掉到 CPU 時格式和 ollama ps 一樣'
Assert-Equal '100% CPU'         (ConvertTo-LoadSummary -SizeBytes 100 -VramBytes 0)                 '完全沒進顯存'
Assert-Equal '未知'             (ConvertTo-LoadSummary -SizeBytes 0 -VramBytes 0)                   '大小是 0 時不除以零'

# 31B 在 PC-YI-SL 量到的量級：300 tokens 約 77 秒
$resp = [pscustomobject]@{
    eval_count = 300; eval_duration = 76900000000
    prompt_eval_count = 30; prompt_eval_duration = 2000000000
    load_duration = 45300000000; done_reason = 'length'
}
$speed = ConvertTo-SpeedResult -Response $resp
Assert-Equal 3.9  $speed.EvalTps   '生成速度換算成 tok/s（奈秒）'
Assert-Equal 15   $speed.PromptTps '讀提示速度換算'
Assert-Equal 45.3 $speed.LoadSec   '載入時間換算成秒'
Assert-Equal 'length' $speed.DoneReason 'done_reason 照帶'

$empty = ConvertTo-SpeedResult -Response ([pscustomobject]@{ done = $true })
Assert-True ($null -eq $empty.EvalTps) '回應缺欄位時不丟例外、速度回 $null'

# 暖機判斷：PC-YI-FY 上 gemma4:12b 冷載入那次 28.1 tok/s（載入 37.8 秒），之後 45.7 與 47.9
Assert-True  (Test-ColdRun $speed)                                  '包含載入的那次算冷載入'
Assert-True  (-not (Test-ColdRun ([pscustomobject]@{ LoadSec = 0.1 }))) '模型已在顯存時不算冷載入'
Assert-True  (-not (Test-ColdRun ([pscustomobject]@{ LoadSec = 0 })))   '缺 load_duration 換算成 0 時不算冷載入'
Assert-True  (-not (Test-ColdRun $null))                            '量測失敗（$null）時不算冷載入'

$warm = @(
    [pscustomobject]@{ EvalTps = 45.7; LoadSec = 0 },
    [pscustomobject]@{ EvalTps = 47.9; LoadSec = 0 }
)
Assert-Equal 46.8 (Get-AverageEvalTps -Results $warm) '平均生成速度'
Assert-Equal 45.7 (Get-AverageEvalTps -Results @($warm[0], $empty, $null)) '缺速度的結果與 $null 不列入平均'
Assert-True ($null -eq (Get-AverageEvalTps -Results @())) '沒有結果時回 $null'

# 已載入模型的段落：沒有載入時明講「無」，不印只有表頭的空表
$none = @(Format-LoadedModelLines -Models @())
Assert-True ($none.Count -eq 1 -and $none[0] -eq '已載入的模型：無') '沒有載入中的模型時只印一行「無」'
Assert-Equal 1 @(Format-LoadedModelLines -Models $null).Count      '傳 $null 也當成沒有'

$lines = @(Format-LoadedModelLines -Models @(
    [pscustomobject]@{ Name = 'gemma4:12b'; Processor = '100% GPU'; Context = 131072 },
    [pscustomobject]@{ Name = 'gemma4:31b-it-qat'; Processor = '57%/43% CPU/GPU'; Context = $null }
))
Assert-Equal 3 $lines.Count '標題加每顆一行'
Assert-Equal '已載入的模型：' $lines[0] '有載入時先印標題'
Assert-True ($lines[1] -match 'gemma4:12b' -and $lines[1] -match '100% GPU' -and $lines[1] -match '上下文 131072') '一行裡有名稱、分配、上下文'
Assert-True ($lines[2] -match '上下文未知') '舊版 Ollama 沒有 context_length 時寫未知'

# ---- 顯存粗估 -----------------------------------------------------------

Write-Host "`n[6] 權重對顯存的粗估" -ForegroundColor Cyan

Assert-Equal 'offload' (Get-FitEstimate -WeightsGiB 16.5 -UsableGiB 15.9) 'qwen3.8:27b（16.5 GiB）上 16GB 卡會 offload'
Assert-Equal 'fits'    (Get-FitEstimate -WeightsGiB 7.0  -UsableGiB 15.9) 'gemma4:12b 上 16GB 卡塞得進'
Assert-Equal 'tight'   (Get-FitEstimate -WeightsGiB 14.0 -UsableGiB 15.9) '超過可用顯存 85% 算吃緊'
Assert-Equal 'cpu'     (Get-FitEstimate -WeightsGiB 7.0  -UsableGiB 0)    '沒有 GPU 時回 cpu'
Assert-Equal 'unknown' (Get-FitEstimate -WeightsGiB 0    -UsableGiB 15.9) '大小未知時不下結論'

# ---- 上下文比對 ---------------------------------------------------------

Write-Host "`n[7] limit.context 對上實際上下文" -ForegroundColor Cyan

Assert-Equal 'ok'      (Get-ContextStatus -Limit 131072 -Effective 131072) '相同時 ok'
Assert-Equal 'over'    (Get-ContextStatus -Limit 131072 -Effective 32768)  'OpenCode 以為的比實際大時要報警'
Assert-Equal 'under'   (Get-ContextStatus -Limit 32768  -Effective 131072) 'OpenCode 以為的比實際小不算錯'
Assert-Equal 'missing' (Get-ContextStatus -Limit $null  -Effective 32768)  '沒有 limit.context'
Assert-Equal 'unknown' (Get-ContextStatus -Limit 32768  -Effective $null)  '實際值不明時不下結論'

# ---- 移除目標 -----------------------------------------------------------

Write-Host "`n[8] -Remove 的目標挑選" -ForegroundColor Cyan

$installed  = @('gemma4:12b', 'gemma4:12b-ctx16k', 'gemma4:12b-it-qat', 'qwen3.8:27b', 'qwen3.8:27b-ctx32k')
$configured = @('gemma4:12b', 'gemma4:12b-ctx32k', 'qwen3.8:27b-ctx32k')

$t = @(Get-RemovalTargets -Tag 'gemma4:12b' -Installed $installed -Configured $configured)
Assert-True ($t -contains 'gemma4:12b')          '指定的模型本身'
Assert-True ($t -contains 'gemma4:12b-ctx16k')   '它的衍生模型'
Assert-True ($t -contains 'gemma4:12b-ctx32k')   '只在設定裡的衍生死項目也一起清'
Assert-True ($t -notcontains 'gemma4:12b-it-qat') '同前綴但不是衍生模型的不能誤刪'
Assert-Equal 3 $t.Count '剛好三個目標'

$t = @(Get-RemovalTargets -Tag 'qwen3.8:27b-ctx32k' -Installed $installed -Configured $configured)
Assert-True ($t.Count -eq 1 -and $t[0] -eq 'qwen3.8:27b-ctx32k') '只刪衍生模型時不動原模型'

$t = @(Get-RemovalTargets -Tag 'nope:1b' -Installed $installed -Configured $configured)
Assert-Equal 0 $t.Count '找不到時回空清單'

# ---- 設定檔移除 ---------------------------------------------------------

Write-Host "`n[9] 從 opencode.json 移除模型" -ForegroundColor Cyan

$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "local-llm-remove-$(Get-Random)"
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$cfgPath = Join-Path $tmpDir 'opencode.json'
$body = @'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "ollama/gemma4:31b-it-qat",
  "mcp": { "obsidian": { "type": "local", "enabled": true } },
  "agent": { "build": { "model": "ollama/gemma4:31b-it-qat-ctx32k" }, "plan": { "model": "ollama/gemma4:12b" } },
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "models": {
        "gemma4:12b": { "limit": { "context": 131072, "output": 16384 } },
        "gemma4:31b-it-qat": { "limit": { "context": 131072, "output": 16384 } },
        "gemma4:31b-it-qat-ctx32k": { "limit": { "context": 32768, "output": 8192 } }
      }
    }
  }
}
'@
[System.IO.File]::WriteAllText($cfgPath, $body, (New-Object System.Text.UTF8Encoding($false)))

$targets = @('gemma4:31b-it-qat', 'gemma4:31b-it-qat-ctx32k')
$removed = @(Remove-OpenCodeModels -Path $cfgPath -Tags $targets 6>$null)
Assert-Equal 2 $removed.Count '兩個目標都移除了'

$after = Read-OpenCodeConfig -Path $cfgPath
$models = $after['provider']['ollama']['models']
Assert-True ($models.ContainsKey('gemma4:12b'))             '沒被指定的模型留著'
Assert-True (-not $models.ContainsKey('gemma4:31b-it-qat')) '指定的模型不見了'
Assert-True ($after.ContainsKey('mcp'))                     '其他設定原封不動'
Assert-Equal 1 @(Get-ChildItem $tmpDir -Filter 'opencode.json.bak-*').Count '移除前有備份'

$refs = @(Get-ConfigModelReferences -Config $after -Tags $targets)
Assert-Equal 2 $refs.Count '找出還指著已刪模型的預設值'
Assert-True (($refs -join ' ') -match '^model = ollama/gemma4:31b-it-qat') '頂層 model 被點名'
Assert-True (($refs -join ' ') -match 'agent\.build\.model')              'agent 底下的 model 也被點名'
Assert-True (($refs -join ' ') -notmatch 'agent\.plan')                   '指著還在的模型的不點名'

$none = @(Remove-OpenCodeModels -Path $cfgPath -Tags @('nope:1b') 6>$null)
Assert-Equal 0 $none.Count '沒有可移除的就回空清單'
Assert-Equal 1 @(Get-ChildItem $tmpDir -Filter 'opencode.json.bak-*').Count '沒動到設定時不產生多餘備份'

# 盤點：同一顆模型在兩份設定都有時要各列一筆
$jsoncPath = Join-Path $tmpDir 'opencode.jsonc'
[System.IO.File]::WriteAllText($jsoncPath, '{ "provider": { "ollama": { "models": { "gemma4:12b": { "name": "old" } } } } }', (New-Object System.Text.UTF8Encoding($false)))
$inventory = Get-ConfiguredModels -Resolved (Resolve-OpenCodeConfig -Path $cfgPath)
Assert-Equal 2 @($inventory['gemma4:12b']).Count '兩份設定都有同一顆時列兩筆'
$jsoncEntry = @($inventory['gemma4:12b'] | Where-Object { $_.File -eq $jsoncPath })[0]
Assert-True ($null -eq $jsoncEntry.Limit) '沒有 limit.context 的那份記成 $null'

Remove-Item $tmpDir -Recurse -Force

# ---- API 回應欄位缺漏 ---------------------------------------------------

Write-Host "`n[10] 讀 API 回應不怕欄位缺漏" -ForegroundColor Cyan

Assert-True ($null -eq (Get-JsonProp $null 'x'))                                   '$null 物件回 $null'
Assert-True ($null -eq (Get-JsonProp ([pscustomobject]@{ a = 1 }) 'reasoning'))    '物件沒有該屬性時回 $null（StrictMode 下不丟例外）'
Assert-Equal 1 (Get-JsonProp ([pscustomobject]@{ a = 1 }) 'a')                     '物件有該屬性時回值'
Assert-Equal 2 (Get-JsonProp @{ b = 2 } 'b')                                       'hashtable 也能讀'
Assert-True ($null -eq (Get-JsonProp @{ b = 2 } 'c'))                              'hashtable 沒有該鍵時回 $null'

Complete-Test
