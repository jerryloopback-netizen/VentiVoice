#!/bin/bash
# VentiVoice - ASR 验证脚本
# 验证 sherpa-onnx 模型 (SenseVoice / Paraformer) 的转写能力
#
# 用法:
#   bash scripts/verify_asr.sh                    # 录制 5 秒测试音频
#   bash scripts/verify_asr.sh path/to/test.wav   # 使用自定义音频文件

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MODELS_DIR="$PROJECT_DIR/models"
TEST_DIR="$PROJECT_DIR/test_output"

mkdir -p "$TEST_DIR"

# 检查 sherpa-onnx
if ! python -c "import sherpa_onnx" 2>/dev/null; then
    echo "[错误] sherpa-onnx 未安装"
    echo "请运行: pip install sherpa-onnx"
    exit 1
fi

# 测试音频
TEST_WAV="$1"
if [ -z "$TEST_WAV" ]; then
    echo "=== 录制测试音频 (5秒) ==="
    echo "请在录音开始后说一段中文..."
    echo ""

    TEST_WAV="$TEST_DIR/test_recording.wav"
    python -c "
import sounddevice as sd
import numpy as np
import wave

DURATION = 5
SAMPLE_RATE = 16000

print('>>> 录音开始 (5秒)，请说话...')
audio = sd.rec(int(DURATION * SAMPLE_RATE), samplerate=SAMPLE_RATE, channels=1, dtype='int16')
sd.wait()
print('>>> 录音结束')

with wave.open('$TEST_WAV', 'wb') as wf:
    wf.setnchannels(1)
    wf.setsampwidth(2)
    wf.setframerate(SAMPLE_RATE)
    wf.writeframes(audio.tobytes())

print(f'>>> 已保存: $TEST_WAV')
" || {
    echo "[错误] 录音失败，请确保已安装 sounddevice"
    exit 1
}
fi

if [ ! -f "$TEST_WAV" ]; then
    echo "[错误] 测试音频不存在: $TEST_WAV"
    exit 1
fi

echo ""
echo "=== 测试音频: $TEST_WAV ==="
echo ""

# 通用 sherpa-onnx 测试函数
test_model() {
    local name="$1"
    local model_type="$2"
    local model_dir="$3"

    if [ ! -d "$model_dir" ]; then
        echo "[跳过] $name 模型未下载"
        return
    fi

    echo "--- $name ---"
    python -c "
import sherpa_onnx
import wave
import time
import numpy as np

model_dir = '$model_dir'
model_type = '$model_type'

if model_type == 'sense_voice':
    recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
        model=model_dir + '/model.int8.onnx',
        tokens=model_dir + '/tokens.txt',
        use_itn=True,
        language='zh',
        num_threads=4,
    )
elif model_type == 'paraformer':
    recognizer = sherpa_onnx.OfflineRecognizer.from_paraformer(
        paraformer=model_dir + '/model.int8.onnx',
        tokens=model_dir + '/tokens.txt',
        num_threads=4,
    )

with wave.open('$TEST_WAV', 'rb') as wf:
    assert wf.getframerate() == 16000, f'需要 16kHz，当前 {wf.getframerate()}Hz'
    samples = wf.readframes(wf.getnframes())

audio = np.frombuffer(samples, dtype=np.int16).astype(np.float32) / 32768.0

stream = recognizer.create_stream()
stream.accept_waveform(16000, audio.tolist())

t0 = time.time()
recognizer.decode_stream(stream)
elapsed = time.time() - t0

result = stream.result.text
print(f'  结果: {result}')
print(f'  耗时: {elapsed:.2f}s')
"
    echo ""
}

# 测试所有已安装的模型
test_model "SenseVoice-Small" "sense_voice" \
    "$MODELS_DIR/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"

test_model "SenseVoice-Large" "sense_voice" \
    "$MODELS_DIR/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09"

test_model "Paraformer-Large" "paraformer" \
    "$MODELS_DIR/sherpa-onnx-paraformer-zh-2024-03-09"

echo "=========================================="
echo "  验证完成 - 请对比各模型的转写结果"
echo "=========================================="
