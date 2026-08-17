"""模型下载与本地缓存管理。

首次运行需联网下载模型，之后完全离线。也可把整个模型目录拷到
无网机器上，配合 ``VSASR_MODEL_DIR`` 或 ``allow_download=False`` 使用。

下载按 :data:`BASE_URLS` 的顺序逐个尝试，任一成功即止：国内直连
github.com 常超时，因此备了两个 GitHub Release 公共代理镜像。
"""

from __future__ import annotations

import hashlib
import http.client
import shutil
import tarfile
import tempfile
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from voice_small_asr.config import default_model_dir

#: 模型下载源，按优先级排列，任一成功即止。
#:
#: 后两个是 GitHub Release 的公共代理镜像（国内直连 github.com 常超时）。
#: 与 Flutter 端 ``model_manager.dart`` 的 ``kModelBaseUrls`` 保持同源同序，
#: 两端下载行为一致；增删源时请同步修改另一端。
BASE_URLS: tuple[str, ...] = (
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models",
    "https://ghfast.top/https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models",
    "https://gh-proxy.com/https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models",
)

#: 首选下载源。
BASE_URL = BASE_URLS[0]

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
    #: 完整文件的保守下限（字节）。镜像走 chunked 编码时拿不到
    #: ``Content-Length``，只能靠这个下限拦住明显截断的文件，见 :func:`_download`。
    min_bytes: int = 0

    @property
    def archive_name(self) -> str:
        return self.url.rsplit("/", 1)[-1]

    @property
    def is_archive(self) -> bool:
        return self.archive_name.endswith(".tar.bz2")

    @property
    def urls(self) -> tuple[str, ...]:
        """所有候选下载地址，按 :data:`BASE_URLS` 的优先级排列。"""
        return tuple(f"{base}/{self.archive_name}" for base in BASE_URLS)


#: SenseVoice-Small int8：中/英/粤/日/韩，开启 ITN 时带标点。
#: 选 2024-07-17 而非 2025-09-09，因为后者不支持标点，无法用于字幕。
ASR_MODEL = ModelSpec(
    name="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17",
    url=f"{BASE_URL}/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2",
    members=("model.int8.onnx", "tokens.txt"),
    approx_mb=228,
    min_bytes=100 * 1024 * 1024,  # 压缩包实测约 155 MB，取整数下限
)

#: silero-vad：语音端点检测，用于分句与流式触发。
VAD_MODEL = ModelSpec(
    name="silero_vad.onnx",
    url=f"{BASE_URL}/silero_vad.onnx",
    approx_mb=1,
    min_bytes=512 * 1024,  # 实测 643854 字节
)

# 解压后的固定模型文件 SHA-256。最终加载前校验内容，避免把截断或错误响应当作缓存。
ASR_MODEL_SHA256 = "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51"
TOKENS_SHA256 = "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc"
VAD_MODEL_SHA256 = "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6"


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


def verify_integrity(paths: ModelPaths) -> None:
    """校验模型文件内容，防止损坏或代理源返回错误文件。"""
    expected = {
        paths.asr_model: ASR_MODEL_SHA256,
        paths.tokens: TOKENS_SHA256,
        paths.vad_model: VAD_MODEL_SHA256,
    }
    for path, wanted in expected.items():
        if not path.is_file():
            raise OSError(f"缺少模型文件：{path}")
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1 << 20), b""):
                digest.update(chunk)
        actual = digest.hexdigest()
        if actual != wanted:
            raise OSError(f"模型文件校验失败：{path}")


def _remove_invalid_cache(root: Path, paths: ModelPaths) -> None:
    """删除坏的解压目录、VAD 和压缩包，确保下一次会重新下载。"""
    shutil.rmtree(paths.asr_model.parent, ignore_errors=True)
    paths.vad_model.unlink(missing_ok=True)
    (root / "_archives" / ASR_MODEL.archive_name).unlink(missing_ok=True)


def _download(
    url: str,
    dest: Path,
    progress: ProgressHook | None,
    *,
    source: tuple[int, int] | None = None,
    min_bytes: int = 0,
) -> None:
    """下载到 ``dest``，先写临时文件再原子改名，避免半截文件被当成有效缓存。

    Args:
        url: 完整下载地址。
        dest: 目标文件路径。
        progress: 进度回调。
        source: ``(第几个源, 共几个源)``，仅用于进度文案。
        min_bytes: 完整文件的保守下限，用于服务端不给 ``Content-Length`` 时兜底。
    """
    dest.parent.mkdir(parents=True, exist_ok=True)
    label = f"下载 {dest.name}"
    if source is not None:
        label += f"（源 {source[0]}/{source[1]}）"
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
            # 两个镜像源是流式代理，常用 chunked 编码而不给 Content-Length，
            # 上面那条校验此时形同虚设。退回一个保守下限：拦不住只差几 KB 的
            # 截断，但能拦住"下了一半断线"这种常见情况 —— 尤其是 VAD 模型，
            # 它没有解压环节兜底，一旦装成缓存就每次都加载失败。
            if not total and min_bytes and done < min_bytes:
                raise OSError(
                    f"{dest.name} 下载不完整：只收到 {done} 字节"
                    f"（服务端未给出总长度，至少应有 {min_bytes} 字节），请重试"
                )
            tmp.replace(dest)
        except BaseException:
            tmp.unlink(missing_ok=True)
            raise


def _download_with_fallback(spec: ModelSpec, dest: Path, progress: ProgressHook | None) -> None:
    """按 :data:`BASE_URLS` 的顺序逐个源尝试下载，任一成功即返回。

    全部失败时抛出最后一个错误，并在消息里说明已尝试的源数量 ——
    只报最后一个源的超时会让人误以为只有那一个镜像坏了。
    """
    urls = spec.urls
    total = len(urls)
    last: Exception | None = None
    for position, url in enumerate(urls, start=1):
        try:
            _download(url, dest, progress, source=(position, total), min_bytes=spec.min_bytes)
            return
        # HTTPException 不是 OSError 的子类：chunked 响应中途断连抛的
        # IncompleteRead 就在这一支，漏掉它会让异常直接穿出去，后面的镜像根本不试。
        except (OSError, http.client.HTTPException) as exc:  # 含超时/HTTP 错误/下载不完整
            last = exc
            if progress and position < total:
                progress(f"源 {position}/{total} 失败（{exc}），换下一个镜像", 0, 0)
    raise OSError(f"{spec.archive_name} 下载失败，已尝试 {total} 个源，最后一个错误：{last}")


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
        paths = resolve_paths(root)
        try:
            verify_integrity(paths)
            return paths
        except OSError as exc:
            if not allow_download:
                raise OSError(f"模型完整性校验失败：{exc}") from exc
            _remove_invalid_cache(root, paths)
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
                _download_with_fallback(spec, archive, progress)
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
            _download_with_fallback(spec, root / spec.name, progress)

    if not keep_archive and archives.is_dir() and not any(archives.iterdir()):
        shutil.rmtree(archives, ignore_errors=True)
    if not is_ready(root):
        raise RuntimeError(f"模型准备失败，请检查 {root} 的内容与磁盘空间")
    paths = resolve_paths(root)
    try:
        verify_integrity(paths)
    except OSError as exc:
        _remove_invalid_cache(root, paths)
        raise OSError(f"模型完整性校验失败：{exc}") from exc
    return paths
