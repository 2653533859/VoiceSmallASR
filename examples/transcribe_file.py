"""示例：转写音频文件，导出 SRT / VTT / JSON。

运行::

    uv run python examples/transcribe_file.py data/samples/yue.wav yue
    uv run python examples/transcribe_file.py meeting.mp3
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

from voice_small_asr import ASRConfig, Transcriber, subtitles


def main(argv: list[str]) -> int:
    source = Path(argv[1]) if len(argv) > 1 else Path("data/samples/yue.wav")
    language = argv[2] if len(argv) > 2 else "auto"
    if not source.is_file():
        print(f"找不到音频：{source}")
        return 1

    # 模型加载约一到两秒；反复识别时请复用同一个 Transcriber 实例。
    transcriber = Transcriber(ASRConfig(language=language))

    started = time.perf_counter()
    result = transcriber.transcribe(source)
    elapsed = time.perf_counter() - started

    print(
        f"音频 {result.duration:.2f}s，耗时 {elapsed:.2f}s，"
        f"实时率 RTF={elapsed / max(result.duration, 1e-9):.3f}"
    )
    print(f"整段文本：{result.text}\n")

    for segment in result:
        print(
            f"#{segment.index} [{segment.start:6.2f} → {segment.end:6.2f}] "
            f"({segment.language}) {segment.text}"
        )
        head = ", ".join(f"{w.text.strip()}@{w.start:.2f}" for w in segment.words[:8])
        if head:
            print(f"      token 时间戳：{head} …")

    out_dir = Path("outputs")
    for suffix in ("srt", "vtt", "json"):
        written = subtitles.write(result, out_dir / f"{source.stem}.{suffix}")
        print(f"已导出 {written}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
