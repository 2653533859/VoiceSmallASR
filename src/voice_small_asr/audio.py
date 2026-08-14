"""音频加载、重采样与流式采集。

统一输出模型要求的格式：float32 单声道 16 kHz，取值范围 [-1, 1]。
wav/flac 直接用 soundfile 读；其余格式（mp3/m4a/视频）或非 16 kHz 采样率
交给 ffmpeg 解码重采样，避免自己实现低质量重采样。
"""

from __future__ import annotations

import shutil
import subprocess
from collections.abc import Iterator
from pathlib import Path

import numpy as np
import soundfile as sf

from voice_small_asr.config import SAMPLE_RATE


def has_ffmpeg() -> bool:
    """ffmpeg 是否可用。"""
    return shutil.which("ffmpeg") is not None


def _decode_with_ffmpeg(path: Path, sample_rate: int) -> np.ndarray:
    """用 ffmpeg 解码为 float32 单声道指定采样率。"""
    if not has_ffmpeg():
        raise RuntimeError(
            f"读取 {path.name} 需要 ffmpeg（用于解码或重采样），但未在 PATH 中找到。"
            " 请安装 ffmpeg，或改用 16 kHz 的 wav/flac 文件。"
        )
    command = [
        "ffmpeg",
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        str(path),
        "-f",
        "f32le",
        "-ac",
        "1",
        "-ar",
        str(sample_rate),
        "-",
    ]
    completed = subprocess.run(command, capture_output=True, check=False)  # noqa: S603
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", "replace").strip()
        raise RuntimeError(f"ffmpeg 解码 {path} 失败：{detail or '未知错误'}")
    return np.frombuffer(completed.stdout, dtype=np.float32).copy()


def load(path: str | Path, *, sample_rate: int = SAMPLE_RATE) -> np.ndarray:
    """加载音频为 float32 单声道数组。"""
    source = Path(path).expanduser()
    if not source.is_file():
        raise FileNotFoundError(f"音频文件不存在：{source}")
    try:
        data, source_rate = sf.read(str(source), dtype="float32", always_2d=True)
    except Exception:  # soundfile 不支持该容器/编码，交给 ffmpeg
        return _decode_with_ffmpeg(source, sample_rate)
    if source_rate != sample_rate:
        return _decode_with_ffmpeg(source, sample_rate)
    mono = data.mean(axis=1) if data.shape[1] > 1 else data[:, 0]
    return np.ascontiguousarray(mono, dtype=np.float32)


def duration_of(samples: np.ndarray, *, sample_rate: int = SAMPLE_RATE) -> float:
    """采样数组对应的时长（秒）。"""
    return len(samples) / float(sample_rate)


def iter_chunks(
    samples: np.ndarray, *, chunk_ms: int = 100, sample_rate: int = SAMPLE_RATE
) -> Iterator[np.ndarray]:
    """把数组切成固定长度的块，用于模拟实时输入。"""
    if chunk_ms <= 0:
        raise ValueError(f"chunk_ms 必须为正，收到 {chunk_ms}")
    step = max(1, int(sample_rate * chunk_ms / 1000))
    for offset in range(0, len(samples), step):
        yield samples[offset : offset + step]


def iter_file(
    path: str | Path, *, chunk_ms: int = 100, sample_rate: int = SAMPLE_RATE
) -> Iterator[np.ndarray]:
    """按块读取文件，供流式识别使用。"""
    yield from iter_chunks(
        load(path, sample_rate=sample_rate), chunk_ms=chunk_ms, sample_rate=sample_rate
    )


def _import_sounddevice(*, required: bool):
    """导入可选依赖 sounddevice。

    除了包缺失（ImportError），PortAudio 动态库缺失或无法加载时
    ``import sounddevice`` 会抛 OSError，两者都要转成可读的中文提示。
    """
    try:
        import sounddevice  # noqa: PLC0415 (可选依赖，延迟导入)
    except (ImportError, OSError) as exc:  # pragma: no cover - 取决于环境
        if not required:
            return None
        raise RuntimeError(
            f"麦克风采集需要可用的 sounddevice / PortAudio：{exc}。"
            " 请执行 uv sync --extra mic，并确认系统已装 PortAudio。"
        ) from exc
    return sounddevice


def iter_microphone(
    *,
    device: int | str | None = None,
    chunk_ms: int = 100,
    sample_rate: int = SAMPLE_RATE,
) -> Iterator[np.ndarray]:
    """从麦克风持续采集音频块。

    需要可选依赖 ``sounddevice``：``uv sync --extra mic``。
    由调用方通过跳出循环或 ``KeyboardInterrupt`` 结束采集。
    """
    sounddevice = _import_sounddevice(required=True)
    block = max(1, int(sample_rate * chunk_ms / 1000))
    try:
        stream = sounddevice.InputStream(
            samplerate=sample_rate,
            channels=1,
            dtype="float32",
            blocksize=block,
            device=device,
        )
    except (sounddevice.PortAudioError, ValueError) as exc:
        raise RuntimeError(
            f"无法打开录音设备 {device!r}：{exc}。可用 vsasr devices 查看设备列表。"
        ) from exc
    with stream:
        while True:
            frames, overflowed = stream.read(block)
            del overflowed  # 溢出时丢弃该块之外无需处理
            yield np.ascontiguousarray(frames[:, 0], dtype=np.float32)


def list_input_devices() -> list[str]:
    """列出可用的录音设备描述，便于用户选择 ``--device``。"""
    sounddevice = _import_sounddevice(required=False)
    if sounddevice is None:
        return []
    try:
        devices = sounddevice.query_devices()
    except (sounddevice.PortAudioError, OSError):  # pragma: no cover - 取决于环境
        return []
    names = []
    for index, info in enumerate(devices):
        if info.get("max_input_channels", 0) > 0:
            # Windows 上部分蓝牙设备名内含换行，会打乱终端输出
            label = " ".join(str(info["name"]).split())
            names.append(f"{index}: {label}")
    return names
