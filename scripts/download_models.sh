#!/bin/bash
# VentiVoice - 模型下载脚本
# 兼容旧入口，实际逻辑由跨平台 Python 脚本负责。

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
python "$SCRIPT_DIR/download_models.py" "$@"
