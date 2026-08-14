"""核心识别引擎：SenseVoice 解码 + VAD 分段的整段转写。

sherpa-onnx 的原生结果只在这里出现，对外一律返回
:class:`~voice_small_asr.segments.Segment`，便于其他项目集成。
"""

from __future__ import annotations

import re
from collections.abc import Sequence
from dataclasses import replace
from pathlib import Path

import numpy as np
import sherpa_onnx

from voice_small_asr import audio, models, vad
from voice_small_asr.config import SAMPLE_RATE, ASRConfig
from voice_small_asr.models import ModelPaths, ProgressHook
from voice_small_asr.segments import Segment, TranscriptionResult, Word

#: SenseVoice 用 ``<|zh|>`` 这类标签承载语言/情感/事件元信息。
_TAG_RE = re.compile(r"<\|([^|]*)\|>")


def _unwrap_tag(value: str | None) -> str:
    """``'<|zh|>'`` -> ``'zh'``；非标签内容原样去空白返回。"""
    if not value:
        return ""
    text = value.strip()
    matched = _TAG_RE.fullmatch(text)
    return matched.group(1) if matched else _TAG_RE.sub("", text).strip()


def _build_words(result: object, offset: float, limit: float) -> tuple[Word, ...]:
    """把 token 级时间戳换算到全局时间轴。

    SenseVoice 的英文 token 自带前导空格，中日粤为单字，
    因此 ``"".join(token)`` 即可还原文本，无需额外处理 BPE 前缀。
    """
    tokens: list[str] = list(getattr(result, "tokens", None) or [])
    starts: list[float] = list(getattr(result, "timestamps", None) or [])
    durations: list[float] = list(getattr(result, "durations", None) or [])
    count = min(len(tokens), len(starts))
    words: list[Word] = []
    for i in range(count):
        token = _TAG_RE.sub("", tokens[i])
        # 只跳过元信息标签（去标签后变成空串）。这里不能用 ``not token.strip()``：
        # SenseVoice 会把英文词间空格作为独立 token 输出（如 ``' '`` 夹在
        # ``' with'`` 与 ``'5'`` 之间），丢掉它会让拼接结果变成 "with50"。
        if not token:
            continue
        start = starts[i]
        if i < len(durations):
            end = start + durations[i]
        elif i + 1 < count:
            end = starts[i + 1]
        else:
            end = limit
        words.append(
            Word(
                text=token,
                start=offset + min(start, limit),
                end=offset + min(max(end, start), limit),
            )
        )
    return tuple(words)


class Recognizer:
    """SenseVoice 解码器薄封装：一段音频进，一个 :class:`Segment` 出。"""

    def __init__(self, config: ASRConfig, paths: ModelPaths) -> None:
        self._config = config
        self._paths = paths
        self._recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
            model=str(paths.asr_model),
            tokens=str(paths.tokens),
            num_threads=config.num_threads,
            use_itn=config.use_itn,
            language=config.sense_voice_language,
            provider="cpu",
            debug=False,
        )

    def _to_segment(
        self,
        result: object,
        *,
        length: int,
        offset: float,
        is_final: bool,
        index: int,
    ) -> Segment:
        span = length / float(SAMPLE_RATE)
        return Segment(
            text=(getattr(result, "text", "") or "").strip(),
            start=offset,
            end=offset + span,
            words=_build_words(result, offset, span),
            language=_unwrap_tag(getattr(result, "lang", "")),
            is_final=is_final,
            index=index,
        )

    def decode(
        self,
        samples: np.ndarray,
        *,
        offset: float = 0.0,
        is_final: bool = True,
        index: int = -1,
    ) -> Segment:
        """解码单段音频。"""
        stream = self._recognizer.create_stream()
        stream.accept_waveform(SAMPLE_RATE, samples)
        self._recognizer.decode_stream(stream)
        return self._to_segment(
            stream.result, length=len(samples), offset=offset, is_final=is_final, index=index
        )

    def decode_batch(
        self, batch: Sequence[tuple[np.ndarray, float]], *, first_index: int = 0
    ) -> list[Segment]:
        """批量解码 ``(音频, 起始秒)``，CPU 上比逐段解码明显更快。"""
        if not batch:
            return []
        streams = []
        for samples, _ in batch:
            stream = self._recognizer.create_stream()
            stream.accept_waveform(SAMPLE_RATE, samples)
            streams.append(stream)
        self._recognizer.decode_streams(streams)
        return [
            self._to_segment(
                stream.result,
                length=len(samples),
                offset=offset,
                is_final=True,
                index=first_index + position,
            )
            for position, (stream, (samples, offset)) in enumerate(zip(streams, batch, strict=True))
        ]


class Transcriber:
    """整段音频转写门面。

    构造一次、复用多次：模型加载约需一到两秒，服务端应把实例缓存起来。

    Example:
        >>> from voice_small_asr import ASRConfig, Transcriber
        >>> t = Transcriber(ASRConfig(language="yue"))
        >>> result = t.transcribe("meeting.mp3")
        >>> result.text
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

    @staticmethod
    def _as_samples(source: str | Path | np.ndarray) -> np.ndarray:
        if isinstance(source, (str, Path)):
            return audio.load(source)
        array = np.asarray(source, dtype=np.float32)
        if array.ndim != 1:
            raise ValueError(f"音频数组必须是一维单声道，收到形状 {array.shape}")
        return array

    def transcribe(
        self, source: str | Path | np.ndarray, *, batch_size: int = 8
    ) -> TranscriptionResult:
        """转写音频文件或采样数组。

        Args:
            source: 文件路径，或 16 kHz float32 单声道数组。
            batch_size: 批量解码的段数，越大吞吐越高、峰值内存越多。

        Returns:
            含分段、时间戳、可导出字幕的结果对象。
        """
        samples = self._as_samples(source)
        detector = vad.build(self.config.vad, self.paths.vad_model)
        collected: list[Segment] = []
        pending: list[tuple[np.ndarray, float]] = []
        for chunk, start in vad.iter_speech(detector, samples, window=self.config.vad.window_size):
            pending.append((chunk, start))
            if len(pending) >= batch_size:
                collected.extend(self.recognizer.decode_batch(pending))
                pending.clear()
        collected.extend(self.recognizer.decode_batch(pending))

        numbered = [
            replace(segment, index=position)
            for position, segment in enumerate(s for s in collected if s.text)
        ]
        return TranscriptionResult(
            segments=numbered,
            duration=audio.duration_of(samples),
            language=self.config.language,
        )
