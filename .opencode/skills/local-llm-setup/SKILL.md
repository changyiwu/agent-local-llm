---
name: local-llm-setup
description: 在一台電腦上從零把 Ollama 裝好並接進 OpenCode（一台機器做一次），支援 Windows 與 Apple Silicon macOS。當使用者說「設定本地模型」「裝 Ollama」「新電腦要裝本地模型」「在 OpenCode 用本機模型」「接本機大模型」「Ollama 設定」「設定 Gemma」「本地模型上下文太小」「檢查本地模型設定」「Ollama 升級後檢查一下」時，請一定要使用此技能。會依顯示卡 VRAM（Mac 則依統一記憶體）自動選一顆實測過的 Gemma 當主力模型、設定 Ollama 全域上下文長度、揪出桌面 app 覆蓋設定的問題，並寫進 opencode.json。只想加入、試跑、量速度或刪除某一顆模型（例如試跑千問）時，改用 local-llm-model。
---

# local-llm-setup — 本機模型接進 OpenCode（新電腦設定）

## 用途

在一台新電腦上把「OpenCode 呼叫本機模型」從零設定到能用：

1. 偵測顯示卡與 VRAM
2. 依 VRAM 選出跑得動的主力模型（只選實測過的 Gemma）
3. 安裝 Ollama、下載模型
4. 設定 Ollama 端的**全域**上下文長度（這步最容易被漏掉）
5. 寫入 OpenCode 的 `opencode.json`
6. 實際送一則訊息驗證，並比對 server log 確認上下文真的生效

主腳本：本技能資料夾的 `setup-local-llm.ps1`。共用函式在專案的 `.opencode/lib/LocalLlm.ps1`，腳本會自己載入。

**跟 local-llm-model 的分工**：這支處理「一台電腦做一次」的事。已經設定好的電腦要加入、試跑、量速度或刪除某一顆模型，用 `local-llm-model`。它可以只給單一模型設上下文，不會動到這裡設的全域值。

這是**專案層級**技能（`.opencode/skills/`），只在 agent-local-llm 專案裡生效，刻意不安裝到全域。不要用 `sync-skills` 把它同步到其他 Agent 的技能目錄。

## 支援平台

| 平台 | 加速 | 備註 |
|------|------|------|
| Windows + NVIDIA | CUDA | 已在 RTX 5060 Ti 16GB、RTX 5060 Laptop 8GB 實測 |
| Windows + AMD 獨顯 | ROCm | Ollama 只認部分 gfx 型號 |
| macOS + Apple Silicon | Metal | 已實作，**尚未實機驗證** |
| macOS + Intel | 無 | 不支援，腳本會擋掉 |

在 Apple Silicon 上第一次跑時，要留意這幾件事並回報給使用者：偵測到的晶片與統一記憶體是否正確、LaunchAgent 有沒有建立成功、`ollama ps` 的 CONTEXT 是不是等於設定值。

## 環境需求

- **必須用 PowerShell 7（`pwsh`）執行**。腳本是 UTF-8 無 BOM，Windows PowerShell 5.1 會用系統 ANSI 解讀而在 parse 階段就失敗，而且 `ConvertFrom-Json -AsHashtable` 在 5.1 不存在。macOS 上先 `brew install --cask powershell`。
- Windows 需要 `winget`（沒有的話會改用官方安裝檔，並先詢問）；macOS 需要 Homebrew。

## 執行流程

### 第一步：一定先跑 `-Plan`

不做任何改動，只印出偵測到的硬體與建議方案。把結果讀給使用者聽，確認後才繼續。

```powershell
pwsh -NoProfile -File "<本技能資料夾>\setup-local-llm.ps1" -Plan
```

### 第二步：正式設定

```powershell
pwsh -NoProfile -File "<本技能資料夾>\setup-local-llm.ps1"
```

每個會改動系統的步驟都會問一次（安裝 Ollama、下載模型、設定環境變數、macOS 建立 LaunchAgent、覆寫 `opencode.json`）。
**不要主動加 `-Yes`**，除非使用者明確說「都不用問」，或執行環境無法回應互動提示（例如非互動式終端），此時要先向使用者說明將自動同意哪些步驟。

### 想檢查現況

```powershell
pwsh -NoProfile -File "<本技能資料夾>\setup-local-llm.ps1" -Check
```

會列出：
- ollama 版本、服務狀態、三個 `OLLAMA_*` 環境變數
- server log 記的實際注入值（和環境變數比對）
- **每一份**設定檔（`.json` 與 `.jsonc`）裡每顆模型的 `limit.context`，對上 Ollama 實際會載入的上下文（有 Modelfile `num_ctx` 的看 `num_ctx`，其餘看全域值）
- 設定裡有、但 Ollama 上沒有的死項目
- `ollama ps` 的實際載入狀態

**Ollama 升級後一定要跑一次**。大版本升級可能把桌面 app 的 context length 打回出廠的 32768，而且不會有任何提示。

## 參數

| 參數 | 用途 |
|------|------|
| `-Plan` | 只偵測與建議，不改動任何東西 |
| `-Check` | 只檢查現況 |
| `-Model <tag>` | 指定主力模型，跳過自動選型 |
| `-Context <n>` | 指定**全域**上下文長度，跳過自動建議 |
| `-KvCache q8_0` | KV cache 量化，相同 VRAM 可塞下約兩倍上下文 |
| `-ConfigPath <path>` | 改寫別的設定檔（預設 `~/.config/opencode/opencode.json`；同目錄的 `.jsonc` 也會被盤點並警告） |
| `-SkipInstall` | 已自行裝好 Ollama 時跳過安裝 |
| `-Yes` | 全程不詢問 |

`-Model` 搭 `-Context` 會把上下文設成**全域**，所有模型都吃。只是想多試一顆模型的話，不要用這組，改用 `local-llm-model` 的 `-Add`。

## 選型表（VRAM → 模型）

| VRAM | 模型 | 下載大小 | 上下文 |
|------|------|---------|--------|
| 48 GB+ | `gemma4:31b-it-q8_0` | 34 GB | 131072 |
| 32 GB | `gemma4:31b-it-qat` | 19 GB | 65536 |
| 24 GB | `gemma4:26b-a4b-it-qat` | 16 GB | 32768 |
| 16 GB | `gemma4:12b` | 7.6 GB | 131072 |
| 10–12 GB | `gemma4:12b` | 7.6 GB | 32768 |
| 8 GB | `gemma4:e4b-it-qat` | 6.1 GB | 32768 |
| ≤ 6 GB | `gemma4:e2b-it-qat` | 4.3 GB | 16384 |

表上只有 Gemma，因為只有它在本專案實測過。其他家族（Qwen 等）沒實測，不讓腳本自動選中。

Apple Silicon 是統一記憶體，腳本先換算成「等效 VRAM」（36GB 以下取 70%、以上取 80%）再套用同一張表。例如 16GB Mac → 11.2GB → `gemma4:12b` @ 32768；64GB Mac → 51.2GB → `gemma4:31b-it-q8_0` @ 131072。

想跑 26B MoE 的話，自動選型的窗口只有 **36–40GB**：32GB 差 0.6GB 沒跨過門檻（實際上跑得動），48GB 以上會跳到 31B 密集模型。兩種情形都要 `-Model gemma4:26b-a4b-it-qat` 手動指定。

沒有可用 GPU 時，改依系統記憶體走 CPU 路徑（很慢，只建議拿來確認流程能通）。
表格寫在 `setup-local-llm.ps1` 的 `$GpuProfiles` / `$CpuProfiles`，要調整就改那裡。

## 三個一定要講清楚的重點

**1. 上下文要在兩個地方各設一次，缺一不可。**

- **Ollama 端**：Windows 是使用者環境變數 `OLLAMA_CONTEXT_LENGTH`；macOS 是 `launchctl setenv` 加上一個 LaunchAgent（`launchctl` 的設定活不過重開機）。Ollama 0.30 之後預設值是「依 VRAM 動態決定」——未滿 23 GB 的機器一律只給 **4096**。不設這個，OpenCode 那邊寫多大都沒用，agent 的工具呼叫會頻繁失敗。
- **OpenCode 端**：`opencode.json` 裡的 `limit.context`。

兩者作用範圍相反：`OLLAMA_CONTEXT_LENGTH` 是全域（Ollama 上每個模型都吃），`limit.context` 是逐一模型。要逐一模型控制實際上下文，只能用 Modelfile 的 `PARAMETER num_ctx`（`num_ctx` 無法從 OpenAI 相容端點傳入，已實測）。`local-llm-model` 的 `-Add <tag> -Context <n>` 就是做這件事。

**而且設了環境變數還不一定生效。** Ollama 0.32 的桌面 app 會拿自己 GUI 設定裡的 context length（出廠預設 32768）覆蓋環境變數，沒有任何提示，重開機後再蓋一次。腳本會比對 server log 記的實際注入值，不一致時印出「上下文對不上」並給修法。**看到這個警告一定要處理**，否則設定看起來成功、實際跑的是別的值 —— 到 Ollama 桌面 app 的 Settings 把 context length 改成同一個值，或關掉桌面 app 改用 `ollama serve`。

**2. 設定檔可能有兩份，OpenCode 會合併讀取。**

`~/.config/opencode/` 底下的 `opencode.json` 與 `opencode.jsonc` **兩份都會被讀進來合併生效**。腳本會盤點兩份並在以下情況警告，看到就要處理：

- 兩份都定義了 `provider.ollama` → 腳本只寫其中一份，另一份的舊模型定義會留在模型清單裡。**要手動移除那一份的 `provider.ollama`**，否則使用者會看到重複或選了會失敗的項目。
- `-Check` 指出「在設定裡但 Ollama 沒有這顆」→ 那是刪過模型留下的死項目，用 `local-llm-model` 的 `-Remove` 清掉。

建議統一用 `opencode.json` 一份。腳本寫回時走 `ConvertTo-Json`，`.jsonc` 的註解一定會被清掉，留 `.jsonc` 沒有意義。

**3. `contextLength` 不是合法欄位。**

OpenCode 的 schema 只認 `limit: { context, output }`。網路上不少舊教學寫 `contextLength`，那個會被靜默忽略。腳本會自動把既有設定裡的 `contextLength` 清掉。

## 設定完成後

上下文由 Ollama 伺服器決定，腳本已重啟它並套用設定，不需要重開終端機。在 OpenCode 裡：

- `/models` 選 **Ollama (local)** 底下的項目
- 或在設定裡指定 `"model": "ollama/gemma4:12b"`

## 常見狀況

| 症狀 | 處理 |
|------|------|
| 工具呼叫一直失敗、對話很快就斷 | 上下文太小。跑 `-Check` 看 `OLLAMA_CONTEXT_LENGTH` 與每顆模型的實際上下文 |
| `ollama ps` 的 PROCESSOR 顯示 CPU | 模型加上下文超出 VRAM。改小 `-Context`，或用 `-KvCache q8_0`；只有某一顆大模型這樣的話，用 `local-llm-model` 給它專屬的小上下文 |
| 改了環境變數卻沒效果 | Ollama 服務要重啟（腳本會做） |
| 重開機後上下文掉回 4096（macOS） | LaunchAgent 沒建立或被移除，跑 `-Check` 會指出 |
| `-Check` 說「上下文對不上」 | Ollama 桌面 app 的 GUI 設定蓋掉了環境變數。到 app 的 Settings 改成同一個值，或改用 `ollama serve` |
| `-Check` 說某顆模型的 limit.context 大於實際上下文 | OpenCode 會以為還有空間，長對話前文被悄悄截掉。把 `limit.context` 改小，或用 `local-llm-model -Add` 重新加入 |
| AMD 顯卡沒吃到 GPU | Ollama 的 ROCm 只支援部分 gfx 型號，不支援時會自動退回 CPU |
| 回應速度可接受但品質不夠 | 往上一階換模型，或改用 `-it-q8_0` 版本 |
| 模型清單有已刪掉／重複的項目 | 設定分散在 `opencode.json` 與 `opencode.jsonc` 兩份。跑 `-Check`，依警告手動移除多餘那份的 `provider.ollama` |

## 測試

改過腳本或共用函式庫後跑一次隔離測試（不連網、不安裝、不碰真正的設定檔）：

```powershell
pwsh -NoProfile -File "<專案根目錄>\tests\test-local-llm-setup.ps1"
pwsh -NoProfile -File "<專案根目錄>\tests\test-local-llm-model.ps1"
```

共用函式庫兩個技能都在用，改了它就兩支都要跑。
