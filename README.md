# VentiVoice

一个运行在本地的语音转文字桌面工具，专为中文场景优化。

在日常工作中，打字往往是思考到输出之间最大的瓶颈——你脑子里已经想好了要写什么，但手指跟不上。VentiVoice 让你按下热键直接说话，松开后几秒内就能得到一段经过 AI 润色的书面文本，自动复制到剪贴板，直接粘贴到任何地方。

核心流程：**热键录音 → 本地 ASR 转写 → LLM 智能纠错+润色 → 剪贴板输出**。ASR 完全在本地运行（无需联网），LLM 润色通过 API 调用（支持任意 OpenAI 兼容接口）。整个流程通常在 3-5 秒内完成，适合写消息、记笔记、写邮件、口述文档以及写Prompt进行Vibe Coding等场景。

## 为什么选择这些 ASR 模型

本项目在开发过程中测试了多种 ASR 方案，包括口碑极好的 Whisper 系列（tiny / large-v3-turbo / large-v3）。但实测发现，Whisper 在个人电脑本地部署、面对中文语音时存在明显问题：

- **中文识别准确率不理想**：Whisper 是多语言通用模型，中文并非其强项，尤其在口语化、带方言色彩的日常表达中错误率较高
- **推理速度慢**：large-v3 在无 GPU 加速时转写 5 秒音频需要 10-30 秒，即使有 Vulkan 加速也远不如专用中文模型
- **部署复杂**：需要编译 whisper.cpp、配置 Vulkan SDK、处理 DLL 依赖，门槛较高

最终选定的 3 个模型均基于 sherpa-onnx 运行时，开箱即用：

| 模型 | 参数量 | 特点 | 适用场景 |
|------|--------|------|----------|
| **SenseVoice-Small** | 234M | 非自回归，极快（5 秒音频 < 0.5s），中/英/日/韩/粤 | 日常使用首选，速度优先 |
| **SenseVoice-2025** (`sensevoice-large`) | ~234M | 2025-09-09 int8 版本，基于 2024-07-17 版本微调，中/粤/英/日/韩；官方说明不支持标点 | 需要新版 SenseVoice 或粤语表现时切换 |
| **Paraformer-Large** | ~220M | 阿里达摩院中文专用模型，非自回归 | 纯中文场景的备选方案 |

三者均使用 int8 量化，单个模型约 220-230MB，总共约 700MB，对磁盘和内存友好。

## 功能

### 核心转写

- 全局热键录音（push-to-talk 或 toggle 模式）
- 三档 LLM 润色：Clean（最低限度清理）/ Refine（书面化整理）/ Rewrite（理解重写）
- 多 ASR 模型切换：SenseVoice-Small / SenseVoice-2025 (`sensevoice-large`) / Paraformer-Large
- 多 LLM 配置管理：支持任意 OpenAI 兼容 API，可在界面内新建/编辑/测试

### 个人词库系统

VentiVoice 拥有一套完整的个人词库系统，能够随着使用不断学习你的语言习惯：

- **LLM 智能纠错**：不再依赖简单字符串替换，而是将词库注入 LLM prompt，由 AI 识别并修正与错误变体相似但不完全一致的 ASR 错误（如"温迪"被识别为"问题"/"闻笛"/"温蒂"等发散变体）
- **自动术语发现**（第三层 LLM）：每次转写完成后，自动分析结果中的专业领域词汇（游戏角色名、学术术语、技术名词、人名地名等），智能加入词库，无需手动维护
- **个性化转写**：LLM 从词库整体推断你的关注领域和语言习惯，在存在歧义时优先倾向你常用领域的表达
- **分层注入策略**：词库按使用频率排序，≤100 条全量注入，100-1000 条前 100 详细+其余仅列正确词，>1000 条截断到 1000 条处理，控制 token 开销
- **词库管理面板**：支持检索词条、手动加入/删除、黑名单机制（被删除的词永远不会被自动加入）
- **旅客模式**：一键关闭词库注入，适合在公共设备上使用

### 界面与体验

- 自定义窗口图标
- 系统托盘常驻，深色主题 UI
- 纠错面板：提交错误词→正确词，自动替换当前文本并复制到剪贴板
- 上次结果：防止误触热键覆盖剪贴板，可随时找回上一次转写结果（跨程序重启持久化）
- 热键设置面板：可折叠，按需展开
- 词库发现提示栏：自动发现新词时在独立状态行显示

## 快速开始

### 环境要求

- Python 3.10+
- Windows 10/11
- 麦克风

### 1. 克隆仓库或下载 release 源码

```bat
git clone https://github.com/jerryloopback-netizen/VentiVoice.git
cd VentiVoice
```

### 2. 创建虚拟环境并安装依赖

在 Windows `cmd.exe` 中运行：

```bat
py -3.10 -m venv .venv
.venv\Scripts\activate
python -m pip install -U pip
python -m pip install -r requirements.txt
```

如果你不想手动输入这些步骤，推荐直接双击仓库根目录的 `install.bat`。它会自动完成：

- 创建 `.venv`
- 安装 Python 依赖
- 复制 `config.yaml`
- 选择并下载模型
- 生成 `run.bat`、`run_debug.bat`
- 可选创建桌面快捷方式

如果你使用 PowerShell：

```powershell
py -3.10 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -U pip
python -m pip install -r requirements.txt
```

### 3. 下载 ASR 模型

模型文件较大，不包含在仓库中。默认只下载日常推荐的 `sensevoice-small`（约 230MB），不是一次下载全部模型：

```bat
python scripts\download_models.py
```

下载其他模型：

```bat
python scripts\download_models.py --model paraformer-large
python scripts\download_models.py --model sensevoice-large
python scripts\download_models.py --all
```

也可以先不下载其他模型。程序启动后，ASR 模型下拉框会标出未下载模型；选择未下载模型时，会提示是否立即下载，下载完成后自动切换。

下载脚本支持简单的下载源选择：

```bat
python scripts\download_models.py --model sensevoice-large --source auto
python scripts\download_models.py --model sensevoice-large --source hf-mirror
python scripts\download_models.py --model sensevoice-small --source official
```

`auto` 会对同一文件的可用源做一次轻量测速，然后选择较快的源。当前三个模型都配置了 Hugging Face 官方源和 `hf-mirror.com` 备用源。

如果网络不佳，也可以手动下载模型并放入 `models/` 目录：

| 模型 | 官方源 | 备用源 | 目录名 |
|------|--------|--------|--------|
| SenseVoice-Small | [Hugging Face](https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17) | [hf-mirror](https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17) | `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/` |
| SenseVoice-2025 (`sensevoice-large`) | [Hugging Face](https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09) | [hf-mirror](https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09) | `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09/` |
| Paraformer-Large | [Hugging Face](https://huggingface.co/csukuangfj/sherpa-onnx-paraformer-zh-2024-03-09) | [hf-mirror](https://hf-mirror.com/csukuangfj/sherpa-onnx-paraformer-zh-2024-03-09) | `sherpa-onnx-paraformer-zh-2024-03-09/` |

每个模型目录下至少需要 `model.int8.onnx` 和 `tokens.txt` 两个文件。

版本说明：参考 Sherpa-ONNX 的 [SenseVoice 官方文档](https://github.com/k2-fsa/sherpa/blob/master/docs/source/onnx/sense-voice/pretrained.rst) 和 [Paraformer 官方文档](https://github.com/k2-fsa/sherpa/blob/master/docs/source/onnx/pretrained_models/offline-paraformer/paraformer-models.rst)。当前 SenseVoice 新版本为 `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09`；`sensevoice-small` 仍使用 2024-07-17 版本作为默认速度优先模型。Paraformer 标准中英文模型仍使用 `sherpa-onnx-paraformer-zh-2024-03-09`；官方文档另有更新的方言微调模型，但不是本项目当前默认 Paraformer 的直接替代。

### 4. 配置 LLM API

复制配置模板并填入你的 API 信息：

在 Windows `cmd.exe` 中运行：

```bat
copy config.yaml.example config.yaml
```

在 PowerShell 中运行：

```powershell
Copy-Item config.yaml.example config.yaml
```

编辑 `config.yaml`，将 `api_key` 替换为你的实际密钥。支持任何 OpenAI 兼容接口（OpenAI、DeepSeek、本地 LM Studio 等）。

也可以启动程序后在界面内管理 LLM 配置。这里，推荐OpenAI的gpt-5.4-mini，具有高速响应和不错的智能。这个模型的API在不少第三方转发站点成本几乎没有。

若没有第三方OpenAI compatible API申请经历，可以尝试 coderelay.cn 的 gpt-5.4-mini。仅作参考不做任何推荐。

### 5. 验证 ASR（可选）

```bat
python src\verify_pipeline.py --no-llm
```

### 6. 运行

```bat
python src\main.py
```

也可以直接双击 `run.bat`，或运行 `install.bat` 后使用生成的桌面快捷方式。

### 卸载

如果要移除这套 Windows 部署生成的内容，双击 `uninstall.bat`。它会删除：

- `.venv`
- `models`
- `config.yaml`
- `corpus\corrections.json`
- `corpus\blacklist.json`
- `corpus\last_result.txt`
- `run.bat`、`run_debug.bat`
- 本地和桌面快捷方式

> 旧的 `scripts/download_models.sh` 和 `scripts/verify_asr.sh` 仍保留给 Git Bash / WSL / Linux 用户。普通 Windows 部署不需要安装 WSL，也不需要运行 `bash`。

## 使用方法

### 录音模式

- **按住录音 (push-to-talk)**：按住热键说话，松开后自动转写
- **Toggle 模式**：按一下开始录音，再按一下结束

可在「热键设置」面板中切换模式。

### 默认热键

| 热键 | 功能 |
|------|------|
| Alt+Shift+1 (!) | 档位一: Clean（最低限度清理） |
| Alt+Shift+2 (@) | 档位二: Refine（书面化整理） |
| Alt+Shift+3 (#) | 档位三: Rewrite（理解重写） |
| Escape | 取消当前操作 |

热键可在界面内自定义修改。

### 个人词库

**手动纠错**：在「纠错」面板中输入错误词和正确词并提交。同一正确词的多种错误变体会自动合并。

**自动发现**：转写完成后，第三层 LLM 会自动识别结果中的专业术语并加入词库。如果某个词不应被加入，可在词库面板中搜索并删除（加入黑名单后永远不会再被自动加入）。

**词库面板**：点击「个人词库」按钮打开，可查看词条统计、LLM 生成的用户画像描述、检索/删除/手动添加词条。

## 项目结构

```
VentiVoice/
├── src/
│   ├── main.py          # 主程序 (UI + 热键 + 流程控制)
│   ├── asr.py           # ASR 引擎抽象层 (sherpa-onnx)
│   ├── llm.py           # LLM 后处理 (三档润色 + 术语发现)
│   ├── recorder.py      # 录音模块
│   ├── corpus.py        # 个人语料库管理 (词库 + 黑名单)
│   └── config.py        # 配置加载/保存
├── prompts/             # LLM 提示词模板
├── models/              # ASR 模型 (需下载，不含在仓库中)
├── corpus/              # 个人语料库数据 (自动生成，不含在仓库中)
├── scripts/             # 辅助脚本
├── config.yaml.example  # 配置模板
├── requirements.txt     # Python 依赖
└── logo.ico             # 应用图标
```

## 技术栈

- ASR: [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (SenseVoice / Paraformer)
- LLM: 任意 OpenAI 兼容 API
- UI: tkinter + pystray (系统托盘)
- 热键: pynput (全局监听)
- 音频: sounddevice

## License

MIT
