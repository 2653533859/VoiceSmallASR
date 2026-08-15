"""模型下载与缓存管理测试（全部离线，不触碰网络）。"""

from __future__ import annotations

import http.client
import io
import tarfile
import urllib.error
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


def _serve_by_url(monkeypatch, outcomes: dict[str, bytes | Exception]) -> list[str]:
    """按 URL 分发响应，返回被依次请求过的 URL 列表。

    未登记的 URL 视为不可达，用于确认成功后不再尝试后面的镜像。
    """
    requested: list[str] = []

    def fake_urlopen(url: str, *args: object, **kwargs: object) -> _FakeResponse:
        requested.append(url)
        outcome = outcomes.get(url)
        if isinstance(outcome, Exception):
            raise outcome
        if outcome is None:
            raise urllib.error.URLError(f"未登记的 URL：{url}")
        return _FakeResponse(outcome, len(outcome))

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    return requested


def test_model_spec_urls_cover_every_source() -> None:
    urls = models.VAD_MODEL.urls
    assert len(urls) == len(models.BASE_URLS)
    assert urls[0] == models.VAD_MODEL.url, "首选源应与 spec.url 一致"
    assert all(u.endswith("/silero_vad.onnx") for u in urls)


def test_download_falls_back_to_the_next_source(monkeypatch, tmp_path: Path) -> None:
    """首选源不通时应自动换镜像，而不是直接失败。"""
    payload = b"mirrored-model"
    urls = models.VAD_MODEL.urls
    requested = _serve_by_url(
        monkeypatch,
        {urls[0]: urllib.error.URLError("timed out"), urls[1]: payload},
    )
    target = tmp_path / "silero_vad.onnx"
    models._download_with_fallback(models.VAD_MODEL, target, None)
    assert target.read_bytes() == payload
    assert requested == [urls[0], urls[1]], "成功后不应再试后面的源"


def test_download_fallback_skips_truncated_source(monkeypatch, tmp_path: Path) -> None:
    """截断的响应等于该源坏了，应换下一个源而不是留下半截文件。"""
    payload = b"z" * 512
    urls = models.VAD_MODEL.urls
    outcomes: dict[str, bytes | Exception] = {urls[1]: payload}
    requested: list[str] = []

    def fake_urlopen(url: str, *args: object, **kwargs: object) -> _FakeResponse:
        requested.append(url)
        if url == urls[0]:
            return _FakeResponse(payload[:100], len(payload))  # 声明 512 只给 100
        body = outcomes.get(url)
        assert isinstance(body, bytes)
        return _FakeResponse(body, len(body))

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    target = tmp_path / "silero_vad.onnx"
    models._download_with_fallback(models.VAD_MODEL, target, None)
    assert target.read_bytes() == payload
    assert list(tmp_path.iterdir()) == [target], "失败源的 .part 文件应已清理"


def test_download_rejects_short_body_when_length_unknown(monkeypatch, tmp_path: Path) -> None:
    """镜像走 chunked 编码时没有 Content-Length，只能靠保守下限拦住截断。"""
    _serve(monkeypatch, b"half-a-model", None)
    target = tmp_path / "silero_vad.onnx"
    with pytest.raises(OSError, match="下载不完整"):
        models._download(
            "https://example.invalid/silero_vad.onnx", target, None, min_bytes=512 * 1024
        )
    assert not target.exists(), "截断的文件不能被装成有效缓存"
    assert list(tmp_path.iterdir()) == [], "临时 .part 文件也应清理掉"


def test_download_fallback_takes_min_bytes_from_spec(monkeypatch, tmp_path: Path) -> None:
    """下限来自 spec：第一个源不报长度且只给了一小截，应换下一个源。"""
    spec = models.ModelSpec(name="t.bin", url=f"{models.BASE_URL}/t.bin", min_bytes=4096)
    urls = spec.urls
    payload = b"w" * 8192
    requested: list[str] = []

    def fake_urlopen(url: str, *args: object, **kwargs: object) -> _FakeResponse:
        requested.append(url)
        return _FakeResponse(b"w" * 100 if url == urls[0] else payload, None)

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    target = tmp_path / "t.bin"
    models._download_with_fallback(spec, target, None)
    assert target.read_bytes() == payload
    assert requested == [urls[0], urls[1]]


def test_download_fallback_survives_incomplete_read(monkeypatch, tmp_path: Path) -> None:
    """IncompleteRead 不是 OSError 的子类，漏掉它会让后面的镜像根本没机会试。"""
    urls = models.VAD_MODEL.urls
    payload = b"v" * (600 * 1024)
    requested: list[str] = []

    class _BrokenResponse(_FakeResponse):
        """chunked 响应中途断连：read() 抛 IncompleteRead 而不是返回 b''。"""

        def read(self, size: int) -> bytes:
            raise http.client.IncompleteRead(b"half")

    def fake_urlopen(url: str, *args: object, **kwargs: object) -> _FakeResponse:
        requested.append(url)
        if url == urls[0]:
            return _BrokenResponse(b"", None)
        return _FakeResponse(payload, len(payload))

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    target = tmp_path / "silero_vad.onnx"
    models._download_with_fallback(models.VAD_MODEL, target, None)
    assert target.read_bytes() == payload
    assert requested == [urls[0], urls[1]], "断连的源应被跳过，而不是让异常穿出去"
    assert list(tmp_path.iterdir()) == [target], "断连源的 .part 文件应已清理"


def test_download_fallback_error_mentions_every_source(monkeypatch, tmp_path: Path) -> None:
    _serve_by_url(monkeypatch, {})  # 所有源都不可达
    with pytest.raises(OSError, match=f"已尝试 {len(models.BASE_URLS)} 个源"):
        models._download_with_fallback(models.VAD_MODEL, tmp_path / "silero_vad.onnx", None)


def test_download_fallback_reports_source_switch(monkeypatch, tmp_path: Path) -> None:
    urls = models.VAD_MODEL.urls
    _serve_by_url(monkeypatch, {urls[0]: urllib.error.URLError("nope"), urls[1]: b"ok"})
    stages: list[str] = []
    models._download_with_fallback(
        models.VAD_MODEL, tmp_path / "silero_vad.onnx", lambda stage, *_: stages.append(stage)
    )
    assert any("换下一个镜像" in stage for stage in stages)
    assert any("源 2/" in stage for stage in stages), "进度文案应标出当前用的是第几个源"


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
