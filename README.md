# VentiVoice

按下热键说话，松开即得书面文本。

VentiVoice 是一个 Windows 桌面语音转写工具，将本地 ASR 识别与 LLM 润色结合，把口语实时转化为可直接粘贴的书面文字。ASR 完全离线运行，LLM 通过你自己的 API Key 调用任意 OpenAI 兼容接口（BYOK），整个流程通常 3-5 秒完成。

**核心流程：热键录音 → 本地 ASR 转写 → 个人词库注入 → LLM 智能纠错+润色 → 剪贴板输出**

适用场景：写消息、记笔记、写邮件、口述文档、Vibe Coding 时口述 Prompt。

## 特性

- **三档 LLM 润色**：Clean（最低限度清理）/ Refine（书面化整理）/ Rewrite（理解重写），一个热键对应一个档位
- **多 ASR 模型热切换**：SenseVoice-Small / SenseVoice-2025 / Paraformer-Large，界面内一键切换，缺失模型自动提示下载
- **多 LLM Provider 管理**：界面内新建、编辑、删除、测试连通性，支持任意 OpenAI 兼容 API
- **个人词库系统**：LLM 智能纠错 + 自动术语发现 + 分层注入策略 + 黑名单 + 旅客模式（详见下方）
- **全局热键**：push-to-talk（按住录音）或 toggle（按一下开始/再按结束）两种模式，热键可自定义
- **系统托盘常驻**：关闭窗口最小化到托盘，不占任务栏
- **纯本地 ASR**：无需联网即可完成语音识别，隐私友好

## 架构概览

```
┌─────────────────────────────────────────────────────────────┐
│  main.py — UI + 热键 + 流程编排 (tkinter + pystray)         │
├─────────────────────────────────────────────────────────────┤
│  recorder.py        sounddevice 录音，输出 float32 numpy     │
│  asr.py             sherpa-onnx 离线推理 (SenseVoice/Para)   │
│  llm.py             三档润色 + 术语发现 (OpenAI 兼容 API)     │
│  corpus.py          个人词库管理 (JSON 持久化 + 黑名单)       │
│  config.py          YAML 配置加载/保存                       │
├─────────────────────────────────────────────────────────────┤
│  prompts/           三档 LLM 提示词模板                      │
│  models/            ASR 模型文件 (int8 ONNX)                 │
│  corpus/            用户词库数据 (corrections + blacklist)    │
│  scripts/           安装器、模型下载、卸载                    │
└─────────────────────────────────────────────────────────────┘
```

数据流：

1. 用户按住热键 → `recorder.py` 通过 sounddevice 采集 16kHz float32 音频
2. 松开热键 → `asr.py` 调用 sherpa-onnx 离线推理，返回原始文本
3. `corpus.py` 根据词库大小构建分层注入内容，嵌入 prompt 模板
4. `llm.py` 将注入后的 prompt 发送到用户配置的 LLM API，返回润色结果
5. 结果自动复制到剪贴板，显示在悬浮窗中
6. 后台异步：术语发现 LLM 从结果中提取专业词汇，自动扩充词库

## ASR 模型

本项目测试过 Whisper 系列（tiny / large-v3-turbo / large-v3），但 Whisper 在无 GPU 的 Windows 本地部署中存在中文准确率低、推理慢、部署复杂的问题。最终选定基于 sherpa-onnx 运行时的三个模型：

| 模型 | 特点 | 适用场景 |
|------|------|----------|
| **SenseVoice-Small** | 非自回归，极快（5s 音频 < 0.5s），中/英/日/韩/粤 | 日常首选 |
| **SenseVoice-2025** | 2025-09 int8 版本，不支持标点 | 粤语或需要新版时切换 |
| **Paraformer-Large** | 阿里达摩院中文专用 | 纯中文备选 |

三者均为 int8 量化，单模型约 230MB，总计约 700MB。

## 个人词库系统

词库是 VentiVoice 区别于普通转写工具的核心能力，随使用自动积累：

**工作原理**：词库不做简单字符串替换，而是将纠错词条注入 LLM prompt，由 AI 根据语境智能判断。例如"温迪"可能被 ASR 识别为"问题"/"闻笛"/"温蒂"等发散变体，LLM 能从上下文推断正确词。

**自动术语发现**：每次转写完成后，后台 LLM 分析结果中的专业词汇（游戏角色名、学术术语、技术名词等），自动加入词库，无需手动维护。

**分层注入策略**：
- ≤100 条：全量注入（错误变体 → 正确词）
- 100-1000 条：前 100 条详细注入 + 其余仅列正确词
- \>1000 条：截断到 1000 条

**词库管理**：
- 手动纠错：在纠错面板提交 错误词→正确词，同一正确词的多种变体自动合并
- 检索/删除/手动添加：词库面板内操作
- 黑名单：删除的词永远不会被自动发现再次加入
- 旅客模式：一键关闭词库注入，适合公共设备
- 词库画像：LLM 分析词库内容，生成用户领域描述

## 快速开始

### 环境要求

- Python 3.11-3.14
- Windows 10/11
- 麦克风

### 自动部署（推荐）

克隆仓库或下载 release 源码后，在项目根目录双击运行：

```bat
install.bat
```

安装脚本会自动完成：

- 创建 `.venv`
- 安装 Python 依赖
- 初始化 `config.yaml`
- 如有旧配置，安装器会引导你手动替换并导入 API / 词库
- 选择并下载 ASR 模型
- 可选写入初始 LLM API 配置
- 生成 `run.bat`、`run_debug.bat`
- 可选创建桌面快捷方式

安装器会在本机 Python 3.11-3.14 中选择包含预编译 NumPy 2.4 wheel 和 sherpa-onnx wheel 的最高可用版本。

部署完成后，双击运行：

```bat
run.bat
```

如果启动失败，用下面的调试入口查看错误：

```bat
run_debug.bat
```

### 手动部署

如果你需要手动部署、排错或参与开发，可以按下面步骤执行。

#### 1. 获取源码

```bat
git clone https://github.com/jerryloopback-netizen/VentiVoice.git
cd VentiVoice
```

#### 2. 创建虚拟环境并安装依赖

在 Windows `cmd.exe` 中运行：

```bat
py -3.14 -m venv .venv
.venv\Scripts\activate
python -m pip install -U pip
python -m pip install --only-binary=:all: -r requirements.txt
```

如果你使用 PowerShell：

```powershell
py -3.14 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -U pip
python -m pip install --only-binary=:all: -r requirements.txt
```

#### 3. 初始化配置

在 Windows `cmd.exe` 中运行：

```bat
copy config.yaml.example config.yaml
```

在 PowerShell 中运行：

```powershell
Copy-Item config.yaml.example config.yaml
```

编辑 `config.yaml`，将 `api_key` 替换为你的实际密钥。支持任何 OpenAI 兼容接口（OpenAI、DeepSeek、本地 LM Studio 等）。也可以启动程序后在界面内管理 LLM 配置。

#### 4. 下载 ASR 模型

默认只下载日常推荐的 `sensevoice-small`：

```bat
python scripts\download_models.py
```

下载其他模型：

```bat
python scripts\download_models.py --model paraformer-large
python scripts\download_models.py --model sensevoice-large
python scripts\download_models.py --all
```

指定下载源：

```bat
python scripts\download_models.py --model sensevoice-small --source official
python scripts\download_models.py --model sensevoice-small --source hf-mirror
```

`auto` 是默认下载源策略，会在官方源和镜像源之间做简单选择。

#### 5. 验证 ASR（可选）

```bat
python src\verify_pipeline.py --no-llm
```

#### 6. 运行

```bat
python src\main.py
```

### 卸载

如果要完全移除项目，双击：

```bat
uninstall.bat
```

它会删除：

- 源码、README、脚本等项目文件
- `.venv`
- `models`
- `run.bat`、`run_debug.bat`、快捷方式
- 运行时生成内容

卸载时可选择保留 `config.yaml`、`corpus\corrections.json`、`corpus\blacklist.json`。

> 旧的 `scripts/download_models.sh` 和 `scripts/verify_asr.sh` 仍保留给 Git Bash / WSL / Linux 用户。普通 Windows 部署不需要安装 WSL，也不需要运行 `bash`。

## 使用方法

### 录音模式

- **按住录音 (push-to-talk)**：按住热键说话，松开后自动转写（默认）
- **Toggle 模式**：按一下开始录音，再按一下结束

在「热键设置」面板中切换模式。

### 默认热键

| 热键 | 档位 | 效果 |
|------|------|------|
| Alt+Shift+1 | Clean | 删除填充词、修正同音字、加标点，不改句式 |
| Alt+Shift+2 | Refine | 口语→书面，保留原意，修复识别错误 |
| Alt+Shift+3 | Rewrite | 理解意图后重新组织，生成结构化文本 |

热键可在界面内自定义修改（支持任意组合键）。

### 配置

`config.yaml` 管理所有配置，也可通过界面修改：

- **ASR 模型**：顶部下拉框切换，未下载的模型会提示自动下载
- **LLM Provider**：支持多个配置并存，界面内新建/编辑/删除/测试连通
- **录音设备**：`recording.device` 指定音频输入设备编号，`null` 为系统默认
- **窗口置顶**：`ui.always_on_top` 控制悬浮窗是否始终在最前

## 项目结构

```
VentiVoice/
├── src/
│   ├── main.py              # 主程序入口 (UI + 热键 + 流程编排)
│   ├── asr.py               # ASR 引擎抽象层 (sherpa-onnx)
│   ├── llm.py               # LLM 三档润色 + 术语自动发现
│   ├── recorder.py          # sounddevice 录音，输出 float32 numpy
│   ├── corpus.py            # 个人词库管理 (JSON + 黑名单)
│   ├── config.py            # YAML 配置加载/保存
│   └── verify_pipeline.py   # 命令行验证脚本 (录音→ASR→LLM)
├── prompts/
│   ├── tier1_clean.txt      # 档位一提示词
│   ├── tier2_refine.txt     # 档位二提示词
│   └── tier3_rewrite.txt    # 档位三提示词
├── models/                  # ASR 模型文件 (需下载)
├── corpus/                  # 用户词库数据 (运行时生成)
│   ├── corrections.json     # 词库主数据
│   └── blacklist.json       # 黑名单
├── scripts/
│   ├── install.ps1          # Windows 安装器
│   ├── uninstall.ps1        # 卸载器
│   └── download_models.py   # 模型下载 (支持测速选源)
├── config.yaml.example      # 配置模板
├── requirements.txt         # Python 依赖
├── install.bat              # 安装入口
├── uninstall.bat            # 卸载入口
└── logo.ico                 # 应用图标
```

## 技术栈

| 层 | 技术 |
|----|------|
| ASR 推理 | [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) — SenseVoice / Paraformer, ONNX Runtime |
| LLM 润色 | 任意 OpenAI 兼容 API (httpx) |
| 音频采集 | sounddevice (PortAudio) |
| 全局热键 | pynput |
| 桌面 UI | tkinter + pystray (系统托盘) |
| 剪贴板 | pyperclip |
| 配置 | PyYAML |

## License

MIT
