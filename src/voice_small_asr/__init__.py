"""VoiceSmallASR：本地离线的多语种流式语音识别。

基于 `sherpa-onnx <https://github.com/k2-fsa/sherpa-onnx>`_ 运行
SenseVoice-Small（int8 量化）与 silero-vad，纯 CPU 推理，
支持中文、英文、粤语、日文、韩文，输出带时间戳的分段与字幕文件。
模型仅首次运行时联网下载，之后完全离线。

整段转写并导出字幕::

    from voice_small_asr import ASRConfig, Transcriber, subtitles

    transcriber = Transcriber(ASRConfig(language="yue"))
    result = transcriber.transcribe("meeting.m4a")
    print(result.text)
    subtitles.write(result, "meeting.srt")

实时流式识别（麦克风）::

    from voice_small_asr import StreamingTranscriber, audio

    streamer = StreamingTranscriber()
    for chunk in audio.iter_microphone():
        for segment in streamer.accept(chunk):
            tag = "" if segment.is_final else "…"
            print(f"[{segment.start:6.2f}s] {segment.text}{tag}")
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

from voice_small_asr import audio, models, subtitles, vad
from voice_small_asr.config import (
    ENV_MODEL_DIR,
    LANGUAGES,
    SAMPLE_RATE,
    ASRConfig,
    VADConfig,
    default_model_dir,
)
from voice_small_asr.engine import Recognizer, Transcriber
from voice_small_asr.segments import Segment, TranscriptionResult, Word
from voice_small_asr.streaming import (
    StreamingTranscriber,
    stream,
    stream_file,
    stream_microphone,
)

__version__ = "0.1.0"


def transcribe(
    source: str | Path | np.ndarray,
    *,
    language: str = "auto",
    model_dir: str | Path | None = None,
    **kwargs: object,
) -> TranscriptionResult:
    """一次性转写音频，便于脚本与快速试用。

    每次调用都会重新加载模型（约一到两秒）。需要反复识别时
    请自行持有 :class:`Transcriber` 实例复用。

    Args:
        source: 音频文件路径，或 16 kHz float32 单声道数组。
        language: ``auto``/``zh``/``en``/``ja``/``ko``/``yue``。
        model_dir: 模型目录，``None`` 用默认缓存目录。
        **kwargs: 透传给 :meth:`Transcriber.transcribe`。
    """
    config = ASRConfig(
        language=language, model_dir=Path(model_dir) if model_dir is not None else None
    )
    return Transcriber(config).transcribe(source, **kwargs)  # type: ignore[arg-type]


__all__ = [
    "ENV_MODEL_DIR",
    "LANGUAGES",
    "SAMPLE_RATE",
    "ASRConfig",
    "Recognizer",
    "Segment",
    "StreamingTranscriber",
    "TranscriptionResult",
    "Transcriber",
    "VADConfig",
    "Word",
    "__version__",
    "audio",
    "default_model_dir",
    "models",
    "stream",
    "stream_file",
    "stream_microphone",
    "subtitles",
    "transcribe",
    "vad",
]
