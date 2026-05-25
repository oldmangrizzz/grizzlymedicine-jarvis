#!/bin/bash
source /Users/rbhanson/research/jarvis/.venv/bin/activate
cd "$(dirname "$0")/.."
mkdir -p onnx_models
python tools/export_xtts_to_onnx.py \
    --out-dir onnx_models \
    --opset 20 \
    --validate \
    2>&1 | tee onnx_models/export_log.txt
