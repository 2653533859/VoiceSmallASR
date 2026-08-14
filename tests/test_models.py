"""模型下载与缓存管理测试（全部离线，不触碰网络）。"""

from __future__ import annotations

import io
import tarfile
import urllib.request
from pathlib import Path

import pytest

from voice_small_asr import models


class _FakeResponse:
    """够用的 HTTPResponse 替身：``read`` 到末尾返回 ``b''`` 而不报错。"""

    def __init__(self, payload: bytes, declared_length: int | None) -> None:
        self._buffer = io.BytesIO(payload)
        self.headers: dict[str, str] = {}
        if declared_length is not None:
            self.headers["Content-Length"] = str(declared_length)

    def read(self, size: int) -> bytes:
        return self._buffer.read(size)

    def __enter__(self) -> _FakeResponse:
        return self

    def __exit__(self, *exc_info: object) -> bool:
        return False


def _serve(monkeypatch, payload: bytes, declared: int | None) -> None:
    monkeypatch.setattr(
        urllib.request, "urlopen", lambda *args, **kwargs: _FakeResponse(payload, declared)
    )


def test_download_writes_complete_file(monkeypatch, tmp_path: Path) -> None:
    payload = b"x" * 4096
    _serve(monkeypatch, payload, len(payload))
    target = tmp_path / "model.bin"
    models._download("https://example.invalid/model.bin", target, None)
    assert target.read_bytes() == payload


def test_download_rejects_truncated_response(monkeypatch, tmp_path: Path) -> None:
    """连接中断时 read() 只返回 b''，必须靠长度比对识别出截断。"""
    _serve(monkeypatch, b"only-a-few-bytes", 10_000_000)
    target = tmp_path / "model.bin"
    with pytest.raises(OSError, match="下载不完整"):
        models._download("https://example.invalid/model.bin", target, None)
    assert not target.exists(), "截断的文件不能被装成有效缓存"
    assert list(tmp_path.iterdir()) == [], "临时 .part 文件也应清理掉"


def test_download_tolerates_missing_content_length(monkeypatch, tmp_path: Path) -> None:
    payload = b"chunked-without-length"
    _serve(monkeypatch, payload, None)
    target = tmp_path / "model.bin"
    models._download("https://example.invalid/model.bin", target, None)
    assert target.read_bytes() == payload


def test_download_reports_progress(monkeypatch, tmp_path: Path) -> None:
    payload = b"y" * (3 << 20)
    _serve(monkeypatch, payload, len(payload))
    seen: list[tuple[str, int, int]] = []
    models._download("https://example.invalid/m.bin", tmp_path / "m.bin", lambda *a: seen.append(a))
    assert seen, "应回调下载进度"
    assert seen[-1][1] == len(payload)
    assert seen[-1][2] == len(payload)


def test_corrupt_archive_is_deleted_so_next_run_can_retry(monkeypatch, tmp_path: Path) -> None:
    """坏压缩包必须删掉，否则之后每次运行都会复用它并同样失败。"""
    archive = tmp_path / "_archives" / models.ASR_MODEL.archive_name
    archive.parent.mkdir(parents=True)
    archive.write_bytes(b"this is definitely not a bz2 tarball")

    def explode(*args: object, **kwargs: object) -> None:
        raise AssertionError("不应发起任何网络请求")

    monkeypatch.setattr(urllib.request, "urlopen", explode)
    with pytest.raises((tarfile.TarError, OSError)):
        models.ensure(tmp_path)
    assert not archive.exists()


def test_resolve_paths_layout(tmp_path: Path) -> None:
    paths = models.resolve_paths(tmp_path)
    assert paths.asr_model == tmp_path / models.ASR_MODEL.name / "model.int8.onnx"
    assert paths.tokens == tmp_path / models.ASR_MODEL.name / "tokens.txt"
    assert paths.vad_model == tmp_path / "silero_vad.onnx"
    assert paths.test_wavs is None


def test_is_ready_false_when_files_missing(tmp_path: Path) -> None:
    assert models.is_ready(tmp_path) is False


def test_is_ready_true_when_all_files_present(tmp_path: Path) -> None:
    paths = models.resolve_paths(tmp_path)
    for target in (paths.asr_model, paths.tokens, paths.vad_model):
        target.parent.mkdir(parents=True, exist_ok=True)
        target.touch()
    assert models.is_ready(tmp_path) is True


def test_offline_mode_gives_actionable_error(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError, match="禁止下载"):
        models.ensure(tmp_path, allow_download=False)


def test_asr_model_choice_is_the_punctuating_one() -> None:
    """2025-09-09 版不支持标点，字幕场景必须用 2024-07-17 版。"""
    assert models.ASR_MODEL.name.endswith("2024-07-17")
    assert models.ASR_MODEL.is_archive
    assert "model.int8.onnx" in models.ASR_MODEL.members


def test_vad_model_is_a_plain_file() -> None:
    assert not models.VAD_MODEL.is_archive
    assert models.VAD_MODEL.archive_name == "silero_vad.onnx"
