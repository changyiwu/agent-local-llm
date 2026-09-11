---
name: local-llm-model
description: 在已經設定好 Ollama 的電腦上加入、試跑、量速度、移除單一模型，並同步 OpenCode 設定。當使用者說「試跑 XX 模型」「裝千問」「裝 Qwen」「加一顆模型到 OpenCode」「這顆模型跑得動嗎」「量一下速度」「模型掉到 CPU 了」「刪掉這個模型」「清掉用不到的模型」「列出本機模型」「本機有哪些模型」時，請一定要使用此技能。支援 Ollama registry 上任何模型（Qwen、Gemma、Llama…），下載前會先估權重塞不塞得進顯存，可用 Modelfile 給單一模型專屬上下文而不動全域設定。這台還沒裝過 Ollama 時先用 local-llm-setup。
---

# local-llm-model — 加入、試跑、移除單一模型

## 用途

在已經跑過 `local-llm-setup` 的電腦上，處理「會一直重複」的模型管理：

| 動作 | 做什麼 |
|------|--------|
| `-List`（預設） | 列出本機模型、每顆實際會載入的上下文、OpenCode 設定對不對得上 |
| `-Add <tag>` | 估顯存 → 下載 → （可選）建專屬上下文的衍生模型 → 寫進 OpenCode → 送訊息驗證 → 量速度 |
| `-Bench <tag>` | 量生成速度與 CPU/GPU 分配 |
| `-Remove <tag>` | 刪模型與它的衍生模型，並從所有 OpenCode 設定檔移除 |

主腳本：本技能資料夾的 `manage-model.ps1`。共用函式在專案的 `.opencode/lib/LocalLlm.ps1`，腳本會自己載入。

這是**專案層級**技能，只在 agent-local-llm 專案裡生效。不要用 `sync-skills` 同步到全域。

## 環境需求

- **PowerShell 7（`pwsh`）**，理由同 local-llm-setup
- Ollama 已安裝且服務在跑。沒有的話先用 `local-llm-setup`

## 執行流程

### 第一步：先看現況

```powershell
pwsh -NoProfile -File "<本技能資料夾>\manage-model.ps1"
```

把清單讀給使用者聽，特別是這幾種警告：
- 設定裡有但 Ollama 沒有的死項目
- `limit.context` 大於實際上下文的模型
- 還有別的大模型正載入中

### 加入一顆模型

```powershell
pwsh -NoProfile -File "<本技能資料夾>\manage-model.ps1" -Add qwen3.8:27b -Context 32768
```

腳本會先印「評估」段落，列出硬體、模型大小、權重塞不塞得進顯存。**下載前把這段讀給使用者聽**，特別是出現「一定有部分層跑在 CPU」時。確認後才讓腳本繼續，大模型動輒 18 GB 起跳。

**要不要加 `-Context`**：

- 不加：沿用全域 `OLLAMA_CONTEXT_LENGTH`（這台的主力模型用的那個值）。
- 加了：用 Modelfile 建一個 `<tag>-ctx<k>` 衍生模型，把 `num_ctx` 釘在這顆上，OpenCode 設定寫的是衍生模型。衍生模型共用權重，不另佔磁碟。
- **權重接近或超過顯存時一定要加**。全域值（16GB 卡是 131072）會套到每顆模型，KV cache 會再擠掉一些層。沒有特別理由就從 `32768` 開始。
- 同一顆模型想比較不同上下文，就用不同的 `-Context` 各加一次，會得到不同名字的衍生模型。

`-Add` 預設會量兩次速度。大模型掉到 CPU 時一次可能好幾分鐘，使用者只想先裝好時加 `-NoBench`。

### 量速度

```powershell
pwsh -NoProfile -File "<本技能資料夾>\manage-model.ps1" -Bench qwen3.8:27b-ctx32k
```

量法固定：原生 `/api/generate`、關閉 thinking、生成 300 tokens、不帶 `num_ctx`（量的是 OpenCode 實際會拿到的上下文）。本專案既有的數字都是這樣量的，可以直接比。

開始前若有別的模型載入中，腳本會問要不要先卸載。**建議卸載**，佔著顯存的模型會讓分配與速度都失真。

模型原本沒載入時，第一次量測會包含載入，數字偏低（16GB 卡上 `gemma4:12b` 冷載入那次 28.1 tok/s，之後 46–48）。腳本把那次標成「暖機」、不列入，另外補量一次，所以 `-Runs` 指的是有效次數。回報時用「第 N 次」與平均那幾行，不要用暖機的數字。

量完回報給使用者時整理成表：

| 模型 | 分配 | 上下文 | 生成速度 | 讀提示速度 |
|---|---|---|---|---|

在 agent-local-llm 專案裡量的數字，要記進 `agents.md` 的技術決策（附機器名與日期）。本專案已知的參照點：16GB 卡上 `gemma4:12b` 100% GPU 38.8 tok/s、`gemma4:26b-a4b-it-qat` 31%/69% CPU/GPU 49.8 tok/s、`gemma4:31b-it-qat` 57%/43% CPU/GPU 3.9 tok/s、`qwen3.8:27b-ctx32k` 39%/61% CPU/GPU 7.0 tok/s。

### 移除

```powershell
pwsh -NoProfile -File "<本技能資料夾>\manage-model.ps1" -Remove gemma4:31b-it-qat
```

腳本會先列出所有目標再問一次：
- 指定的模型
- 它的 `-ctx<n>` 衍生模型
- 只存在於設定檔的死項目

移除前會自動備份設定檔。若 `model`、`small_model` 或 `agent.<名稱>.model` 還指著被刪的模型，腳本會點名，要提醒使用者改掉。

只想刪衍生模型、保留原模型時，直接指定衍生模型的名字（例如 `-Remove qwen3.8:27b-ctx32k`）。

## 參數

| 參數 | 用途 |
|------|------|
| `-List` | 列清單（不給任何動作參數時的預設） |
| `-Add <tag>` | 加入模型 |
| `-Context <n>` | 只配 `-Add`：給這顆模型專屬上下文（建衍生模型，不動全域） |
| `-NoBench` | 只配 `-Add`：加入後不量速度 |
| `-Bench <tag>` | 量速度 |
| `-Runs <n>` | 配 `-Add` 或 `-Bench`：量測次數，預設 2 |
| `-Remove <tag>` | 移除模型與衍生模型 |
| `-ConfigPath <path>` | 改寫別的設定檔（預設 `~/.config/opencode/opencode.json`） |
| `-Yes` | 全程不詢問 |

**不要主動加 `-Yes`**，理由同 local-llm-setup。

## 判讀要點

**看激活參數，不是總參數。** MoE 的總參數決定知識廣度，激活參數決定推理深度與速度。`26b-a4b` 在 16GB 卡上 31% 掉到 CPU 還比 12B 快，因為每個 token 只算 4B；密集模型每個 token 都要穿過放在 CPU 的那些層，速度會掉一個數量級。

**下載大小不等於顯存佔用。** 評估段落的「塞不塞得進」只是粗估，實際以量測時的 CPU/GPU 分配為準。

**OpenCode 設定的能力旗標照 Ollama 回報的能力設定。** 模型不支援 `tools` 時，腳本會警告：在 OpenCode 裡只能聊天，agent 讀不了檔也改不了程式。這種模型不適合拿來跑 agent。

**Ollama 版本太舊時 `ollama pull` 會失敗。** 新架構的模型常要求新版 Ollama。升級後要用 `local-llm-setup` 跑一次 `-Check`。

## 常見狀況

| 症狀 | 處理 |
|------|------|
| `-Add` 說讀不到全域上下文 | 這台沒設 `OLLAMA_CONTEXT_LENGTH` 也讀不到 server log。加 `-Context`，或先用 local-llm-setup 設定 |
| 量到的分配不是 100% GPU | 權重或 KV cache 超出顯存。用更小的 `-Context` 重新 `-Add` 一次再量；還是不行就換小一階的量化或模型 |
| 速度比預期慢很多 | 先確認沒有別的模型佔著顯存（`-List` 會列出已載入的），筆電要接電源 |
| 在 OpenCode 裡選了模型卻報錯 | 跑 `-List` 看是不是死項目，或 `limit.context` 對不上 |
| 刪了模型但磁碟沒變大 | 還有衍生模型共用同一批權重。`-Remove` 原模型會一併處理 |

## 測試

```powershell
pwsh -NoProfile -File "<專案根目錄>\tests\test-local-llm-model.ps1"
```

改到共用函式庫時，`tests\test-local-llm-setup.ps1` 也要跑。
