# agent-local-llm（專案藍圖）

> 本檔為跨 Agent 通用的專案藍圖（AGENTS.md 開放標準）。任何 Agent 的每個 session 都應先讀本檔＋`handoff.md`。
> Claude Code 預設只在沒有 `CLAUDE.md` 時才讀 `AGENTS.md`，故由 `CLAUDE.md` 的 `@AGENTS.md` import 本檔；Claude 專屬規範寫在 `CLAUDE.md`。

## 專案簡介

讓 OpenCode 能呼叫本機大模型（透過 Ollama）。產出是兩個 OpenCode 專案技能，加上一個共用的 PowerShell 7 函式庫：

- **`local-llm-setup`**：一台電腦做一次。偵測顯示卡 → 依 VRAM 選出跑得動的 Gemma 版本 → 安裝 Ollama → 下載模型 → 設定全域上下文長度 → 寫入 `opencode.json` → 實際送訊息驗證 → 比對 server log 確認上下文真的生效。`-Check` 檢查現況。
- **`local-llm-model`**：一直重複做。加入 Ollama registry 上任何模型、用 Modelfile 給它專屬上下文、量速度與 CPU/GPU 分配、刪乾淨。

專案原名 `agent-gemma`，只接 Gemma。2026-09-11 為了試跑 `qwen3.8:27b` 改名並拆技能，見下方「為什麼拆成兩個技能」。

## 同步層級

| 層級 | 位置 | 用途 |
|------|------|------|
| L1 本地 | `我的雲端硬碟/agents/agent-local-llm`（GDrive 同步） | `AGENTS.md` 藍圖＋`handoff.md` 交接＋`CLAUDE.md` 橋接 |
| L2 GitHub | [changyiwu/agent-local-llm](https://github.com/changyiwu/agent-local-llm)（**公開**；舊網址 `agent-gemma` 由 GitHub 自動轉址） | 版本控制與雲端備份（`handoff.md` 不進 repo） |
| L3 Obsidian | vault 內 `agent-local-llm/專案工作流程.md` | 詳細脈絡、決策紀錄、踩坑筆記、更動紀錄 |

## 關鍵時程

目前沒有固定時程。

## 目標與路線圖

- [x] 階段一：確認 Ollama 的 Gemma 4 實際 tag 與大小、OpenCode provider schema、Ollama 上下文預設行為
- [x] 階段二：完成 `setup-gemma.ps1`（硬體偵測、選型表、安裝、拉模型、環境變數、設定合併、煙霧測試）
- [x] 階段三：完成隔離測試 `tests/test-setup-gemma.ps1`（不連網不改系統）
- [x] 階段四：完成 `SKILL.md` 與 README
- [x] 階段五：在 Windows 實機跑完整流程並驗證兩個 VRAM 階層（16GB→131072、8GB→32768，皆 100% GPU）
- [x] 階段六：加入 Apple Silicon macOS 支援；測試擴充到 59 項
- [x] 階段七：專案初始化三層級（L1 本地、L2 公開 GitHub、L3 Obsidian）
- [ ] 階段八：在實體 Mac 上驗證 macOS 路徑（目前只有邏輯與 plist 格式測試，沒有實機跑過）。範圍在 2026-08-21 擴大：除了 LaunchAgent 與等效 VRAM 比例，還要驗 **MLX 後端**（Ollama 在 Apple Silicon 是 GGUF／MLX 雙後端，選型表只走了 GGUF 那條）與 macOS 版桌面 app 是否也有 GUI 覆蓋上下文的行為
- [~] 階段九：驗證 24GB 以上那幾階的選型。**已在 16GB 卡上用 CPU offload 實測 MoE 與 31B 密集**：`gemma4:26b-a4b-it-qat` 更快但沒有更會自我檢查（見下方「MoE 實測」）；`gemma4:31b-it-qat` 57% 掉到 CPU、只剩 3.9 tok/s，能力也沒有明顯勝過 12B（見「31B 密集模型實測」）。**尚缺**：24GB 卡全 GPU 的表現、Apple Silicon 路徑（併入階段八）
- [x] 階段十：讓腳本處理 `opencode.jsonc`（盤點 `.json`／`.jsonc` 並存、`-Check` 兩份都讀並揪出死項目、寫入前警告重複的 provider 定義）；測試 59 → 72 項
- [x] 階段十一：揪出 Ollama 桌面 app 的 GUI 設定覆蓋 `OLLAMA_CONTEXT_LENGTH`（腳本比對 server log 的實際注入值，不一致就報警並給修法）；測試 72 → 89 項
- [x] 階段十二：專案改名 `agent-local-llm`，技能依任務拆成 `local-llm-setup`／`local-llm-model`，共用函式抽成 `.opencode/lib/LocalLlm.ps1`；新增 `-Add`／`-Bench`／`-Remove`／`-List`，`-Check` 改成逐顆比對 `limit.context` 與實際上下文；測試 89 → 187 項並全開 StrictMode；在 `NB-YI` 用真的 Ollama 跑過 `-Add`（含衍生模型）→ `-List` → `-Remove` 全流程
- [~] 階段十三：試跑 `qwen3.8:27b`，和 12B、31B 用同一個沙盒比速度與 agent 表現。這是第一次用 Gemma 以外的密集 27B 驗證「密集 30B 級能不能自我稽核」。**已在 `PC-YI-FY` 用 `-Add qwen3.8:27b -Context 32768` 完成下載、設定與量速度**（39%/61% CPU/GPU、7.0 tok/s，見「`qwen3.8:27b` 實測速度」）；**尚缺**：timeout 沙盒的 agent 表現比較

技能刻意**不**同步到全域技能目錄，見下方「技術決策」。

## 資料夾結構

```text
agent-local-llm/
├── .opencode/
│   ├── lib/
│   │   └── LocalLlm.ps1              # 兩個技能共用的函式庫（dot-source，不是模組）
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
├── AGENTS.md              # 跨 Agent 專案藍圖
├── handoff.md             # 跨工作階段交接（本機檔，git 不追蹤，靠 GDrive 同步）
├── CLAUDE.md              # Claude Code 橋接
├── README.md
├── LICENSE
├── .gitattributes         # 固定文字檔為 LF，避免跨電腦 hash 漂移
└── .gitignore
```

## 技術決策與理由

**為什麼拆成兩個技能（2026-09-11）**
原本的 `gemma-setup` 混了兩件頻率完全不同的事：「一台電腦做一次」的環境設定（裝 Ollama、全域上下文、GUI 覆蓋、`-Check`），和「會一直重複」的模型管理（拉新模型、給它專屬上下文、試跑、刪掉）。後者之前沒有工具：刪 31B 要手動 `ollama rm` 再手改 `opencode.json`，試跑大模型要手寫 Modelfile。要試 `qwen3.8:27b` 時這個缺口就藏不住了。

依任務拆，不依模型家族拆。拆成 gemma／qwen 兩個技能的話，安裝、設定合併、log 比對全要複製一份，而兩家模型在這些步驟上沒有任何差異。

**共用函式庫用 dot-source 的 `.ps1`，不用 `.psm1` 模組**
模組有自己的作用域，裡面的函式讀不到呼叫端腳本的 `$Yes`、`$SkipInstall` 這類參數。改成模組的話，`Confirm-Step` 等函式都得多傳參數，行為也可能跟著變。`LocalLlm.ps1` 只定義常數與函式、不執行任何流程，所以測試能直接 dot-source；主腳本有主流程，測試仍用 AST 抽函式。

函式庫放在 `.opencode/lib/`，不放在任一技能資料夾裡。兩個技能地位對等，放進其中一個會讓另一個看起來依賴它。代價是技能資料夾不能單獨複製出去用，腳本找不到函式庫時會直接說明這件事。

**自動選型仍然只選 Gemma**
改名後 `local-llm-setup` 的 `$GpuProfiles` 還是全 Gemma。只有它在本專案實測過，沒實測的東西不讓腳本自動選中（跟 MLX tag 不進 `$MacProfiles` 同一條原則）。其他家族用 `local-llm-model -Add` 手動加入；哪天某一家實測夠多，再考慮進選型表。

**OpenCode 的能力旗標改成讀 `/api/show` 的 `capabilities`**
以前寫死 `tool_call`／`reasoning`／`attachment` 全開，對 Gemma 4 剛好正確。換成別家模型就不一定：對不支援圖片的模型開 `attachment`、對不會 thinking 的模型開 `reasoning`，OpenCode 都會照送，出錯時看不出原因。現在依 `tools`／`thinking`／`vision` 設定；讀不到（舊版 Ollama）時只開 `tool_call`。Ollama 0.34 上 `gemma4:e4b-it-qat` 回報的是 `completion, vision, audio, tools, thinking`。

模型不支援 `tools` 時 `-Add` 會警告。那種模型在 OpenCode 裡只能聊天，不能跑 agent。

**衍生模型的命名 `<tag>-ctx<k>` 是 `-Remove` 的依據**
`-Add qwen3.8:27b -Context 32768` 建出 `qwen3.8:27b-ctx32k`，沿用 `PC-YI-FY` 上既有的 `gemma4:12b-ctx16k`。`-Remove` 靠 `^<tag>-ctx\d+k?$` 找出衍生模型一起刪（衍生模型共用權重 blob，只刪原模型不會釋出空間）。正則必須綁「`-ctx` 加數字」：刪 `gemma4:12b` 不能順手把 `gemma4:12b-it-qat` 也刪掉，測試裡刻意放了這個誘餌。

有沒有釘住上下文，看 `/api/show` 的 `parameters` 裡有沒有 `num_ctx` 那一行（純文字、以空白對齊；沒設參數的模型連 `parameters` 欄位都沒有）。`-Check` 與 `-List` 用它判斷每顆模型實際會載入多少上下文：有 `num_ctx` 看它，沒有就看全域值。

**`limit.context` 大於實際上下文要報警，反過來不用**
全域值與 Modelfile 並存後，兩邊對不上的機會變多了。`limit.context` 比實際大時，OpenCode 以為還有空間而繼續塞，Ollama 卻只載入較小的值，前文會被悄悄截掉，而且沒有任何錯誤訊息。比實際小只是 OpenCode 提早壓縮對話，浪費一點空間但不會出錯。

**`-Bench` 的量法**
走原生 `/api/generate`、`think=false`、`num_predict=300`，這就是前面 31B 那組 3.9 tok/s 的量法，新數字可以直接跟舊的比。**刻意不帶 `options.num_ctx`**：要量的是 OpenCode 實際會拿到的上下文，自己帶會讓 Ollama 用另一組設定重新載入。`think` 只對回報 `thinking` 能力的模型帶。

分配讀 `/api/ps` 的 `size_vram / size`，算法和 `ollama ps` 的 PROCESSOR 欄一樣。`/api/ps` 在 0.34 有 `context_length` 欄位，舊版不一定有，所以一律用 `Get-JsonProp` 讀。量測前有別的模型載入中就先問要不要卸載，這是 `PC-YI-SL` 上 31B 把 12B 擠到 CPU 的教訓。

**冷載入那次不列入（2026-09-12 加入）。** 回應的 `load_duration` 滿 1 秒就算冷載入，標成暖機、另外補量一次，`-Runs` 因此是有效次數。只丟一次：模型每次都重新載入時（例如 keep-alive 太短）照樣列入並註明，不會無限重量。起因是 `PC-YI-FY` 上 `gemma4:12b` 冷載入那次只有 28.1 tok/s（載入 37.8 秒、讀提示 1.5 tok/s），之後是 45.7 與 47.9。**桌機也會這樣**，不只是 `NB-YI` 那種筆電省電狀態。同一批權重的 `gemma4:12b-ctx16k` 緊接著量，只花 3.4 秒載入，第一次就是 45.8，看起來拖慢的主要是從磁碟讀權重，但沒有驗證。代價是那種情況也會多量一次。

**下載前查 registry 的大小與磁碟空間**
`-Add` 會先抓 `https://registry.ollama.ai/v2/<namespace>/<name>/manifests/<tag>`（`Accept: application/vnd.docker.distribution.manifest.v2+json`），加總 layers 與 config 的 `size`，就是 `ollama pull` 要下載的量。`qwen3.8:27b` 是 16.52 GiB（網頁寫 18GB，十進位），`gemma4:12b` 是 7.04 GiB，和選型表的 7.6 GB 對得上。`hf.co/...` 這類別家 registry 不查。

有了大小就能在下載前預告「權重大於可用顯存，一定會 offload」，並比對模型存放處的剩餘空間。這只是粗估，因為下載大小不等於顯存佔用（見下方 e4b 那條），實際分配以 `-Bench` 量到的為準。

**腳本全面開 StrictMode，讀 API 回應一律走 `Get-JsonProp`**
舊的 `Test-Setup` 直接讀 `$choice.message.reasoning`。Gemma 4 會 thinking 所以一直沒出事，換成不會 thinking 的模型，StrictMode 下讀不存在的屬性會直接丟例外。Ollama 各版本、各模型的回應欄位本來就不一致，所以抽成 `Get-JsonProp`，測試也改成在 StrictMode 下跑，才抓得到這類只在實機才炸的錯。

**為什麼上下文要在兩個地方各設一次**
Ollama 0.30 之後，`OLLAMA_CONTEXT_LENGTH` 未設定時是「依 VRAM 動態決定」：未滿 23 GB 只給 4096，23 GB 以上 32768，47 GB 以上 262144。OpenCode 端的 `limit.context` 只影響 OpenCode 自己怎麼切對話，不會改變 Ollama 實際載入的上下文。兩邊都要設。

**Ollama 桌面 app 的 GUI 設定會覆蓋 `OLLAMA_CONTEXT_LENGTH`（0.32 實測）**
桌面 app 把自己的設定存在 `db.sqlite` 的 `settings.context_length`（Windows 在 `%LOCALAPPDATA%\Ollama\`），**出廠預設 32768**。它啟動 server 時會把這個值當環境變數注入，蓋掉使用者環境變數，而且沒有任何提示。

在 `PC-YI-FY` 上的鐵證：使用者環境變數設成 131072，server log 卻是

```
msg="server config" env="map[... OLLAMA_CONTEXT_LENGTH:32768 ...]"
msg="vram-based default context" total_vram="15.9 GiB" default_num_ctx=4096
```

Ollama 自己依 VRAM 算的是 4096，實際用 32768 —— 那個 32768 只可能來自 GUI。同一台改用 `ollama serve` 直接啟動，注入的就是 131072。

這也解掉了 `NB-YI` 那個「`OLLAMA_CONTEXT_LENGTH` 進場前就已是 32768、來源不明」的謎：**那不是誰設的，是桌面 app 的出廠預設**。

影響很惡劣：腳本每一步都回報成功、`opencode.json` 也寫對了，實際載入的卻是另一個值，而且重開機後又會被蓋一次。所以腳本現在會比對「持久化的環境變數」與「server log 記的實際注入值」，不一致就報警並給修法（見下方 `Test-RuntimeContext`）。

修法有二：把桌面 app 設定裡的 context length 也改成同一個值（一勞永逸），或關掉桌面 app 改用 `ollama serve`。本專案兩台 Windows 機器都採前者。

**判斷「實際生效值」要看 server log，不是環境變數**
`Get-PersistentEnv` 讀到的是「我們希望的值」，`ollama ps` 的 CONTEXT 要模型載入後才有。唯一隨時可查、且反映真實情況的是 server log 每次啟動寫的那行 `server config`。腳本用 `Read-ContextFromLogText` 解析它（抽成吃字串的純函式，才能在沒有 Ollama 的機器上測），由 `Test-RuntimeContext` 做比對。

log 位置：Windows `%LOCALAPPDATA%\Ollama\server*.log`、macOS `~/.ollama/logs/server*.log`。`server.log` 是當前的，`server-1.log` 以後是輪替過的舊檔，所以要由新到舊找第一個讀得到值的檔，並取檔內**最後一次**匹配。同一行還有 `default_num_ctx=4096` 這種誘餌數字，正則必須綁 `OLLAMA_CONTEXT_LENGTH:` 前綴。

**`contextLength` 是無效欄位**
OpenCode 的 `provider.<id>.models.<tag>` schema 只認 `limit: { context, output }`（`required: [context, output]`）。`contextLength` 不在 schema 裡，寫了會被靜默忽略。腳本會主動移除既有設定裡的這個欄位。

**VRAM 怎麼讀**
`Win32_VideoController.AdapterRAM` 是 32-bit 有號整數，超過 4GB 會失真，不能用。NVIDIA 走 `nvidia-smi --query-gpu=memory.total`；其餘讀登錄檔 `HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-...}\<n>\HardwareInformation.qwMemorySize`。

**選型表的閾值刻意壓低**
標稱 16GB 的卡實際回報約 15.9 GB，24GB 約 23.6 GB。所以 `MinVram` 用 15 / 23 / 31 / 46，不用整數標稱值。

**16GB 那階的 131072 是實測值，不是估的**
在 RTX 5060 Ti 16GB 上用 `nvidia-smi` 量 `gemma4:12b`：4096 佔 8181 MiB、65536 佔 9550 MiB、131072 佔 10291 MiB、262144 佔 12467 MiB，全程 100% GPU。Gemma 的滑動視窗注意力讓 KV cache 幾乎不隨上下文線性成長，從 4K 到 131K 只多 2.1 GB。取 131072 而非上限，是留約 3.7 GB 給桌面環境波動。8GB 那階也已實測（見下），其餘階層還沒實測，數字偏保守。

**8GB 那階的 32768 也是實測值**
在 RTX 5060 **Laptop** GPU 8GB 上跑 `gemma4:e4b-it-qat`：`ollama ps` 顯示 CONTEXT 32768、100% GPU，載入只佔 3.1 GB，留約 4.9 GB 餘裕。這台同時有 AMD Radeon 610M 內顯（0.5 GB），顯卡篩選規則正確挑到 NVIDIA 那張，沒被內顯干擾。餘裕看起來還能往上調上下文，但沒實測過更高值，維持 32768。

（當時記的「`OLLAMA_CONTEXT_LENGTH` 進場前就已是 32768、來源不明」已經查明是桌面 app 的 GUI 預設值，見上面那一段。這台之所以矇混過關，是因為腳本判定「已是目標值」就沒改也沒重啟 —— 剛好等於 8GB 這階的建議值。）

2026-09-11 在 `NB-YI` 用改名後的腳本跑 `-Check`（Ollama 0.34.0）：環境變數、server log 實際注入值、`opencode.json` 三處都是 32768，沒有警告。**但這個結果分不出 GUI 設定有沒有改過** —— 環境變數與 GUI 出廠預設剛好都是 32768，蓋不蓋都一樣。要確認只能到桌面 app 的 Settings 看，或暫時把環境變數改成別的值再看 log。

同一天用 `manage-model.ps1 -Add gemma4:e4b-it-qat -Context 16384` 做端到端驗證：衍生模型 `gemma4:e4b-it-qat-ctx16k` 載入後 `ollama ps` 為 100% GPU、CONTEXT 16384（蓋過全域 32768），`-Bench` 量到生成 64.9 tok/s、讀提示 174.7 tok/s。驗證完已用 `-Remove` 刪掉衍生模型，原模型不受影響。

同一台稍早用原生 API 冷載入同一顆模型時，第一次只量到 1.65 tok/s（載入 84 秒）。之後同樣條件量到 64.9，差 40 倍。推測第一次是筆電 GPU 還沒從省電狀態醒來，但沒有深究。**筆電量速度要接電源，且丟掉冷載入後的第一個數字**。

**16GB 那階的 10291 MiB 已在第二台機器重現**
`PC-YI-FY`（RTX 5060 Ti 16GB）用 `nvidia-smi` 取載入前後差值，131072 下實佔 **10288 MiB**，與桌機首次實測的 10291 MiB 只差 3 MiB。這一階的數字可以當定論用。

量的時候要先確認沒有殘留 —— 殺 `ollama` 與 `ollama app` 不會帶走 `llama-server.exe`，那才是真正吃 VRAM 的行程。漏殺它會讓 baseline 多算幾個 GB（第一次量出 5206 MiB 的差值就是這樣來的，看起來還「比較省」，其實是舊實例已經佔著）。三個名字都要殺：`ollama`、`ollama app`、`llama-server`。

**第三台 16GB 機器 `PC-Yi-SL` 也驗過（2026-09-10）**
規格與 `PC-YI-FY` 相同（RTX 5060 Ti 16GB、61.7 GB 記憶體，另有 AMD 內顯沒被誤選），Ollama 0.33.3 由桌面 app 啟動。`-Check` 全綠：環境變數、server log 實際注入值、`opencode.json` 三處都是 131072，代表這台的 GUI 設定也已改過，沒被出廠的 32768 蓋掉。走 `/v1/chat/completions` 載入 `gemma4:12b` 後 `ollama ps` 為 100% GPU、CONTEXT 131072。

顯存差值約 10509 MiB，比定論值多約 220 MiB —— 但這次**沒有**照上一段先殺三個行程，baseline 是幾分鐘前讀的，差距在桌面環境波動範圍內，不推翻 10291 MiB。冷載入 68.8 秒，熱狀態回一句話 4.8 秒。

**選型表的「下載大小」不等於顯存佔用**
`gemma4:e4b-it-qat` 下載後 `ollama list` 顯示 6.1 GB，實際載入 `ollama ps` 只佔 3.1 GB。選型表的 `SizeGB` 是**磁碟下載大小**，用來預告要下載多久、要留多少硬碟，不能拿來推算塞不塞得進 VRAM。同理，同名模型的非 QAT 版本（`gemma4:e4b`，9.6 GB）在 8GB 卡上會部分掉到 CPU，QAT 版本才進得去 —— 8GB 這階一定要用 `-it-qat`。

**兩個上下文設定的作用範圍相反**
`opencode.json` 的 `limit.context` 掛在 `provider.ollama.models.<tag>` 底下，只影響那一個模型；`OLLAMA_CONTEXT_LENGTH` 是 Ollama 伺服器的環境變數，**所有**經由 Ollama 跑的模型都吃它。

這代表：日後若在同一台 Ollama 上再拉一個明顯更大的模型（例如 27B），全域的 131072 會讓它配不下而掉層到 CPU，且使用者不會意識到跟 Gemma 的設定有關。屆時的解法是把全域值設保守、個別模型用 Modelfile 拉高：

```
FROM gemma4:12b
PARAMETER num_ctx 16384
```

已實測驗證：這樣 `ollama create` 出來的衍生模型，走 OpenAI 相容端點載入時 `ollama ps` 的 CONTEXT 確實是 16384，蓋過全域設定。這也是 OpenCode 這條路上唯一能做到逐一模型控制上下文的方法（`num_ctx` 從 OpenAI 端點傳不進去，見下）。衍生模型共用權重 blob，不額外佔磁碟。

`PC-YI-FY` 上留著的 `gemma4:12b-ctx16k` 就是這條結論的證物：與 `gemma4:12b` 指向同一批權重 blob、其餘參數全同，只多一個 `PARAMETER num_ctx 16384`。**沒有任何設定引用它**（`opencode.json` 只定義 `gemma4:12b`），磁碟成本為零，留著是為了日後要複驗「Modelfile 蓋過全域」時不必重建 —— 跑 `ollama run gemma4:12b-ctx16k` 再看 `ollama ps` 的 CONTEXT 即可。

**`num_ctx` 無法從 OpenAI 相容端點傳入（已實測）**
同一台機器上三個對照：`/v1/chat/completions` 不帶參數 → 載入 4096；`/v1/chat/completions` 帶 `options.num_ctx=32768` → 仍是 4096，被靜默忽略；原生 `/api/chat` 帶同樣參數 → 32768。OpenCode 走 `@ai-sdk/openai-compatible`，打的是前者，所以 `opencode.json` 在協定層面上就無法決定實際載入的上下文，只能靠 `OLLAMA_CONTEXT_LENGTH` 或 Modelfile。

**`ollama ps` 的 SIZE 欄位不可靠**
同一個模型不同上下文下會在 8.1～8.5 GB 之間亂跳，跟實際 VRAM 佔用對不上。要量就用 `nvidia-smi --query-gpu=memory.used` 取載入前後的差值。

**24GB 那階選 MoE**
`gemma4:26b-a4b-it-qat`（16 GB）總參數 26B 但每次只啟用 4B，同顯存下比 31B 密集模型快得多。

**MoE 實測：更快，但沒有更會自我檢查（2026-08-22，PC-YI-FY）**
在 16GB 卡（RTX 5060 Ti）上實測，權重 16 GB 塞不進 VRAM，靠 61.7 GB 系統記憶體做 CPU offload：

| 模型 | 分配 | 速度 |
|---|---|---|
| `gemma4:12b` 密集 | 100% GPU、8.2 GB | 38.8 tok/s |
| `gemma4:26b-a4b-it-qat` | **31%/69% CPU/GPU**、16 GB | **49.8 tok/s** |

**即使 31% 掉到 CPU，MoE 仍比 12B 快 28%** —— 每個 token 只算 4B，而 12B 密集要算滿。這推翻了「16GB 卡上不了這一階」的假設：有大記憶體就能用 offload 換到，速度反而更好。

但**能力沒有跟著上去**。用同一個模糊指令（「把 timeout 調成 60，相關的地方都要一起改」，兩處要改：`config.py` 與 `README.md`），各跑三次、都放了要求 grep 驗證的 `AGENTS.md`：

| | 兩處都改對 | **真的執行驗證 grep** | 謊報驗證 |
|---|---|---|---|
| `gemma4:12b` | 3/3 | **0/3** | 2/3 |
| `gemma4:26b-a4b-it-qat` | 3/3 | **1/3** | 2/3 |

MoE 唯一一次「真的驗證」是運氣不是能力。兩個模型都會**聲稱驗證過但沒執行**，其中 MoE 有一次還把 `grep` 的指令與輸出整段假造出來。沒有 `AGENTS.md` 時 MoE 更糟：除了同樣漏掉 README，還在 `config.py` 多塞一行死註解 `# TIMEOUT = 60`。

**選型要看激活參數，不是總參數**
這是上面那組數字的解釋，也是比記住模型名更有用的一條：MoE 的**總參數決定知識廣度，激活參數決定推理深度**。自我稽核（拿當前狀態回頭比對原始目標）是推理能力，所以 `26b-a4b` 在這件事上表現得像 4B，不像 26B。

想買到穩定的自我稽核，要的是密集 30B+ 或激活參數大得多的 MoE —— 那已超出 16GB 卡加 offload 的舒適範圍。原本路線圖裡「MoE 是 24GB 那階的升級」這個假設，只在速度與知識廣度上成立，在 agentic 可靠度上不成立。

**`AGENTS.md` 的效果大於換模型**
同一組測試裡，有 `AGENTS.md` 的六次**全部**改對兩處；沒有規則的兩次（12B、MoE 各一）**全部**漏掉 README。規則能有效擴充「該改哪些地方」的檢查清單 —— 那只需照著清單執行，正是這個級距的強項；但規則要求的**自我稽核叫不出來**，模型只學會模仿回報格式。

實務結論：先寫 `AGENTS.md`，別急著換模型；且**不要相信模型的驗證聲明**，重要改動自己 `git diff`。要它驗證就寫「把 grep 的原始輸出貼出來」（執行），而不是「去確認有沒有殘留」（稽核）。

**31B 密集模型實測：跑得動，但慢十倍、沒有更可靠（2026-09-10，PC-Yi-SL）**
在 16GB 卡（RTX 5060 Ti、61.7 GB 記憶體）上下載 `gemma4:31b-it-qat`（`ollama list` 顯示 18 GB）。先殺三個行程、由桌面 app 重啟 Ollama 再量，上下文沿用全域 131072：

| 模型 | 分配 | 顯存差值 | 生成速度 |
|---|---|---|---|
| `gemma4:12b` | 100% GPU | 約 10.3 GB | 38.8 tok/s |
| `gemma4:26b-a4b-it-qat` | 31%/69% CPU/GPU | — | 49.8 tok/s |
| `gemma4:31b-it-qat` | **57%/43% CPU/GPU** | 14565 MiB | **3.9 tok/s** |

速度用原生 `/api/generate`、`think=false`、每次生成約 300 tokens，量兩次都是 3.9。這正好印證上面「看激活參數」那條：MoE 31% 掉到 CPU 還更快，因為每個 token 只算 4B；密集 31B 每個 token 都要穿過放在 CPU 的那 57%，速度只剩 12B 的十分之一。131072 的 KV cache 也在擠顯存，用 Modelfile 把 31B 的 `num_ctx` 調低應該能讓更多層回到 GPU —— 沒測。

能力比較用重建的沙盒（`src/config.py`、`src/client.py`、`README.md`，加一份三步驟的 `AGENTS.md`：改前 grep、逐一檢視、改後再 grep），12B 與 31B 在**同一個沙盒**各跑三次，指令同樣是「把 timeout 調成 60，相關的地方都要一起改」：

| | 兩處都改對 | 改完真的再 grep | 謊報驗證 | 每輪耗時 |
|---|---|---|---|---|
| `gemma4:12b` | 0/3 | 0/3 | 0/3 | 20–28 秒 |
| `gemma4:31b-it-qat` | 1/3 | 0/3 | 0/3 | 4–5 分鐘 |

慢十幾倍只多對一次，三次的樣本分不出是能力還是運氣；`AGENTS.md` 第 3 步（改完再 grep）六次都沒執行。所以上面「要穩定的自我稽核得上密集 30B+」那條，**至少在 16GB 卡加 offload 這條路上買不到**。對 16GB 卡的結論：留在 12B，不要上 31B。

**這組數字不能跟 MoE 那張表並列。** 原沙盒內容沒留紀錄，這次是照線索重建的；舊表 12B 有 `AGENTS.md` 是 3/3 改對，這次是 0/3。已確認不是 `AGENTS.md` 沒載入（方法見工作約定），差異應該來自規則措辭與檔案內容不同。這次也沒有謊報驗證，可能是因為重建的規則沒要求模型回報驗證結果。

**真正決定成敗的是 grep 的大小寫**
六次的第一步都是 grep 小寫的 `timeout`。OpenCode 的 grep 工具區分大小寫，只命中 `client.py` 裡的 `timeout=TIMEOUT` 那一行。之後有沒有再 grep 大寫 `TIMEOUT`，幾乎直接決定結果：

- 只搜小寫的三次（12B 一次、31B 兩次）：**全部**不知道 README 要改
- 有再搜大寫的三次：都看到了 README；其中 12B 一次把路徑寫成 `src/README.md` 失敗後放棄、一次看到卻沒改，只有 31B 那次改對

也就是說，失敗主要發生在「搜尋」這一步，而不是「判斷」。實務上值得在專案 `AGENTS.md` 寫明「搜尋名稱時不分大小寫」—— 這條還沒實測效果。

**`qwen3.8:27b` 實測速度：比 31B 快近一倍，但仍是 12B 的七分之一（2026-09-12，PC-YI-FY）**
和 `PC-YI-SL` 同規格（RTX 5060 Ti 16GB、61.7 GB 記憶體），Ollama 0.34.0。用 `manage-model.ps1 -Add qwen3.8:27b -Context 32768` 一次跑完：registry 查到 17.7 GB、評估段落預告「權重 16.5 GB 大於可用顯存 15.9 GB，一定 offload」、下載、建 `qwen3.8:27b-ctx32k`、寫進 `opencode.json`、測試訊息、量速度。`/api/show` 回報的能力是 `completion, vision, tools, thinking`，OpenCode 三個旗標都開。

| 模型 | 上下文 | 分配 | 生成速度 |
|---|---|---|---|
| `gemma4:12b` | 131072 | 100% GPU | 45.7–47.9 tok/s |
| `gemma4:12b-ctx16k` | 16384 | 100% GPU | 45.3–46.8 tok/s |
| `qwen3.8:27b-ctx32k` | 32768 | **39%/61% CPU/GPU**（`ollama ps` 的 SIZE 19 GB） | **6.9–7.0 tok/s** |
| `qwen3.8:27b-ctx64k` | 65536 | **48%/52% CPU/GPU**（SIZE 20 GB） | **5.3–5.7 tok/s** |

上下文從 32K 加倍到 64K，`ollama ps` 的 SIZE 只多 1 GB，但 CPU 的比例從 39% 升到 48%，生成速度掉了約兩成。**Qwen 不像 Gemma**：上下文變大會實際吃掉顯存，把更多權重擠到 CPU。64K 版是給使用者在 OpenCode 裡試跑用的。

12B 那兩列是同一天、同一台用 `-Bench` 量的，第一列的數字已經丟掉冷載入那次。它比 README 記的 38.8 tok/s 快約兩成，但 38.8 是 Ollama 0.32 時量的，量法也沒記下來，所以不能把差距歸給版本。**同一批權重，上下文 131K 和 16K 生成速度一樣**，符合 Gemma 的 KV cache 幾乎不隨上下文成長。

Qwen 27B 掉到 CPU 的比例（39%）比 31B（57%）少，速度也快了近一倍（7.0 對 3.9）。但兩者的上下文不同（32768 對 131072），而且不是同一台機器，所以不能說成是模型本身比較快。每輪 agent 任務大概要好幾分鐘，實際能不能用還沒驗證。讀提示速度第一次 23.7、第二次 113.9，差這麼多可能是第二次的提示命中了快取，沒有深究。

**技能放專案層級，不進全域**
路徑是 `.opencode/skills/local-llm-setup/` 與 `.opencode/skills/local-llm-model/` —— OpenCode 對專案技能會從 cwd 往上找到 git worktree 根目錄。刻意不裝進 `~/.config/opencode/skills/`，也不跑 `sync-skills`：兩個技能只服務「OpenCode 接本機模型」這一件事，沒有跨專案使用的理由，放全域只會在每個專案的技能清單裡佔位置。而且它們依賴專案裡的 `.opencode/lib/LocalLlm.ps1`，單獨複製出去也跑不起來。

**macOS 只支援 Apple Silicon**
Intel Mac 沒有 Ollama 可用的 GPU 加速（Metal 後端只對 Apple Silicon 有效），純 CPU 跑 12B 不堪用。腳本在 `Get-MacHardware` 用 `uname -m` 檢查，不是 arm64 就直接 throw 並說明原因，而不是讓使用者下載完 7.6GB 才發現跑不動。

**Apple Silicon 的「等效 VRAM」是估的**
統一記憶體由 CPU/GPU 共用，Metal 的可取用上限看 `iogpu.wired_limit_mb`，未調整時約為總記憶體的 65~75%。腳本取保守比例（36GB 以下 70%、以上 80%）換算後套用同一張 GPU 選型表。這是啟發式，不是量測值 —— 真的在 Mac 上跑過之後應該回頭校正。

**Mac 上還有 MLX 這條路，選型表從來沒走過（未驗證）**
Ollama 在 Apple Silicon 是**雙後端**：GGUF 模型走 llama.cpp ＋ Metal，`-mlx` tag 的模型才走 Apple 的 MLX 引擎，**兩者不會自動互轉**。選型表一律給 GGUF tag（`gemma4:12b`、`31b-it-qat` …），所以 Mac 路徑實際上一次都沒用到 MLX。

registry 上有對應的 MLX tag，大小與 GGUF 版相近：`gemma4:31b-mlx`（19 GB）、`26b-mlx`（18 GB）、`31b-mlx-bf16`（64 GB），另有 `31b-nvfp4`（19 GB）與 `31b-mxfp8`（33 GB）。官方說法是 MLX 引擎「更快、更省記憶體」，Gemma 4 在 0.31 之後還有多 token 預測（MTP）加速；量化格式方面稱 NVFP4 比 q4_K_M 快約 20%。

**這些都是官方部落格的說法，本專案一項都沒實測。** 兩件事要在階段八一起驗證：

1. 同一台 Mac 上 `gemma4:12b`（GGUF）與對應 MLX tag 的速度與記憶體佔用差多少 —— 差很多的話 Mac 的選型表要另立一張，不能沿用 GPU 那張。
2. MLX 引擎在 0.19 preview 時的門檻是「32 GB 以上統一記憶體」。這條若仍有效，24 GB 的 Mac 根本吃不到 MLX，會直接影響購買建議與選型分界。有沒有在後續版本放寬，沒查到。

在驗證之前**不要把 MLX tag 寫進 `$MacProfiles` 之類的自動選型**，沒實測的東西不該讓腳本自動選中。

**Gemma 4 的完整 tag 階梯（31B 是天花板）**
Gemma 4 最大就是 31B，沒有更大的參數量。選型表只收了每個尺寸的其中一兩階，完整階梯是：

| 尺寸 | qat | q4_K_M | mxfp8 | q8_0 | bf16 |
|---|---|---|---|---|---|
| 31B 密集 | 19 GB | 20 GB | 33 GB | 34 GB | 63 GB |
| 26B MoE（a4b） | 16 GB | 18 GB | 28 GB | 28 GB | 52 GB |
| 12B | — | 7.6 GB | — | — | — |

另有 `gemma4:31b-coding-mtp-bf16`（64 GB），coding 專用且帶 MTP —— 對「OpenCode 跑 agent」這個用途最對口，但 64 GB 的體積要 96 GB 以上的機器才裝得下，目前沒有硬體可測。

選型表刻意只放 qat 與 q8_0 兩階：qat 是同尺寸下最省的可用選擇，q8_0 是品質接近原始權重的那一階，中間的 q4_K_M 與 qat 差距小、不值得多一個分支。要用其他階就 `-Model` 手動指定。

**Mac 要幾 GB 才選得到 MoE：36GB**
把上面的比例套進 GPU 選型表（MoE 那階門檻是 23）：

| 統一記憶體 | 等效 VRAM | 選到 |
|---|---|---|
| 24 GB | 16.8 | `gemma4:12b` / 131072 |
| 32 GB | 22.4 | `gemma4:12b`（**差 0.6 GB 沒進 MoE**） |
| **36 GB** | 25.2 | **`gemma4:26b-a4b-it-qat`** |
| 48 GB | 38.4 | `gemma4:31b-it-qat`（跳過 MoE） |
| 64 GB | 51.2 | `gemma4:31b-it-q8_0` |

自動選中 MoE 的窗口只有 36–40 GB 這一小段。**32GB 的 Mac 實際上跑得動**（權重 16 GB，32GB 機器的 wired limit 預設約 24 GB），只是被 0.70 的保守比例卡在門檻外 0.6 GB —— 要在 32GB 機器上測就得 `-Model gemma4:26b-a4b-it-qat` 手動指定。48GB 以上想測 MoE 也一樣要手動指定，否則會自動跳到 31B 密集模型。

這個「差 0.6 GB」正是估值不準的代價，也是階段八要校正那個比例的具體理由。

**macOS 的環境變數要做兩層**
`launchctl setenv` 立即生效且 GUI 版 Ollama 讀得到，但**活不過重開機**。所以還要在 `~/Library/LaunchAgents/ai.ollama.env.plist` 寫一個 `RunAtLoad` 的 LaunchAgent 於登入時重設。少了這層，使用者某天重開機後上下文會悄悄掉回 4096，而且完全沒有徵兆 —— 這是最難查的那種故障。`-Check` 會檢查 plist 是否存在。

**必須用 PowerShell 7**
腳本是 UTF-8 無 BOM，5.1 會用系統 ANSI 解讀而在 parse 階段失敗；而且 `ConvertFrom-Json -AsHashtable` 在 5.1 不存在，設定合併會直接壞掉。腳本有 `#requires -Version 7.0`。

**OpenCode 會合併 `opencode.json` 與 `opencode.jsonc`**
兩個檔案同時存在時 OpenCode 兩份都讀、合併生效（已實測：`opencode models ollama` 同時列出兩邊定義的模型）。腳本用 `Resolve-OpenCodeConfig` 盤點同目錄的兩個檔名，`-Check` 逐份回報、並比對 `ollama list` 指出「設定裡有但 Ollama 沒有」的死項目；寫入前若發現另一份也定義了 `provider.ollama`，會警告那份不會被清掉、要手動移除。

寫入目標的規則：明確給 `-ConfigPath` 就寫那份（盤點與警告照做）；沒給時只有 `.jsonc` 存在就寫 `.jsonc`，其餘一律寫 `.json`。

**單一設定檔請用 `.json`，不要用 `.jsonc`**
腳本寫回時走 `ConvertTo-Json`，**註解一定會被清掉** —— `.jsonc` 唯一的優勢因此不成立。腳本寫入 `.jsonc` 時會先警告這件事。PowerShell 7 的 `ConvertFrom-Json` 讀得動註解與尾逗號（5.1 不行，這是另一個必須用 pwsh 7 的理由）。

**設定合併不覆寫整份檔案**
`opencode.json` 裡還有 mcp、permission、experimental 等使用者既有設定。腳本用 `ConvertFrom-Json -AsHashtable` 讀進來、只改 `provider.ollama` 這一支、再寫回，並在寫入前備份成 `opencode.json.bak-<時間戳>`（同一秒重跑會自動加序號，不覆蓋前一份）。

## 工作約定

操作型規則，與上面的「技術決策」分開：那邊解釋為什麼這樣設計，這邊是動手時不要踩的雷。

**測 OpenCode CLI：不可用 `timeout` 包裝，也不可放進巢狀 bash 腳本**
兩種寫法都會讓 `opencode run` **卡死在啟動階段** —— log 檔全空、模型完全沒載入、進程掛著不退，外觀跟「模型跑很慢」一模一樣。直接在命令列跑則一切正常。要限制時間就改成背景執行、事後用 `Stop-Process` 終止。

這條記下來是因為它在 2026-08-22 那次連續造成三次誤判：先誤以為是目錄被鎖、再誤以為是 MCP server 連線卡住，最後才發現凡是被 `timeout` 或巢狀腳本包起來的都失敗、直接跑的都成功。下一個 Agent 很可能重踩。

**清理測試進程時，比對條件不要包含自己會出現的字串**
用 `Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match '...' }` 掃殺殘留進程時，若比對字串正好出現在自己這行命令裡，會把自己殺掉（表現為 exit 255）。同一次工作階段內犯過兩次。改用進程名 `-Filter "Name='opencode.exe'"` 篩選，或挑一個不會出現在清理指令自身的特徵字串。

Windows 上 `opencode.exe`（CLI）與 `OpenCode.exe`（桌面 app）在 WMI 查詢裡可用大小寫區分，篩 CLI 用小寫那個，不會誤傷使用者開著的桌面版。

**用 `until ... sleep` 等背景工作時，殺掉工作也要停等待迴圈**
等待迴圈盯的是某個檔案裡的完成標記。一旦把產生標記的腳本殺了（或把檔案刪了），條件永遠不成立，迴圈會無限空轉、不會自己結束也不會回報。殺工作時要連等待方一起停。

**`opencode run --format json` 重導到檔案時，跑的過程中檔案是空的**
2026-09-10 實測：模型已經載入、正在跑，輸出檔一直是 0 bytes，要到 `opencode` 結束才一次寫入。判斷有沒有在跑要看 `ollama ps` 有沒有載入模型，不要看輸出檔大小。事件裡 `type=tool_use` 的 `part.tool` 與 `part.state.input` 就是完整的工具序列 —— 判斷「有沒有真的執行驗證」要看這個，不要看模型的回覆文字。

**模型不照 `AGENTS.md` 做時，先確認規則有沒有被載入**
用 `opencode run --dir <專案> "不要使用任何工具，直接根據你的系統指示回答：AGENTS.md 規定了什麼？"`。JSON 輸出裡工具呼叫數為 0、又答得出內容，就代表規則確實在系統提示裡。先做這一步，才分得清是「沒載入」還是「載入了但不照做」—— 兩者的修法完全不同。

**Agent 代跑會詢問的腳本時，先列出會自動同意的步驟，再加 `-Yes`**
Agent 的 shell 是非互動的，`Confirm-Step` 裡的 `Read-Host` 答不了。可能直接出錯，也可能讀到空字串——而空字串會被當成同意。技能寫的是「不要主動加 `-Yes`」，所以要先向使用者列出會被自動同意的步驟（下載、建衍生模型、寫 `opencode.json`、卸載其他模型），確認都是使用者要的才加。`-Check`、`-List` 不會詢問；`-Bench` 只在有別的模型載入中時才問。

**Ollama 升級後跑一次 `-Check`**
桌面 app 的 context length 存在 `db.sqlite`（`schema_version` 目前 16），大版本升級若動到 schema 或重設預設值，設好的值可能被打回出廠的 32768，且沒有任何提示。原因見上面「Ollama 桌面 app 的 GUI 設定會覆蓋 `OLLAMA_CONTEXT_LENGTH`」。

## 測試

```powershell
pwsh -NoProfile -File .\tests\test-local-llm-setup.ps1
pwsh -NoProfile -File .\tests\test-local-llm-model.ps1
```

隔離測試共 203 項（setup 104 ＋ model 99）：不連網、不安裝、不下載模型、不建立或刪除模型、不動使用者環境變數、不碰真正的 `opencode.json`。改到 `.opencode/lib/LocalLlm.ps1` 時兩支都要跑。

兩支都在 `Set-StrictMode -Version Latest` 下跑，和腳本本身一致。共用函式庫直接 dot-source；主腳本用 AST 抽函式。`$GpuProfiles`／`$CpuProfiles` 也從 AST 抽賦值敘述，不在測試裡另抄一份，免得抄的那份和腳本漂移了測試照樣會過。顯卡篩選也改成直接測腳本實際呼叫的 `Select-UsableGpu`，理由相同。斷言工具與「dot-source 路徑指得到檔案」的檢查放在 `tests/assert.ps1`。

- **setup**：語法／編碼、Windows 與 Apple Silicon 兩條選型路徑、顯卡篩選規則、LaunchAgent 的 plist 是否為合法 XML、設定合併與備份（含能力旗標）、`.json`／`.jsonc` 並存時的解析與寫入目標、server log 的上下文解析與不一致偵測。
- **model**：參數組（`-Context` 只能配 `-Add`）、tag 正規化與 registry 網址、衍生模型命名與 `num_ctx` 解析、能力旗標、速度與分配換算、冷載入判斷與平均、已載入模型的段落、顯存粗估、`limit.context` 比對、移除目標挑選（含同前綴誘餌）、設定移除與 `model`／`agent.*.model` 殘留、API 欄位缺漏。

會打 Ollama 或 registry 的函式不在隔離測試裡，只測它們背後的純函式。實際行為是 2026-09-11 在 `NB-YI` 用真的 Ollama 跑 `-Check`、`-List`、`-Add`、`-Remove` 驗過的（設定檔指到暫存目錄）。2026-09-12 在 `PC-YI-FY`（16GB）又跑了 `-Check`、`-List`、`-Bench`，以及寫進真正設定檔的 `-Add qwen3.8:27b`。`-Bench` 的暖機判斷還沒在實機走過，因為 `-Add` 量速度前，測試訊息已經把模型載入了。

StrictMode 下 `[xml]` 物件要從 `DocumentElement` 往下取：plist 帶 DOCTYPE，`$doc.plist` 會同時對到 DOCTYPE 節點與根元素，再取 `.dict` 就丟例外。

log 解析那組測試用**假的 log 文字**餵 `Read-ContextFromLogText`，不碰真的檔案；不一致偵測則在區塊內重新定義 `Write-Warn2`／`Get-OllamaRuntimeContext` 之類的相依函式來攔輸出，所以在沒裝 Ollama 的機器上也跑得完。誘餌案例（`default_num_ctx=4096`）刻意保留，避免哪天正則放寬成 `\d+` 又抓錯數字。

macOS 的實際系統呼叫（`launchctl`、`osascript`、`brew`）在 Windows 上測不到，所以把 plist 的 XML 組裝抽成 `New-MacLaunchAgentXml` 獨立函式，至少讓最容易出跳脫錯誤的那段可以被驗證。

## 對外相依

- Ollama（winget id `Ollama.Ollama`）
- Ollama registry 的 `gemma4` / `gemma3` tag（自動選型）；其他模型由使用者用 `-Add` 指定
- Ollama registry 的 manifest API（`registry.ollama.ai/v2/.../manifests/<tag>`，下載前查大小；非官方 API，查不到時腳本照常下載）
- Ollama 本機 API：`/api/tags`、`/api/show`（`capabilities`、`parameters`）、`/api/ps`（`size_vram`、`context_length`）、`/api/generate`
- OpenCode 設定 schema：<https://opencode.ai/config.json>
- OpenCode 的 Ollama 接法需要 `@ai-sdk/openai-compatible`（OpenCode 沒有內建 ollama provider）
