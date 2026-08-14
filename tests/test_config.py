"""配置校验测试（不依赖模型）。"""

from __future__ import annotations

from pathlib import Path

import pytest

from voice_small_asr.config import (
    ENV_MODEL_DIR,
    LANGUAGES,
    SAMPLE_RATE,
    ASRConfig,
    VADConfig,
    default_model_dir,
)


def test_defaults_are_cpu_friendly() -> None:
    config = ASRConfig()
    assert config.language == "auto"
    assert config.use_itn is True
    assert 1 <= config.num_threads <= 4
    assert config.partial_interval > 0
    assert config.model_dir is None


def test_vad_defaults() -> None:
    vad = VADConfig()
    assert vad.window_size == 512, "silero-vad 在 16 kHz 下要求 512 采样窗口"
    assert 0 < vad.threshold < 1
    assert vad.min_silence_duration > 0
    assert vad.max_speech_duration > vad.min_speech_duration


def test_sample_rate_matches_model_requirement() -> None:
    assert SAMPLE_RATE == 16000


@pytest.mark.parametrize("language", LANGUAGES)
def test_every_declared_language_is_accepted(language: str) -> None:
    assert ASRConfig(language=language).language == language


def test_required_languages_are_supported() -> None:
    for language in ("zh", "en", "yue", "ja"):
        assert language in LANGUAGES


def test_unknown_language_is_rejected() -> None:
    with pytest.raises(ValueError, match="language"):
        ASRConfig(language="fr")


def test_auto_maps_to_empty_string_for_sherpa() -> None:
    assert ASRConfig(language="auto").sense_voice_language == ""
    assert ASRConfig(language="yue").sense_voice_language == "yue"


def test_non_positive_threads_rejected() -> None:
    with pytest.raises(ValueError, match="num_threads"):
        ASRConfig(num_threads=0)


def test_negative_partial_interval_rejected() -> None:
    with pytest.raises(ValueError, match="partial_interval"):
        ASRConfig(partial_interval=-1.0)


def test_partial_interval_zero_disables_partials() -> None:
    assert ASRConfig(partial_interval=0.0).partial_interval == 0.0


def test_model_dir_is_expanded_to_absolute(tmp_path: Path) -> None:
    config = ASRConfig(model_dir=tmp_path / "m")
    assert config.model_dir is not None
    assert config.model_dir.is_absolute()
    assert config.resolved_model_dir == config.model_dir


def test_default_model_dir_honours_env(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setenv(ENV_MODEL_DIR, str(tmp_path / "custom"))
    assert default_model_dir() == (tmp_path / "custom").resolve()


def test_default_model_dir_without_env(monkeypatch) -> None:
    monkeypatch.delenv(ENV_MODEL_DIR, raising=False)
    assert default_model_dir().parts[-2:] == ("voice-small-asr", "models")


def test_resolved_model_dir_falls_back_to_default(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setenv(ENV_MODEL_DIR, str(tmp_path))
    assert ASRConfig().resolved_model_dir == tmp_path.resolve()
