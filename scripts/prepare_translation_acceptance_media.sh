#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "用法：$0 <包含 en.wav/ja.wav 的目录> [输出目录]" >&2
  exit 2
fi

WAV_DIR="$1"
OUTPUT_DIR="${2:-$WAV_DIR}"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "找不到 ffmpeg；请先安装 ffmpeg" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
for language in en ja; do
  input="$WAV_DIR/$language.wav"
  output="$OUTPUT_DIR/$language.mp4"
  if [[ ! -f "$input" ]]; then
    echo "缺少输入素材：$input" >&2
    exit 1
  fi
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i color=c=black:s=640x360:r=30:d=8 \
    -i "$input" \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 128k -shortest "$output"
done

echo "已生成：$OUTPUT_DIR/en.mp4"
echo "已生成：$OUTPUT_DIR/ja.mp4"
