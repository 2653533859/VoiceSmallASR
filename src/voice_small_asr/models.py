"""模型下载与本地缓存管理。

首次运行需联网下载模型，之后完全离线。也可把整个模型目录拷到
无网机器上，配合 ``VSASR_MODEL_DIR`` 或 ``allow_download=False`` 使用。
"""

from __future__ import annotations

import shutil
import tarfile
import tempfile
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from voice_small_asr.config import default_model_dir

BASE_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"

#: 下载进度回调：``(阶段描述, 已完成字节, 总字节, 总字节未知时为 0)``。
ProgressHook = Callable[[str, int, int], None]


@dataclass(frozen=True, slots=True)
class ModelSpec:
    """一个待下载的模型资源。"""

    name: str
    url: str
    #: 压缩包解压后必须存在的文件（相对包内顶层目录）；单文件模型留空。
    members: tuple[str, ...] = ()
    approx_mb: int = 0

    @property
    def archive_name(self) -> str:
        return self.url.rsplit("/", 1)[-1]

    @property
    def is_archive(self) -> bool:
        return self.archive_name.endswith(".tar.bz2")


#: SenseVoice-Small int8：中/英/粤/日/韩，开启 ITN 时带标点。
#: 选 2024-07-17 而非 2025-09-09，因为后者不支持标点，无法用于字幕。
ASR_MODEL = ModelSpec(
    name="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17",
    url=f"{BASE_URL}/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2",
    members=("model.int8.onnx", "tokens.txt"),
    approx_mb=228,
)

#: silero-vad：语音端点检测，用于分句与流式触发。
VAD_MODEL = ModelSpec(name="silero_vad.onnx", url=f"{BASE_URL}/silero_vad.onnx", approx_mb=1)


@dataclass(frozen=True, slots=True)
class ModelPaths:
    """已就绪的模型文件路径。"""

    asr_model: Path
    tokens: Path
    vad_model: Path
    #: 模型包自带的多语种示例音频目录（zh/en/ja/ko/yue.wav），可能不存在。
    test_wavs: Path | None = None


def resolve_paths(model_dir: Path | None = None) -> ModelPaths:
    """推导模型文件应在的路径，不检查是否存在。"""
    root = Path(model_dir) if model_dir is not None else default_model_dir()
    asr_dir = root / ASR_MODEL.name
    wavs = asr_dir / "test_wavs"
    return ModelPaths(
        asr_model=asr_dir / "model.int8.onnx",
        tokens=asr_dir / "tokens.txt",
        vad_model=root / VAD_MODEL.name,
        test_wavs=wavs if wavs.is_dir() else None,
    )


def is_ready(model_dir: Path | None = None) -> bool:
    """模型是否已完整存在于本地。"""
    paths = resolve_paths(model_dir)
    return all(p.is_file() for p in (paths.asr_model, paths.tokens, paths.vad_model))


def _download(url: str, dest: Path, progress: ProgressHook | None) -> None:
    """下载到 ``dest``，先写临时文件再原子改名，避免半截文件被当成有效缓存。"""
    dest.parent.mkdir(parents=True, exist_ok=True)
    label = f"下载 {dest.name}"
    with urllib.request.urlopen(url, timeout=60) as response:  # noqa: S310 (固定 https 源)
        total = int(response.headers.get("Content-Length") or 0)
        done = 0
        fd, tmp_name = tempfile.mkstemp(dir=dest.parent, suffix=".part")
        tmp = Path(tmp_name)
        try:
            with open(fd, "wb") as handle:
                while chunk := response.read(1 << 20):
                    handle.write(chunk)
                    done += len(chunk)
                    if progress:
                        progress(label, done, total)
            # 连接中途断开时 read() 只会返回 b'' 而不抛异常，循环会正常结束，
            # 因此必须比对长度，否则截断的文件会被"原子地"装成有效缓存。
            if total and done != total:
                raise OSError(
                    f"{dest.name} 下载不完整：收到 {done} 字节，应为 {total} 字节，请重试"
                )
            tmp.replace(dest)
        except BaseException:
            tmp.unlink(missing_ok=True)
            raise


def _extract(archive: Path, root: Path, progress: ProgressHook | None) -> None:
    """解压 tar.bz2，使用 data 过滤器防止路径穿越。"""
    if progress:
        progress(f"解压 {archive.name}", 0, 0)
    root.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "r:bz2") as tar:
        tar.extractall(root, filter="data")


def ensure(
    model_dir: Path | None = None,
    *,
    allow_download: bool = True,
    keep_archive: bool = False,
    progress: ProgressHook | None = None,
) -> ModelPaths:
    """确保模型就绪并返回路径；缺失时按需下载。"""
    root = Path(model_dir) if model_dir is not None else default_model_dir()
    if is_ready(root):
        return resolve_paths(root)
    if not allow_download:
        raise FileNotFoundError(
            f"模型不完整且已禁止下载。请把模型放到 {root}，"
            f"需包含 {ASR_MODEL.name}/ 与 {VAD_MODEL.name}"
        )

    archives = root / "_archives"
    for spec in (ASR_MODEL, VAD_MODEL):
        if spec.is_archive:
            if all((root / spec.name / m).is_file() for m in spec.members):
                continue
            archive = archives / spec.archive_name
            if not archive.is_file():
                _download(spec.url, archive, progress)
            try:
                _extract(archive, root, progress)
            except (tarfile.TarError, OSError):
                # 坏压缩包必须删掉：否则上面的 is_file() 会一直复用它，
                # 之后每次运行都以同样的方式失败，直到用户手动清理。
                archive.unlink(missing_ok=True)
                raise
            if not keep_archive:
                archive.unlink(missing_ok=True)
        elif not (root / spec.name).is_file():
            _download(spec.url, root / spec.name, progress)

    if not keep_archive and archives.is_dir() and not any(archives.iterdir()):
        shutil.rmtree(archives, ignore_errors=True)
    if not is_ready(root):
        raise RuntimeError(f"模型准备失败，请检查 {root} 的内容与磁盘空间")
    return resolve_paths(root)
