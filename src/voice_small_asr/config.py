"""配置与常量定义。

集成方通常只需构造 :class:`ASRConfig`，其余默认值针对 CPU 离线场景调优。
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

#: SenseVoice 支持的语言代码。``auto`` 为自动检测。
LANGUAGES: tuple[str, ...] = ("auto", "zh", "en", "ja", "ko", "yue")

#: 模型要求的采样率，所有音频都会被重采样到该值。
SAMPLE_RATE: int = 16000

#: 环境变量：覆盖模型缓存目录。
ENV_MODEL_DIR = "VSASR_MODEL_DIR"


def default_model_dir() -> Path:
    """返回模型缓存目录。

    优先取环境变量 ``VSASR_MODEL_DIR``，否则用用户缓存目录，
    这样多个项目集成本库时可共享同一份模型，不重复下载。
    """
    env = os.environ.get(ENV_MODEL_DIR)
    if env:
        return Path(env).expanduser().resolve()
    return Path.home() / ".cache" / "voice-small-asr" / "models"


def _default_num_threads() -> int:
    """CPU 推理线程数：留一个核给采集与主线程。"""
    return max(1, min(4, (os.cpu_count() or 2) - 1))


@dataclass(slots=True)
class VADConfig:
    """语音端点检测（silero-vad）参数。

    这些值直接决定流式识别的延迟与断句质量：
    ``min_silence_duration`` 越小上屏越快，但容易把一句话切碎。
    """

    threshold: float = 0.5
    #: 判定句子结束所需的静音时长（秒）。
    min_silence_duration: float = 0.35
    #: 短于此长度的语音段被丢弃（秒），用于过滤咳嗽、点击噪声。
    min_speech_duration: float = 0.25
    #: 单个语音段的硬上限（秒），超过则强制切分，避免长时间不出结果。
    max_speech_duration: float = 20.0
    #: silero-vad 要求 16kHz 下窗口为 512 采样点。
    window_size: int = 512


@dataclass(slots=True)
class ASRConfig:
    """识别器配置。

    Attributes:
        language: ``auto``/``zh``/``en``/``ja``/``ko``/``yue``。
            指定具体语言比 ``auto`` 更稳，粤语建议显式传 ``yue``。
        use_itn: 逆文本标准化。开启后输出标点与阿拉伯数字，
            生成字幕时应保持开启。
        num_threads: onnxruntime 线程数。
        model_dir: 模型缓存目录，``None`` 表示用默认目录。
        partial_interval: 流式局部结果的最小间隔（秒）。
            设为 ``0`` 关闭局部结果，只输出最终句子。
        vad: 端点检测参数。
    """

    language: str = "auto"
    use_itn: bool = True
    num_threads: int = field(default_factory=_default_num_threads)
    model_dir: Path | None = None
    partial_interval: float = 0.6
    vad: VADConfig = field(default_factory=VADConfig)

    def __post_init__(self) -> None:
        if self.language not in LANGUAGES:
            raise ValueError(f"language 必须是 {LANGUAGES} 之一，收到 {self.language!r}")
        if self.num_threads < 1:
            raise ValueError(f"num_threads 必须 >= 1，收到 {self.num_threads}")
        if self.partial_interval < 0:
            raise ValueError(f"partial_interval 不能为负，收到 {self.partial_interval}")
        if self.model_dir is not None:
            self.model_dir = Path(self.model_dir).expanduser().resolve()

    @property
    def resolved_model_dir(self) -> Path:
        """实际使用的模型目录。"""
        return self.model_dir if self.model_dir is not None else default_model_dir()

    @property
    def sense_voice_language(self) -> str:
        """转换为 sherpa-onnx 期望的取值（``auto`` 对应空串）。"""
        return "" if self.language == "auto" else self.language
