#requires -Version 7.0
<# 兩支測試共用的斷言小工具。dot-source 後用 Complete-Test 收尾並設定結束碼。 #>

$script:Pass = 0
$script:Fail = 0

function Assert-True {
    param([bool] $Condition, [string] $Name)
    if ($Condition) { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else            { $script:Fail++; Write-Host "  FAIL  $Name" -ForegroundColor Red }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Name)
    Assert-True ($Expected -eq $Actual) "$Name (預期 $Expected，實得 $Actual)"
}

function Assert-ScriptFile {
    <# 語法可解析、UTF-8 無 BOM。回傳 AST 讓呼叫端抽函式。 #>
    param([string] $Path)
    $leaf = Split-Path -Leaf $Path
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "$leaf 可正確解析"
    foreach ($e in @($parseErrors)) {
        Write-Host "        line $($e.Extent.StartLineNumber): $($e.Message)" -ForegroundColor Red
    }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Assert-True (-not $hasBom) "$leaf 是 UTF-8 無 BOM"
    return $ast
}

function Assert-LibReference {
    <# 腳本 dot-source 共用函式庫的相對路徑要真的指得到檔案，搬資料夾時最容易斷在這裡。 #>
    param([string] $ScriptPath)
    $text = Get-Content -Path $ScriptPath -Raw
    $m = [regex]::Match($text, "Join-Path \`$PSScriptRoot '([^']*LocalLlm\.ps1)'")
    Assert-True $m.Success "$(Split-Path -Leaf $ScriptPath) 有載入共用函式庫"
    if ($m.Success) {
        $resolved = Join-Path (Split-Path -Parent $ScriptPath) $m.Groups[1].Value
        Assert-True (Test-Path $resolved) "$(Split-Path -Leaf $ScriptPath) 指向的函式庫路徑存在"
    }
}

function Complete-Test {
    Write-Host ''
    if ($script:Fail -eq 0) {
        Write-Host "全部通過：$script:Pass 項" -ForegroundColor Green
        exit 0
    }
    Write-Host "通過 $script:Pass 項，失敗 $script:Fail 項" -ForegroundColor Red
    exit 1
}
