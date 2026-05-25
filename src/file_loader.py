"""音频文件加载模块

将本地音频文件 (.mp3/.wav/.flac/.ogg/.m4a/.wma) 转换为
16kHz 单声道 float32 numpy 数组，与 recorder.py 输出格式一致。
"""

from __future__ import annotations

from pathlib import Path

import numpy as np


def _find_ffmpeg() -> str | None:
    """查找 ffmpeg 可执行文件路径：优先项目 tools/ 目录，其次系统 PATH"""
    import shutil

    project_tools = Path(__file__).parent.parent / "tools" / "ffmpeg.exe"
    if project_tools.is_file():
        return str(project_tools)

    return shutil.which("ffmpeg")


def load_audio_file(path: str, target_sr: int = 16000) -> np.ndarray:
    """加载音频文件并转换为 float32 numpy 数组

    Parameters
    ----------
    path : str
        音频文件路径
    target_sr : int
        目标采样率，默认 16000

    Returns
    -------
    np.ndarray
        float32 单声道音频数组，值域 [-1.0, 1.0]

    Raises
    ------
    FileNotFoundError
        文件不存在
    RuntimeError
        pydub 或 ffmpeg 不可用
    """
    file_path = Path(path)
    if not file_path.is_file():
        raise FileNotFoundError(f"音频文件不存在: {path}")

    try:
        from pydub import AudioSegment
    except ImportError:
        raise RuntimeError("pydub 未安装。请运行: pip install pydub")

    ffmpeg_path = _find_ffmpeg()
    if ffmpeg_path:
        AudioSegment.converter = ffmpeg_path

    try:
        audio = AudioSegment.from_file(str(file_path))
    except Exception as e:
        if "ffmpeg" in str(e).lower() or "ffprobe" in str(e).lower():
            raise RuntimeError(
                "ffmpeg 未找到。请安装 ffmpeg 或将 ffmpeg.exe 放入项目 tools/ 目录。\n"
                f"原始错误: {e}"
            )
        raise

    audio = audio.set_channels(1)
    audio = audio.set_frame_rate(target_sr)
    audio = audio.set_sample_width(2)  # 16-bit PCM

    samples = np.frombuffer(audio.raw_data, dtype=np.int16)
    samples = samples.astype(np.float32) / 32768.0

    return samples


def get_audio_duration_seconds(path: str) -> float:
    """获取音频文件时长（秒），用于导入前的时长检查"""
    try:
        from pydub import AudioSegment

        ffmpeg_path = _find_ffmpeg()
        if ffmpeg_path:
            AudioSegment.converter = ffmpeg_path

        audio = AudioSegment.from_file(path)
        return len(audio) / 1000.0
    except Exception:
        return 0.0
