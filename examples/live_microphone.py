"""示例：麦克风实时识别，Ctrl+C 结束并保存字幕。

需要可选依赖：``uv sync --extra mic``

运行::

    uv run python examples/live_microphone.py
    uv run python examples/live_microphone.py yue
"""

from __future__ import annotations

import sys
from pathlib import Path

from voice_small_asr import ASRConfig, StreamingTranscriber, TranscriptionResult, audio, subtitles


def main(argv: list[str]) -> int:
    language = argv[1] if len(argv) > 1 else "auto"

    # partial_interval=0.5：每 0.5 秒刷新一次"这句话说到哪了"的临时结果。
    config = ASRConfig(language=language, partial_interval=0.5)
    streamer = StreamingTranscriber(config)

    finals = []
    print("开始说话（Ctrl+C 结束）…", file=sys.stderr)
    try:
        for chunk in audio.iter_microphone():
            for segment in streamer.accept(chunk):
                if segment.is_final:
                    # 定稿：换行留存
                    print(f"\r\x1b[K[{segment.start:7.2f}s] {segment.text}")
                    finals.append(segment)
                else:
                    # 临时：原地刷新，稍后被定稿结果覆盖
                    print(f"\r\x1b[K[{segment.start:7.2f}s] {segment.text} …", end="", flush=True)
    except KeyboardInterrupt:
        print("\r\x1b[K", end="")

    finals.extend(streamer.flush())
    if not finals:
        print("没有识别到语音。")
        return 0

    result = TranscriptionResult(segments=finals, duration=finals[-1].end, language=language)
    written = subtitles.write(result, Path("outputs") / "live.srt")
    print(f"\n共 {len(finals)} 句，已保存 {written}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
