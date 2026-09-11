# agent-local-llm

讓 OpenCode 呼叫本機大模型：透過 [Ollama](https://ollama.com)，在新電腦上一行指令設定到能用，之後隨時加入、試跑、量速度、刪除任何模型。

專案原名 `agent-gemma`。一開始只接 Google Gemma，2026-09 起不限模型家族（Qwen 等都能用），改名並拆成兩個技能。

## 兩個技能

| 技能 | 什麼時候用 | 腳本 |
|------|-----------|------|
| `local-llm-setup` | **一台電腦做一次**：偵測顯示卡、裝 Ollama、自動選一顆實測過的 Gemma、設全域上下文、揪出桌面 app 覆蓋設定、`-Check` 檢查現況 | `.opencode/skills/local-llm-setup/setup-local-llm.ps1` |
| `local-llm-model` | **一直重複做**：加入任何模型、給它專屬上下文、量速度與 CPU/GPU 分配、刪乾淨 | `.opencode/skills/local-llm-model/manage-model.ps1` |

兩支腳本共用 `.opencode/lib/LocalLlm.ps1`（設定檔讀寫、server log 解析、Ollama API）。

## 快速開始

### 新電腦

在本專案根目錄開 PowerShell 7（Windows 用 `pwsh`，macOS 先 `brew install --cask powershell`）：

```powershell
pwsh -NoProfile -File ./.opencode/skills/local-llm-setup/setup-local-llm.ps1 -Plan
```

先看它偵測到什麼、打算裝哪個版本。確認沒問題再跑正式設定：

```powershell
pwsh -NoProfile -File ./.opencode/skills/local-llm-setup/setup-local-llm.ps1
```

每個會改動系統的步驟（安裝 Ollama、下載模型、設定環境變數、建立 LaunchAgent、覆寫 `opencode.json`）都會先問一次。

跑完直接在 OpenCode 裡用 `/models` 選 **Ollama (local)** 底下的模型即可。上下文是由 Ollama 伺服器決定的，腳本已經重啟它並套用設定，不需要重開終端機。

### 試跑另一顆模型

```powershell
pwsh -NoProfile -File ./.opencode/skills/local-llm-model/manage-model.ps1 -Add qwen3.8:27b -Context 32768
```

它會：
1. 先估權重塞不塞得進顯存、磁碟夠不夠，再問要不要下載。
2. 用 Modelfile 建一個 `num_ctx 32768` 的衍生模型 `qwen3.8:27b-ctx32k`，不動全域上下文，也不另佔磁碟。
3. 寫進 OpenCode，能力旗標依模型實際支援的功能設定。
4. 送一則訊息驗證，最後量兩次生成速度與 CPU/GPU 分配。

```powershell
pwsh -NoProfile -File ./.opencode/skills/local-llm-model/manage-model.ps1                           # 列出模型與上下文比對
pwsh -NoProfile -File ./.opencode/skills/local-llm-model/manage-model.ps1 -Bench gemma4:12b         # 只量速度
pwsh -NoProfile -File ./.opencode/skills/local-llm-model/manage-model.ps1 -Remove qwen3.8:27b       # 連同衍生模型與設定一起刪
```

## 支援的平台

| 平台 | 加速方式 | 狀態 |
|------|---------|------|
| Windows + NVIDIA 獨顯 | CUDA | 已在 RTX 5060 Ti 16GB、RTX 5060 Laptop 8GB 實測 |
| Windows + AMD 獨顯 | ROCm | 支援，但 Ollama 只認部分 gfx 型號 |
| macOS + Apple Silicon | Metal（統一記憶體） | 已實作，**尚未在實機驗證** |
| macOS + Intel | 無 | 不支援，腳本會擋掉並說明原因 |

Intel Mac 沒有 Ollama 可用的 GPU 加速，純 CPU 跑 12B 不堪用，所以直接擋掉而不是讓你等半天才發現。

## local-llm-setup 做了什麼

| 步驟 | Windows | macOS（Apple Silicon） |
|------|---------|----------------------|
| 1. 偵測硬體 | NVIDIA 走 `nvidia-smi`；其餘讀登錄檔的 `qwMemorySize`。內顯會被排除 | `uname -m` 確認 arm64，`sysctl hw.memsize` 讀統一記憶體 |
| 2. 選版本 | 依可用 VRAM 對照選型表 | 依統一記憶體的可用比例對照同一張表 |
| 3. 安裝 Ollama | `winget install Ollama.Ollama`；沒有 winget 就用官方安裝檔 | `brew install --cask ollama` |
| 4. 下載模型 | `ollama pull`，已存在就跳過 | 同左 |
| 5. 設定上下文 | 設使用者環境變數 | `launchctl setenv` ＋ 寫 LaunchAgent 讓它活過重開機 |
| 6. 重啟 Ollama | 結束 `ollama`、`ollama app`、`llama-server` 後重開 `ollama app.exe` | `osascript` 結束 App 後 `open -a Ollama` |
| 7. 寫 OpenCode 設定 | 合併進 `~/.config/opencode/opencode.json`（先自動備份，保留既有的 mcp／permission 等設定） | 同左 |
| 8. 驗證 | 送一則訊息到 `/v1/chat/completions`，印出 `ollama ps`，並比對 server log 的實際注入值 | 同左 |

`Win32_VideoController.AdapterRAM` 是 32-bit 有號整數，超過 4GB 會失真，所以 Windows 這邊不用它。

## 選型表（local-llm-setup 自動選型）

| VRAM | 模型 | 下載大小 | 上下文 |
|------|------|---------|--------|
| 48 GB+ | `gemma4:31b-it-q8_0` | 34 GB | 131072 |
| 32 GB | `gemma4:31b-it-qat` | 19 GB | 65536 |
| 24 GB | `gemma4:26b-a4b-it-qat` | 16 GB | 32768 |
| 16 GB | `gemma4:12b` | 7.6 GB | 131072 |
| 10–12 GB | `gemma4:12b` | 7.6 GB | 32768 |
| 8 GB | `gemma4:e4b-it-qat` | 6.1 GB | 32768 |
| ≤ 6 GB | `gemma4:e2b-it-qat` | 4.3 GB | 16384 |

表上只有 Gemma，因為只有它在本專案實測過；沒實測的東西不讓腳本自動選中。其他模型用 `local-llm-model -Add` 手動加入。

沒有 Ollama 可用的獨立顯卡時，改依系統記憶體走 CPU 路徑（很慢，只建議拿來確認流程能通）。

`24 GB` 那階刻意選 MoE 的 `26b-a4b`：總參數 26B 但每次只啟用 4B，同樣顯存下比 31B 密集模型快得多。

**31B 是 Gemma 4 的天花板**，沒有更大的參數量。表上每個尺寸只收了 qat 與 q8_0 兩階，registry 上還有中間與更高的精度 —— 31B 是 qat 19 GB / q4_K_M 20 GB / mxfp8 33 GB / q8_0 34 GB / bf16 63 GB，26B MoE 是 16 / 18 / 28 / 28 / 52 GB。另有 coding 專用的 `gemma4:31b-coding-mtp-bf16`（64 GB）。

### Apple Silicon 怎麼換算

M 系列是統一記憶體，CPU 和 GPU 共用同一塊。Metal 能取用的上限由 `iogpu.wired_limit_mb` 決定，未調整時大約是總記憶體的 65～75%。腳本取保守值換算成「等效 VRAM」後，套用上面同一張表：

| 統一記憶體 | 取用比例 | 等效可用 | 選到的模型 | 上下文 |
|-----------|---------|---------|-----------|--------|
| 8 GB | 70% | 5.6 GB | `gemma4:e2b-it-qat` | 16384 |
| 16 GB | 70% | 11.2 GB | `gemma4:12b` | 32768 |
| 24 GB | 70% | 16.8 GB | `gemma4:12b` | 131072 |
| 32 GB | 70% | 22.4 GB | `gemma4:12b` | 131072 |
| 36 GB | 70% | 25.2 GB | `gemma4:26b-a4b-it-qat` | 32768 |
| 48 GB | 80% | 38.4 GB | `gemma4:31b-it-qat` | 65536 |
| 64 GB | 80% | 51.2 GB | `gemma4:31b-it-q8_0` | 131072 |

寧可低估也不要載到一半才發現爆掉。覺得太保守就用 `-Context` 或 `-Model` 自己指定。

> ⚠️ **Mac 路徑尚未實機驗證**，上表的比例是保守估計。另外 Ollama 在 Apple Silicon 是 GGUF／MLX **雙後端** —— GGUF 走 llama.cpp ＋ Metal，`-mlx` tag 才走 Apple 的 MLX 引擎，不會自動互轉。自動選型一律選 GGUF tag，所以走的是 Metal 那條路。MLX 版官方宣稱更快更省記憶體，但本專案沒有實測，也還沒確認 MLX 的「32 GB 以上統一記憶體」門檻在新版是否仍然存在。

**想跑 26B MoE 的話，自動選型的窗口只有 36–40 GB**：32 GB 差 0.6 GB 沒跨過門檻（實際上跑得動，權重才 16 GB），48 GB 以上則會跳到 31B 密集模型。這兩種情形都得手動指定：

```bash
pwsh -NoProfile -File ./.opencode/skills/local-llm-setup/setup-local-llm.ps1 -Model gemma4:26b-a4b-it-qat -Context 32768
```

要調整就改 `setup-local-llm.ps1` 裡的 `$GpuProfiles` / `$CpuProfiles`。

### 上下文吃多少 VRAM（實測）

`gemma4:12b` 在 RTX 5060 Ti 16GB 上，用 `nvidia-smi` 量到的模型佔用量：

| num_ctx | 佔用 VRAM | 放置 |
|---------|----------|------|
| 4,096 | 8,181 MiB | 100% GPU |
| 16,384 | 8,685 MiB | 100% GPU |
| 32,768 | 8,973 MiB | 100% GPU |
| 65,536 | 9,550 MiB | 100% GPU |
| 131,072 | 10,291 MiB | 100% GPU |
| 196,608 | 11,376 MiB | 100% GPU |
| 262,144 | 12,467 MiB | 100% GPU |

從 4K 拉到 131K，VRAM 只多吃 2.1 GB —— Gemma 用滑動視窗注意力（每 5 層局部、1 層全域），KV cache 幾乎不隨上下文線性成長，跟一般 Transformer 的直覺很不一樣。所以本專案的選型表在上下文上給得比多數教學大方。**其他家族的模型不一定這樣**，加入時用 `-Context` 從小的值開始。

選 131072 而不是上限 262144，是為了留約 3.7 GB 給桌面環境波動。VRAM 一旦不足，Ollama 會把部分層丟回 CPU，速度直接掉一個數量級。

## local-llm-model 的量測

`-Bench` 固定這樣量，本專案所有速度數字都能直接比：

- 原生 `/api/generate`
- 關閉 thinking
- 生成 300 tokens
- **不帶 `num_ctx`**：量的是 OpenCode 實際會拿到的上下文。自己帶 `num_ctx` 會讓 Ollama 用另一組設定重新載入。
- **丟掉冷載入那次**：包含載入模型的那次量測數字偏低，標成暖機、不列入，另外補量一次。

分配讀 `/api/ps` 的 `size_vram / size`，格式和 `ollama ps` 的 PROCESSOR 欄一樣。

16GB 卡（RTX 5060 Ti、61.7 GB 記憶體）上的參照點：

| 模型 | 分配 | 生成速度 |
|---|---|---|
| `gemma4:12b` | 100% GPU | 38.8 tok/s |
| `gemma4:26b-a4b-it-qat`（MoE，啟用 4B） | 31%/69% CPU/GPU | 49.8 tok/s |
| `gemma4:31b-it-qat`（密集，上下文 131072） | 57%/43% CPU/GPU | 3.9 tok/s |
| `qwen3.8:27b-ctx32k`（密集，上下文 32768） | 39%/61% CPU/GPU | 7.0 tok/s |

**看激活參數，不是總參數**：MoE 31% 掉到 CPU 還比 12B 快，因為每個 token 只算 4B；密集 31B 每個 token 都要穿過放在 CPU 的那 57%。權重超過顯存的密集模型，先有心理準備會慢一個數量級。

## 為什麼上下文要設兩次

這是本地模型跑 agent 最常見的坑，兩個地方缺一不可：

**Ollama 端 — `OLLAMA_CONTEXT_LENGTH`**

Ollama 0.30 之後預設值是「依 VRAM 動態決定」：未滿 23 GB 的機器一律只給 **4096**，23 GB 以上給 32768，47 GB 以上給 262144。所以一台 16 GB 顯卡的電腦如果沒設這個變數，實際跑起來就是 4K 上下文——OpenCode 那邊寫多大都沒用，工具呼叫會頻繁失敗、對話很快就斷。

> ⚠️ **設了環境變數也不保證生效。** Ollama 0.32 的**桌面 app** 把自己的 context length 設定（出廠預設 32768）存在 `db.sqlite`，啟動 server 時會拿它覆蓋環境變數，而且完全沒有提示 —— 重開機後又會再蓋一次。腳本會比對 server log 記的實際注入值並在不一致時報警。修法是把桌面 app 設定裡的 context length 也改成同一個值，或關掉桌面 app 改用 `ollama serve`。

Windows 設使用者環境變數即可。**macOS 麻煩一點**：要用 `launchctl setenv`，而且它活不過重開機 —— 所以腳本還會在 `~/Library/LaunchAgents/ai.ollama.env.plist` 寫一個登入時自動重設的 LaunchAgent，否則你某天重開機後上下文會悄悄掉回 4096 而毫無徵兆。要移除：

```bash
launchctl bootout gui/$(id -u)/ai.ollama.env && rm ~/Library/LaunchAgents/ai.ollama.env.plist
```

另外要注意 `OLLAMA_CONTEXT_LENGTH` 是**全域**的，Ollama 上每個模型都吃這個值；而 `opencode.json` 的 `limit.context` 是**逐一模型**的。在同一台 Ollama 上再拉一個明顯更大的模型時，全域值可能讓它配不下而掉層到 CPU。解法是用 Modelfile 給那顆模型專屬的上下文：

```
FROM qwen3.8:27b
PARAMETER num_ctx 32768
```

`local-llm-model -Add <tag> -Context <n>` 會自動做這件事。已實測：這樣建出來的衍生模型走 OpenAI 相容端點載入時，`ollama ps` 的 CONTEXT 確實會蓋過全域設定。衍生模型共用權重 blob，不額外佔磁碟。

**OpenCode 端 — `limit.context`**

```json
"models": {
  "gemma4:12b": {
    "name": "gemma4:12b (local)",
    "tool_call": true,
    "reasoning": true,
    "attachment": true,
    "limit": { "context": 131072, "output": 16384 }
  }
}
```

注意欄位名是 `limit.context`。網路上不少舊教學寫的 `contextLength` **不在 OpenCode 的 schema 裡**，會被靜默忽略。腳本會自動把既有設定裡的 `contextLength` 清掉。

`tool_call`／`reasoning`／`attachment` 依 Ollama `/api/show` 回報的 `tools`／`thinking`／`vision` 能力設定，不寫死。

`-Check` 與 `-List` 會逐顆比對 `limit.context` 和 Ollama 實際會載入的上下文。前者比較大時會報警：OpenCode 以為還有空間，長對話的前文會被 Ollama 悄悄截掉。

## 參數

### setup-local-llm.ps1

| 參數 | 用途 |
|------|------|
| `-Plan` | 只偵測與建議，不改動任何東西 |
| `-Check` | 只檢查現況（環境變數、實際注入值、每顆模型的上下文比對、死項目） |
| `-Model <tag>` | 指定主力模型，跳過自動選型 |
| `-Context <n>` | 指定**全域**上下文長度，跳過自動建議 |
| `-KvCache q8_0` | KV cache 量化，相同 VRAM 可塞下約兩倍上下文，品質損失很小 |
| `-ConfigPath <path>` | 改寫別的設定檔（預設 `~/.config/opencode/opencode.json`；同目錄的 `.jsonc` 也會被盤點並警告） |
| `-SkipInstall` | 已自行裝好 Ollama 時跳過安裝 |
| `-Yes` | 全程不詢問 |

### manage-model.ps1

| 參數 | 用途 |
|------|------|
| `-List` | 列出模型與上下文比對（不給動作參數時的預設） |
| `-Add <tag>` | 加入模型：估顯存、下載、寫設定、驗證、量速度 |
| `-Context <n>` | 配 `-Add`：用 Modelfile 給這顆模型專屬上下文 |
| `-NoBench` | 配 `-Add`：加入後不量速度 |
| `-Bench <tag>` | 量生成速度與 CPU/GPU 分配 |
| `-Runs <n>` | 配 `-Add`／`-Bench`：量測次數，預設 2 |
| `-Remove <tag>` | 刪模型、它的 `-ctx<n>` 衍生模型、所有設定檔裡的項目 |
| `-ConfigPath <path>` | 同上 |
| `-Yes` | 全程不詢問 |

## 疑難排解

| 症狀 | 處理 |
|------|------|
| 工具呼叫一直失敗、對話很快就斷 | 上下文太小。跑 `-Check` 看 `OLLAMA_CONTEXT_LENGTH` 與每顆模型的實際上下文 |
| `ollama ps` 的 PROCESSOR 顯示 CPU 或 CPU/GPU 混合 | 模型加上下文超出 VRAM。只有某顆大模型這樣的話，用 `manage-model.ps1 -Add <tag> -Context <較小值>`；整台都這樣就改小全域 `-Context` 或加 `-KvCache q8_0` |
| 重開機後上下文變回 4096（macOS） | LaunchAgent 沒建立或被移除。跑 `-Check` 會告訴你 |
| `-Check` 說「上下文對不上」 | Ollama 桌面 app 用自己的 GUI 設定蓋掉了環境變數。到 app 的 Settings 把 context length 改成同一個值，或改用 `ollama serve` |
| `-Check` 說 limit.context 大於實際上下文 | OpenCode 設定的比 Ollama 真正載入的大。重新 `-Add` 那顆模型，或手動改小 `limit.context` |
| `ollama pull` 失敗、說版本太舊 | 升級 Ollama，再跑一次 `-Check`（升級可能把桌面 app 的 context length 打回 32768） |
| 改了環境變數卻沒效果 | Ollama 服務要重啟（腳本會做）。若重啟了還是沒效果，看「上下文對不上」那列 |
| AMD 顯卡沒吃到 GPU | Ollama 的 ROCm 只支援部分 gfx 型號，不支援時會自動退回 CPU |
| 腳本一開就報語法錯誤 | 用到了 Windows PowerShell 5.1。必須用 `pwsh`（PowerShell 7） |
| Intel Mac 被擋下 | 沒有 Ollama 可用的 GPU 加速，不支援 |
| 想還原設定 | 腳本每次寫入前都會備份成 `opencode.json.bak-<時間戳>` |

## 環境需求

- Windows，或 Apple Silicon 的 macOS
- PowerShell 7 以上（Windows 用 `pwsh`；macOS 先 `brew install --cask powershell`）
- OpenCode
- Windows 需要 `winget`（沒有的話會改用官方安裝檔，並先詢問）；macOS 需要 Homebrew

## 開發

改過腳本後跑隔離測試——不連網、不安裝、不下載模型、不動環境變數、不碰真正的 `opencode.json`：

```powershell
pwsh -NoProfile -File ./tests/test-local-llm-setup.ps1
pwsh -NoProfile -File ./tests/test-local-llm-model.ps1
```

共 187 項（101 ＋ 86），兩支都在 StrictMode 下跑：

- **setup**：語法與編碼、兩條選型路徑（選型表直接從腳本 AST 抽出，不另抄一份）、顯卡篩選、LaunchAgent plist、設定合併與備份、`.json`／`.jsonc` 並存、server log 解析與不一致偵測
- **model**：參數組、tag 正規化與 registry 網址、衍生模型命名與 `num_ctx` 解析、能力旗標、速度與分配換算、顯存粗估、上下文比對、移除目標挑選（不誤刪同前綴模型）、設定移除與預設值殘留、API 欄位缺漏

改到 `.opencode/lib/LocalLlm.ps1` 時兩支都要跑。

## 資料夾結構

```text
agent-local-llm/
├── .opencode/
│   ├── lib/
│   │   └── LocalLlm.ps1              # 兩個技能共用的函式庫（dot-source）
│   └── skills/                       # OpenCode 專案技能（不裝到全域）
│       ├── local-llm-setup/
│       │   ├── SKILL.md
│       │   └── setup-local-llm.ps1   # 新電腦設定、-Plan、-Check
│       └── local-llm-model/
│           ├── SKILL.md
│           └── manage-model.ps1      # -List / -Add / -Bench / -Remove
├── tests/
│   ├── assert.ps1                    # 兩支測試共用的斷言
│   ├── test-local-llm-setup.ps1
│   └── test-local-llm-model.ps1
├── agents.md              # 跨 Agent 專案藍圖
├── handoff.md             # 跨工作階段交接（不進 repo）
├── CLAUDE.md              # Claude Code 橋接
├── README.md
├── LICENSE
├── .gitattributes
└── .gitignore
```

技能刻意放在 `.opencode/skills/` 這個**專案層級**路徑，只在這個專案裡生效，不安裝到 `~/.config/opencode/skills/`。它們只服務 OpenCode 接本機模型這一件事，沒有跨專案使用的理由，也不需要 `sync-skills` 同步到其他 Agent。

## 授權

MIT
