"""录音模块

push-to-talk 模式: 按住热键录音，松开停止。
返回 float32 单声道 16kHz numpy 数组。
"""

from __future__ import annotations

import threading
from typing import Optional

import numpy as np
import sounddevice as sd


class Recorder:
    def __init__(self, sample_rate: int = 16000, device: Optional[int] = None):
        self.sample_rate = sample_rate
        self.device = device
        self._chunks: list[np.ndarray] = []
        self._recording = False
        self._lock = threading.Lock()

    def start(self) -> None:
        with self._lock:
            if self._recording:
                return
            self._chunks = []
            self._recording = True

        self._stream = sd.InputStream(
            samplerate=self.sample_rate,
            channels=1,
            dtype="float32",
            device=self.device,
            callback=self._callback,
        )
        self._stream.start()

    def stop(self) -> np.ndarray:
        with self._lock:
            if not self._recording:
                return np.array([], dtype=np.float32)
            self._recording = False

        self._stream.stop()
        self._stream.close()

        if not self._chunks:
            return np.array([], dtype=np.float32)

        audio = np.concatenate(self._chunks, axis=0).flatten()
        return audio

    def _callback(self, indata: np.ndarray, frames: int, time, status) -> None:
        with self._lock:
            if self._recording:
                self._chunks.append(indata.copy())
