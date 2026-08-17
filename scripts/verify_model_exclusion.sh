#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-}"
if [[ -z "$ROOT_DIR" || ! -d "$ROOT_DIR" ]]; then
  echo "用法：$0 <待检查的应用目录>" >&2
  exit 2
fi

model_files="$(find "$ROOT_DIR" -type f \( \
  -iname '*.onnx' -o \
  -iname 'tokens.txt' -o \
  -iname '*.tar.bz2' \
\) -print)"

if [[ -n "$model_files" ]]; then
  echo "应用产物包含不应打包的模型文件：" >&2
  printf '%s\n' "$model_files" >&2
  exit 1
fi

echo "模型排除检查通过：$ROOT_DIR"
