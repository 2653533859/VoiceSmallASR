"""示例：把识别能力集成进别的项目（服务端 / 后台任务）。

要点：

1. 进程启动时构造一次 :class:`Transcriber`，之后复用 —— 模型加载才是耗时项；
2. 生产环境用 ``allow_download=False``，让缺模型立刻失败而不是偷偷联网；
3. sherpa-onnx 的识别器可以被多线程共享，但为稳妥起见这里加锁串行化，
   需要更高并发时改成"每线程/每进程一个 ASRService"；
4. 对外只暴露 JSON 友好的 dict，不泄漏任何 sherpa-onnx 类型。

运行::

    uv run python examples/service_integration.py data/samples/zh.wav
"""

from __future__ import annotations

import sys
import threading
from pathlib import Path
from typing import Any

from voice_small_asr import ASRConfig, Transcriber, subtitles


class ASRService:
    """可长期驻留的转写服务。"""

    def __init__(
        self,
        *,
        language: str = "auto",
        model_dir: Path | None = None,
        allow_download: bool = False,
    ) -> None:
        config = ASRConfig(language=language, model_dir=model_dir)
        self._transcriber = Transcriber(config, allow_download=allow_download)
        self._lock = threading.Lock()

    def transcribe(self, source: str | Path) -> dict[str, Any]:
        """转写一个音频文件，返回可直接 JSON 序列化的结果。"""
        with self._lock:
            result = self._transcriber.transcribe(source)
        return result.to_dict()

    def to_subtitle(self, source: str | Path, fmt: str = "srt") -> str:
        """转写并直接返回字幕文本，适合 HTTP 响应体。"""
        with self._lock:
            result = self._transcriber.transcribe(source)
        return subtitles.render(result, fmt)


def main(argv: list[str]) -> int:
    source = Path(argv[1]) if len(argv) > 1 else Path("data/samples/zh.wav")
    if not source.is_file():
        print(f"找不到音频：{source}")
        return 1

    # 真实服务里这一行发生在启动阶段，不在请求路径上。
    service = ASRService(language="auto")

    payload = service.transcribe(source)
    print(f"语言：{payload['language']}  时长：{payload['duration']}s")
    print(f"文本：{payload['text']}")
    print(f"段数：{len(payload['segments'])}")
    print("\n--- SRT ---")
    print(service.to_subtitle(source, "srt"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
