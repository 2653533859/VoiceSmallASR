"""流式（准实时）识别。

SenseVoice 本身是非流式模型，这里用 VAD 驱动出流式体验：

* VAD 判定一句话说完 → 产出 ``is_final=True`` 的最终段（时间戳准确，用于字幕）；
* 说话过程中每隔 ``partial_interval`` 秒对"当前这句"重解码一次，
  产出 ``is_final=False`` 的局部段，供 UI 即时上屏，随后被最终段替换。

因此延迟不是逐字级的几十毫秒，而是局部结果约 0.6 秒、
整句定稿约为"句末静音 + 推理时间"。集成方按 ``is_final`` 决定是覆盖还是追加即可。
"""

from __future__ import annotations

import time
from collections.abc import Iterable, Iterator
from pathlib import Path

import numpy as np

from voice_small_asr import audio, models, vad
from voice_small_asr.config import SAMPLE_RATE, ASRConfig
from voice_small_asr.engine import Recognizer
from voice_small_asr.models import ProgressHook
from voice_small_asr.segments import Segment

#: 局部结果所需的最短音频长度（秒），过短的片段识别无意义。
MIN_PARTIAL_SECONDS = 0.35


class StreamingTranscriber:
    """VAD 驱动的流式识别器。

    Example:
        >>> from voice_small_asr import StreamingTranscriber, audio
        >>> st = StreamingTranscriber()
        >>> for chunk in audio.iter_microphone():
        ...     for seg in st.accept(chunk):
        ...         print(seg.text, "" if seg.is_final else "(临时)")
    """

    def __init__(
        self,
        config: ASRConfig | None = None,
        *,
        allow_download: bool = True,
        progress: ProgressHook | None = None,
    ) -> None:
        self.config = config or ASRConfig()
        self.paths = models.ensure(
            self.config.resolved_model_dir,
            allow_download=allow_download,
            progress=progress,
        )
        self.recognizer = Recognizer(self.config, self.paths)
        self._detector = vad.build(self.config.vad, self.paths.vad_model)
        self._final_count = 0
        self._last_partial = 0.0

    @property
    def final_count(self) -> int:
        """已产出的最终段数量。"""
        return self._final_count

    def reset(self) -> None:
        """清空内部状态，开始新一路音频。"""
        self._detector.reset()
        self._final_count = 0
        self._last_partial = 0.0

    def _take_finals(self) -> list[Segment]:
        finals: list[Segment] = []
        for samples, start in vad.drain(self._detector):
            segment = self.recognizer.decode(
                samples, offset=start, is_final=True, index=self._final_count
            )
            if segment.text:
                self._final_count += 1
                finals.append(segment)
            self._last_partial = 0.0
        return finals

    def _make_partial(self) -> Segment | None:
        interval = self.config.partial_interval
        if interval <= 0 or not self._detector.is_speech_detected():
            return None
        now = time.monotonic()
        if self._last_partial and now - self._last_partial < interval:
            return None
        current = self._detector.current_segment
        samples = np.asarray(current.samples, dtype=np.float32)
        if samples.size < MIN_PARTIAL_SECONDS * SAMPLE_RATE:
            return None
        segment = self.recognizer.decode(
            samples, offset=current.start / float(SAMPLE_RATE), is_final=False
        )
        # 解码结束后才记时间：局部解码要重跑整句，在弱 CPU 上可能比
        # partial_interval 还慢；若用解码前的时刻，节流条件会立刻再次满足，
        # 于是每个音频块都触发一次重解码，把 CPU 全部吃掉、拖慢定稿输出。
        self._last_partial = time.monotonic()
        return segment if segment.text else None

    def accept(self, chunk: np.ndarray) -> list[Segment]:
        """送入一块音频，返回本次产生的段（最终段在前，局部段在后）。"""
        self._detector.accept_waveform(np.asarray(chunk, dtype=np.float32))
        produced = self._take_finals()
        partial = self._make_partial()
        if partial is not None:
            produced.append(partial)
        return produced

    def flush(self) -> list[Segment]:
        """音频结束时调用，取出尾部未定稿的语音段。"""
        self._detector.flush()
        return self._take_finals()


def stream(
    chunks: Iterable[np.ndarray],
    config: ASRConfig | None = None,
    **kwargs: object,
) -> Iterator[Segment]:
    """把音频块序列转成识别段序列。"""
    transcriber = StreamingTranscriber(config, **kwargs)  # type: ignore[arg-type]
    for chunk in chunks:
        yield from transcriber.accept(chunk)
    yield from transcriber.flush()


def stream_file(
    path: str | Path,
    config: ASRConfig | None = None,
    *,
    chunk_ms: int = 100,
    realtime: bool = False,
    **kwargs: object,
) -> Iterator[Segment]:
    """按块读取文件做流式识别；``realtime=True`` 时按真实速度节流。"""
    samples = audio.load(path)
    chunks = audio.iter_chunks(samples, chunk_ms=chunk_ms)
    if realtime:
        chunks = _throttle(chunks, chunk_ms / 1000.0)
    yield from stream(chunks, config, **kwargs)


def stream_microphone(
    config: ASRConfig | None = None,
    *,
    device: int | str | None = None,
    chunk_ms: int = 100,
    **kwargs: object,
) -> Iterator[Segment]:
    """从麦克风做流式识别，需可选依赖 ``sounddevice``。"""
    yield from stream(audio.iter_microphone(device=device, chunk_ms=chunk_ms), config, **kwargs)


def _throttle(chunks: Iterable[np.ndarray], delay: float) -> Iterator[np.ndarray]:
    """按块时长睡眠，让文件回放接近真实采集速度。"""
    for chunk in chunks:
        started = time.monotonic()
        yield chunk
        remaining = delay - (time.monotonic() - started)
        if remaining > 0:
            time.sleep(remaining)
