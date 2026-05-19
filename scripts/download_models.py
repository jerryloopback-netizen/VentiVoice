"""Download VentiVoice ASR models.

This script is intentionally cross-platform so Windows users do not need Bash,
WSL, Git Bash, or Unix utilities.
"""

from __future__ import annotations

import argparse
import contextlib
import os
import shutil
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable
from urllib.error import URLError
from urllib.request import Request, urlopen


PROJECT_DIR = Path(__file__).resolve().parent.parent
MODELS_DIR = PROJECT_DIR / "models"

def hf_url(repo: str, filename: str, mirror: bool = False) -> str:
    base = "https://hf-mirror.com" if mirror else "https://huggingface.co"
    return f"{base}/{repo}/resolve/main/{filename}"


@dataclass(frozen=True)
class FileSpec:
    path: str
    urls: tuple[str, ...]


@dataclass(frozen=True)
class ModelSpec:
    model_id: str
    name: str
    directory: str
    required_files: tuple[str, ...]
    files: tuple[FileSpec, ...] = ()


MODELS: dict[str, ModelSpec] = {
    "sensevoice-small": ModelSpec(
        model_id="sensevoice-small",
        name="SenseVoice-Small",
        directory="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17",
        required_files=("model.int8.onnx", "tokens.txt"),
        files=(
            FileSpec(
                path="model.int8.onnx",
                urls=(
                    hf_url("csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17", "model.int8.onnx"),
                    hf_url("csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17", "model.int8.onnx", mirror=True),
                ),
            ),
            FileSpec(
                path="tokens.txt",
                urls=(
                    hf_url("csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17", "tokens.txt"),
                    hf_url("csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17", "tokens.txt", mirror=True),
                ),
            ),
        ),
    ),
    "sensevoice-large": ModelSpec(
        model_id="sensevoice-large",
        name="SenseVoice-Large",
        directory="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09",
        required_files=("model.int8.onnx", "tokens.txt"),
        files=(
            FileSpec(
                path="model.int8.onnx",
                urls=(
                    hf_url("csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09", "model.int8.onnx"),
                    hf_url("csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09", "model.int8.onnx", mirror=True),
                ),
            ),
            FileSpec(
                path="tokens.txt",
                urls=(
                    hf_url("csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09", "tokens.txt"),
                    hf_url("csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09", "tokens.txt", mirror=True),
                ),
            ),
        ),
    ),
    "paraformer-large": ModelSpec(
        model_id="paraformer-large",
        name="Paraformer-Large",
        directory="sherpa-onnx-paraformer-zh-2024-03-09",
        required_files=("model.int8.onnx", "tokens.txt"),
        files=(
            FileSpec(
                path="model.int8.onnx",
                urls=(
                    hf_url("csukuangfj/sherpa-onnx-paraformer-zh-2024-03-09", "model.int8.onnx"),
                    hf_url("csukuangfj/sherpa-onnx-paraformer-zh-2024-03-09", "model.int8.onnx", mirror=True),
                ),
            ),
            FileSpec(
                path="tokens.txt",
                urls=(
                    hf_url("csukuangfj/sherpa-onnx-paraformer-zh-2024-03-09", "tokens.txt"),
                    hf_url("csukuangfj/sherpa-onnx-paraformer-zh-2024-03-09", "tokens.txt", mirror=True),
                ),
            ),
        ),
    ),
}


def model_dir(spec: ModelSpec) -> Path:
    return MODELS_DIR / spec.directory


def is_installed(spec: ModelSpec) -> bool:
    target = model_dir(spec)
    return all((target / file).is_file() for file in spec.required_files)


def human_size(num_bytes: int) -> str:
    size = float(num_bytes)
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024 or unit == "GB":
            return f"{size:.1f}{unit}"
        size /= 1024
    return f"{size:.1f}GB"


def choose_url(urls: Iterable[str], source: str) -> str:
    candidates = list(urls)
    if not candidates:
        raise ValueError("No download URLs configured")

    if source == "official":
        return candidates[0]
    if source == "hf-mirror":
        for url in candidates:
            if "hf-mirror.com" in url:
                return url
        print("[提示] 该模型没有配置 hf-mirror 镜像，使用官方源。")
        return candidates[0]

    results: list[tuple[float, str]] = []
    for url in candidates:
        elapsed = probe_url(url)
        if elapsed is None:
            print(f"[测速] 不可用: {url}")
            continue
        print(f"[测速] {elapsed:.2f}s  {url}")
        results.append((elapsed, url))

    if results:
        return sorted(results, key=lambda item: item[0])[0][1]

    print("[提示] 所有测速失败，按配置顺序尝试下载。")
    return candidates[0]


def probe_url(url: str, timeout: float = 8.0) -> float | None:
    start = time.perf_counter()
    try:
        request = Request(url, method="HEAD", headers={"User-Agent": "VentiVoice/1.0"})
        with contextlib.closing(urlopen(request, timeout=timeout)) as response:
            if 200 <= response.status < 400:
                return time.perf_counter() - start
    except Exception:
        pass

    try:
        request = Request(
            url,
            headers={"User-Agent": "VentiVoice/1.0", "Range": "bytes=0-4095"},
        )
        with contextlib.closing(urlopen(request, timeout=timeout)) as response:
            if 200 <= response.status < 400:
                response.read(4096)
                return time.perf_counter() - start
    except Exception:
        return None
    return None


def download_file(urls: Iterable[str], dest: Path, source: str) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    last_error: Exception | None = None
    ordered = list(urls)
    first_url = choose_url(ordered, source)
    ordered = [first_url] + [url for url in ordered if url != first_url]

    for url in ordered:
        part = dest.with_suffix(dest.suffix + ".part")
        try:
            print(f"[下载] {dest.name}")
            print(f"       {url}")
            request = Request(url, headers={"User-Agent": "VentiVoice/1.0"})
            with contextlib.closing(urlopen(request, timeout=30.0)) as response:
                total_header = response.headers.get("Content-Length")
                total = int(total_header) if total_header else None
                downloaded = 0
                with part.open("wb") as file:
                    while True:
                        chunk = response.read(1024 * 1024)
                        if not chunk:
                            break
                        file.write(chunk)
                        downloaded += len(chunk)
                        if total:
                            percent = downloaded / total * 100
                            print(
                                f"\r       {percent:5.1f}% ({human_size(downloaded)}/{human_size(total)})",
                                end="",
                            )
                        else:
                            print(f"\r       {human_size(downloaded)}", end="")
                print()
            part.replace(dest)
            return
        except (OSError, URLError, TimeoutError) as exc:
            last_error = exc
            print(f"[失败] {url}: {exc}")
            with contextlib.suppress(OSError):
                part.unlink()

    raise RuntimeError(f"下载失败: {dest}") from last_error


def install_model(model_id: str, source: str) -> None:
    spec = MODELS[model_id]
    target = model_dir(spec)

    if is_installed(spec):
        print(f"[跳过] {spec.name} 已安装: {target}")
        return

    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    print(f"=== 下载 {spec.name} ===")
    print(f"模型目录: {target}")

    tmp_dir = Path(tempfile.mkdtemp(prefix=f"{spec.model_id}.", dir=MODELS_DIR))
    try:
        for file_spec in spec.files:
            download_file(file_spec.urls, tmp_dir / file_spec.path, source)
        if target.exists():
            shutil.rmtree(target)
        tmp_dir.replace(target)
    except Exception:
        shutil.rmtree(tmp_dir, ignore_errors=True)
        raise

    if not is_installed(spec):
        missing = [file for file in spec.required_files if not (target / file).is_file()]
        raise RuntimeError(f"{spec.name} 下载不完整，缺少: {', '.join(missing)}")

    print(f"[OK] {spec.name} 就绪")


def list_models() -> None:
    print("可用模型:")
    for spec in MODELS.values():
        status = "已安装" if is_installed(spec) else "未下载"
        print(f"  {spec.model_id:<18} {status:<6} {spec.name}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="下载 VentiVoice ASR 模型")
    parser.add_argument(
        "--model",
        choices=tuple(MODELS),
        default="sensevoice-small",
        help="要下载的模型，默认只下载 sensevoice-small",
    )
    parser.add_argument("--all", action="store_true", help="下载全部模型")
    parser.add_argument("--list", action="store_true", help="列出模型安装状态后退出")
    parser.add_argument(
        "--source",
        choices=("auto", "official", "hf-mirror"),
        default="auto",
        help="下载源。auto 会对同一文件的可用源做简单测速",
    )
    return parser.parse_args()


def main() -> int:
    if os.name == "nt":
        with contextlib.suppress(Exception):
            sys.stdout.reconfigure(encoding="utf-8")
            sys.stderr.reconfigure(encoding="utf-8")

    args = parse_args()

    if args.list:
        list_models()
        return 0

    selected = list(MODELS) if args.all else [args.model]
    try:
        for model_id in selected:
            install_model(model_id, args.source)
            print()
        list_models()
    except Exception as exc:
        print(f"[错误] {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
