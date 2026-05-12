#!/bin/bash
# VentiVoice - 模型下载脚本
# 下载 sherpa-onnx 格式的 ASR 模型 (SenseVoice / Paraformer)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MODELS_DIR="$PROJECT_DIR/models"

mkdir -p "$MODELS_DIR"

echo "=== VentiVoice: 模型下载 ==="
echo "模型目录: $MODELS_DIR"
echo ""

# 通用下载函数
download_and_extract() {
    local url="$1"
    local dirname="$2"
    local target="$MODELS_DIR/$dirname"

    if [ -d "$target" ]; then
        echo "[跳过] $dirname 已存在"
        return
    fi

    local archive="$MODELS_DIR/$(basename "$url")"
    echo "[下载] $dirname ..."
    curl -L --progress-bar -o "$archive" "$url"
    echo "[解压] $dirname ..."
    tar -xf "$archive" -C "$MODELS_DIR"
    rm -f "$archive"
    echo "[OK] $dirname 就绪"
}

SHERPA_BASE="https://github.com/k2-fsa/sherpa-onnx/releases/download"
HF_BASE="https://hf-mirror.com/csukuangfj"

echo "--- Sherpa-ONNX 模型 ---"
echo ""

# 1. SenseVoice-Small (中/英/日/韩/粤, int8, ~228MB)
echo "[1/3] SenseVoice-Small"
download_and_extract \
    "$SHERPA_BASE/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2" \
    "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"

# 2. SenseVoice-Large (中/英/日/韩/粤, int8, ~226MB)
echo ""
echo "[2/3] SenseVoice-Large"
SENSE_LARGE_DIR="$MODELS_DIR/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09"
if [ -d "$SENSE_LARGE_DIR" ]; then
    echo "[跳过] sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09 已存在"
else
    mkdir -p "$SENSE_LARGE_DIR"
    echo "[下载] model.int8.onnx ..."
    curl -L --progress-bar -o "$SENSE_LARGE_DIR/model.int8.onnx" \
        "$HF_BASE/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09/resolve/main/model.int8.onnx"
    echo "[下载] tokens.txt ..."
    curl -L --progress-bar -o "$SENSE_LARGE_DIR/tokens.txt" \
        "$HF_BASE/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09/resolve/main/tokens.txt"
    echo "[OK] SenseVoice-Large 就绪"
fi

# 3. Paraformer-Large (中文, int8, ~220MB)
echo ""
echo "[3/3] Paraformer-Large"
download_and_extract \
    "$SHERPA_BASE/asr-models/sherpa-onnx-paraformer-zh-2024-03-09.tar.bz2" \
    "sherpa-onnx-paraformer-zh-2024-03-09"

echo ""
echo "=== 所有模型下载完成 ==="
echo ""
echo "已下载模型:"
ls -d "$MODELS_DIR"/sherpa-onnx-* 2>/dev/null | while read d; do
    size=$(du -sh "$d" | cut -f1)
    echo "  $(basename "$d") ($size)"
done
echo ""
echo "下一步: 运行 scripts/verify_asr.sh 验证 ASR"
