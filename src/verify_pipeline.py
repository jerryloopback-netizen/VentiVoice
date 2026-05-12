"""Phase 0 验证脚本 - 命令行最小闭环

用法:
  python src/verify_pipeline.py                    # 录音 5 秒后转写
  python src/verify_pipeline.py --wav test.wav     # 用已有 WAV 文件
  python src/verify_pipeline.py --tier 2           # 指定 LLM 档位 (1/2/3)
  python src/verify_pipeline.py --model large-v3   # 指定 ASR 模型
  python src/verify_pipeline.py --no-llm           # 只跑 ASR，跳过 LLM
"""

from __future__ import annotations

import argparse
import sys
import time
import wave
from pathlib import Path

import numpy as np

# 把 src 目录加入路径
sys.path.insert(0, str(Path(__file__).parent))

from config import load_config
from asr import build_engine
from llm import LLMProcessor
from recorder import Recorder


def record_audio(duration: float, sample_rate: int = 16000) -> np.ndarray:
    print(f">>> 录音开始 ({duration:.0f}秒)，请说话...")
    rec = Recorder(sample_rate=sample_rate)
    rec.start()
    time.sleep(duration)
    audio = rec.stop()
    print(">>> 录音结束")
    return audio


def load_wav(path: str) -> tuple[np.ndarray, int]:
    with wave.open(path, "rb") as wf:
        sr = wf.getframerate()
        samples = wf.readframes(wf.getnframes())
    audio = np.frombuffer(samples, dtype=np.int16).astype(np.float32) / 32768.0
    return audio, sr


def main():
    parser = argparse.ArgumentParser(description="VentiVoice 管道验证")
    parser.add_argument("--wav", help="使用已有 WAV 文件而非录音")
    parser.add_argument("--duration", type=float, default=5.0, help="录音时长 (秒)")
    parser.add_argument("--model", default=None, help="ASR 模型名称")
    parser.add_argument("--tier", type=int, default=1, choices=[1, 2, 3], help="LLM 档位")
    parser.add_argument("--no-llm", action="store_true", help="跳过 LLM 处理")
    args = parser.parse_args()

    config = load_config()
    model_name = args.model or config["asr"]["default_model"]

    # 1. 获取音频
    if args.wav:
        print(f"[加载] {args.wav}")
        audio, sr = load_wav(args.wav)
    else:
        audio = record_audio(args.duration)
        sr = config["recording"]["sample_rate"]

    if len(audio) == 0:
        print("[错误] 音频为空")
        sys.exit(1)

    print(f"[音频] {len(audio)/sr:.1f}s, {sr}Hz, {len(audio)} 采样点")

    # 2. ASR
    print(f"\n[ASR] 使用模型: {model_name}")
    t0 = time.time()
    engine = build_engine(config, model_name)
    raw_text = engine.transcribe(audio, sr)
    asr_time = time.time() - t0

    print(f"[ASR 耗时] {asr_time:.2f}s")
    print(f"[ASR 原始输出]\n{raw_text}\n")

    if args.no_llm or not raw_text.strip():
        return

    # 3. LLM
    providers = config["llm"].get("providers", {})
    default_provider = config["llm"].get("default_provider", "")
    if not providers or default_provider not in providers:
        print("[跳过 LLM] config.yaml 中未配置有效的 LLM provider")
        return

    print(f"[LLM] 档位 {args.tier} 处理中...")
    t0 = time.time()
    processor = LLMProcessor(config)
    result = processor.process(raw_text, args.tier)
    llm_time = time.time() - t0

    print(f"[LLM 耗时] {llm_time:.2f}s")
    print(f"[LLM 输出 (档位{args.tier})]\n{result}\n")


if __name__ == "__main__":
    main()
