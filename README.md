# VentiVoice

一个运行在本地的语音转文字桌面工具，专为中文场景优化。

在日常工作中，打字往往是思考到输出之间最大的瓶颈——你脑子里已经想好了要写什么，但手指跟不上。VentiVoice 让你按下热键直接说话，松开后几秒内就能得到一段经过 AI 润色的书面文本，自动复制到剪贴板，直接粘贴到任何地方。

核心流程：**热键录音 → 本地 ASR 转写 → LLM 润色 → 剪贴板输出**。ASR 完全在本地运行（无需联网），LLM 润色通过 API 调用（支持任意 OpenAI 兼容接口）。整个流程通常在 3-5 秒内完成，适合写消息、记笔记、写邮件、口述文档等场景。

## 为什么选择这些 ASR 模型

本项目在开发过程中测试了多种 ASR 方案，包括口碑极好的 Whisper 系列（tiny / large-v3-turbo / large-v3）。但实测发现，Whisper 在个人电脑本地部署、面对中文语音时存在明显问题：

- **中文识别准确率不理想**：Whisper 是多语言通用模型，中文并非其强项，尤其在口语化、带方言色彩的日常表达中错误率较高
- **推理速度慢**：large-v3 在无 GPU 加速时转写 5 秒音频需要 10-30 秒，即使有 Vulkan 加速也远不如专用中文模型
- **部署复杂**：需要编译 whisper.cpp、配置 Vulkan SDK、处理 DLL 依赖，门槛较高

最终选定的 3 个模型均基于 sherpa-onnx 运行时，开箱即用：

| 模型 | 参数量 | 特点 | 适用场景 |
|------|--------|------|----------|
| **SenseVoice-Small** | 234M | 非自回归，极快（5 秒音频 < 0.5s），中/英/日/韩/粤 | 日常使用首选，速度优先 |
| **SenseVoice-Large** | ~1.6B | 自回归，更高准确率（AISHELL-1 CER 2.09%），50+ 语言 | 需要更高精度时切换 |
| **Paraformer-Large** | ~220M | 阿里达摩院中文专用模型，非自回归 | 纯中文场景的备选方案 |

三者均使用 int8 量化，单个模型约 220-230MB，总共约 700MB，对磁盘和内存友好。

## 功能

- 全局热键录音（push-to-talk 或 toggle 模式）
- 三档 LLM 润色：Clean（最低限度清理）/ Refine（书面化整理）/ Rewrite（理解重写）
- 多 ASR 模型切换：SenseVoice-Small / SenseVoice-Large / Paraformer-Large
- 多 LLM 配置管理：支持任意 OpenAI 兼容 API，可在界面内新建/编辑/测试
- 个人语料库纠错：自动学习并修正常见识别错误
- 系统托盘常驻，深色主题 UI

## 快速开始

### 环境要求

- Python 3.10+
- Windows 10/11
- 麦克风

### 1. 克隆仓库

```bash
git clone https://github.com/jerryloopback-netizen/VentiVoice.git
cd VentiVoice
```

### 2. 安装依赖

```bash
pip install -r requirements.txt
```

### 3. 下载 ASR 模型

模型文件较大（约 700MB），不包含在仓库中，需单独下载：

```bash
bash scripts/download_models.sh
```

如果网络不佳，也可以手动下载模型并放入 `models/` 目录：

| 模型 | 来源 | 目录名 |
|------|------|--------|
| SenseVoice-Small | [sherpa-onnx releases](https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models) | `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/` |
| SenseVoice-Large | [HuggingFace](https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09) | `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09/` |
| Paraformer-Large | [sherpa-onnx releases](https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models) | `sherpa-onnx-paraformer-zh-2024-03-09/` |

每个模型目录下至少需要 `model.int8.onnx` 和 `tokens.txt` 两个文件。

### 4. 配置 LLM API

复制配置模板并填入你的 API 信息：

```bash
cp config.yaml.example config.yaml
```

编辑 `config.yaml`，将 `api_key` 替换为你的实际密钥。支持任何 OpenAI 兼容接口（OpenAI、DeepSeek、本地 LM Studio 等）。

也可以启动程序后在界面内管理 LLM 配置。

### 5. 验证 ASR（可选）

```bash
bash scripts/verify_asr.sh
```

### 6. 运行

```bash
python src/main.py
```

或双击运行 `create_shortcut.bat` 生成桌面快捷方式后使用。

## 使用方法

### 录音模式

- **按住录音 (push-to-talk)**：按住热键说话，松开后自动转写
- **Toggle 模式**：按一下开始录音，再按一下结束

可在界面底部「热键设置」区域切换模式。

### 默认热键

| 热键 | 功能 |
|------|------|
| Alt+Shift+1 (!) | 档位一: Clean（最低限度清理） |
| Alt+Shift+2 (@) | 档位二: Refine（书面化整理） |
| Alt+Shift+3 (#) | 档位三: Rewrite（理解重写） |
| Escape | 取消当前操作 |

热键可在界面内自定义修改。

### 语料库纠错

在转写结果区域下方的「纠错」面板中，输入错误词和正确词并提交。程序会自动记住并在后续转写中自动替换。

## 项目结构

```
VentiVoice/
├── src/
│   ├── main.py          # 主程序 (UI + 热键 + 流程控制)
│   ├── asr.py           # ASR 引擎抽象层 (sherpa-onnx)
│   ├── llm.py           # LLM 后处理 (三档润色)
│   ├── recorder.py      # 录音模块
│   ├── corpus.py        # 个人语料库管理
│   └── config.py        # 配置加载/保存
├── prompts/             # LLM 提示词模板
├── models/              # ASR 模型 (需下载，不含在仓库中)
├── corpus/              # 个人语料库数据
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
