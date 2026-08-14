"""silero-vad 端点检测封装。

VAD 承担两件事：把长音频切成句子级片段（决定字幕断句），
以及在流式场景下告诉我们"一句话说完了"从而触发识别。
"""

from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path

import numpy as np
import sherpa_onnx

from voice_small_asr.config import SAMPLE_RATE, VADConfig


def build(
    config: VADConfig,
    model_path: Path,
    *,
    num_threads: int = 1,
    buffer_seconds: float = 60.0,
) -> sherpa_onnx.VoiceActivityDetector:
    """构造 VoiceActivityDetector。"""
    vad_config = sherpa_onnx.VadModelConfig()
    vad_config.silero_vad.model = str(model_path)
    vad_config.silero_vad.threshold = config.threshold
    vad_config.silero_vad.min_silence_duration = config.min_silence_duration
    vad_config.silero_vad.min_speech_duration = config.min_speech_duration
    vad_config.silero_vad.max_speech_duration = config.max_speech_duration
    vad_config.silero_vad.window_size = config.window_size
    vad_config.sample_rate = SAMPLE_RATE
    vad_config.num_threads = num_threads
    vad_config.provider = "cpu"
    if not vad_config.validate():
        raise RuntimeError(f"VAD 配置无效，请检查模型文件：{model_path}")
    return sherpa_onnx.VoiceActivityDetector(vad_config, buffer_size_in_seconds=buffer_seconds)


def drain(
    detector: sherpa_onnx.VoiceActivityDetector,
) -> Iterator[tuple[np.ndarray, float]]:
    """取出当前已完成的语音段，产出 ``(音频, 起始秒)``。

    ``front`` 返回的是检测器内部对象的引用，``pop()`` 之后其 ``samples``
    会变成空数组，因此这里必须在 ``pop()`` 之前把数据拷出来。
    """
    while not detector.empty():
        segment = detector.front
        samples = np.array(segment.samples, dtype=np.float32, copy=True)
        start = segment.start / float(SAMPLE_RATE)
        detector.pop()
        if samples.size:
            yield samples, start


def iter_speech(
    detector: sherpa_onnx.VoiceActivityDetector,
    samples: np.ndarray,
    *,
    window: int = 512,
) -> Iterator[tuple[np.ndarray, float]]:
    """把整段音频喂给 VAD，逐个产出检测到的语音段。

    按 ``window`` 大小分批送入，与 silero-vad 的推理窗口对齐。
    """
    for offset in range(0, len(samples), window):
        detector.accept_waveform(samples[offset : offset + window])
        yield from drain(detector)
    detector.flush()
    yield from drain(detector)
