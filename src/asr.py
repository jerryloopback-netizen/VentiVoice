"""ASR 引擎抽象层

使用 sherpa-onnx 推理 SenseVoice / Paraformer 模型。
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from pathlib import Path

import numpy as np


class ASREngine(ABC):
    @abstractmethod
    def transcribe(self, audio: np.ndarray, sample_rate: int = 16000) -> str:
        ...


class SherpaOnnxEngine(ASREngine):
    """使用 sherpa-onnx 库推理 (SenseVoice 或 Paraformer)"""

    def __init__(self, model_type: str, model_path: str, tokens_path: str,
                 language: str = "zh", use_itn: bool = True, num_threads: int = 4):
        try:
            import sherpa_onnx
        except ImportError:
            raise ImportError("请先安装 sherpa-onnx: pip install sherpa-onnx")

        self._sherpa = sherpa_onnx
        self.model_type = model_type

        if model_type == "sense_voice":
            self.recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
                model=model_path,
                tokens=tokens_path,
                use_itn=use_itn,
                language=language,
                num_threads=num_threads,
            )
        elif model_type == "paraformer":
            self.recognizer = sherpa_onnx.OfflineRecognizer.from_paraformer(
                paraformer=model_path,
                tokens=tokens_path,
                num_threads=num_threads,
            )
        else:
            raise ValueError(f"未知模型类型: {model_type}")

    def transcribe(self, audio: np.ndarray, sample_rate: int = 16000) -> str:
        stream = self.recognizer.create_stream()
        stream.accept_waveform(sample_rate, audio.tolist())
        self.recognizer.decode_stream(stream)
        return stream.result.text.strip()


def build_engine(config: dict, model_name: str) -> ASREngine:
    asr_cfg = config["asr"]
    project_root = Path(__file__).parent.parent

    def resolve(p: str) -> str:
        path = Path(p)
        if not path.is_absolute():
            path = project_root / path
        return str(path.resolve())

    sherpa_models = asr_cfg.get("sherpa_onnx", {}).get("models", {})
    if model_name in sherpa_models:
        m = sherpa_models[model_name]
        return SherpaOnnxEngine(
            model_type=m["type"],
            model_path=resolve(m["model_path"]),
            tokens_path=resolve(m["tokens_path"]),
            language=m.get("language", "zh"),
            use_itn=m.get("use_itn", True),
        )

    raise ValueError(f"未知模型: {model_name}。可用: {list(sherpa_models)}")
