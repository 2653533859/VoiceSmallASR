"""命令行与包级接口测试（不依赖模型）。"""

from __future__ import annotations

from pathlib import Path

import pytest

import voice_small_asr
from voice_small_asr.cli import build_parser, main


def test_package_exposes_stable_api() -> None:
    for name in (
        "Transcriber",
        "StreamingTranscriber",
        "ASRConfig",
        "Segment",
        "TranscriptionResult",
        "transcribe",
        "subtitles",
        "models",
        "audio",
    ):
        assert name in voice_small_asr.__all__
        assert hasattr(voice_small_asr, name)


def test_version_is_set() -> None:
    assert voice_small_asr.__version__


def test_parser_prog_name() -> None:
    assert build_parser().prog == "vsasr"


def test_main_without_args_prints_help(capsys) -> None:
    assert main([]) == 0
    assert "vsasr" in capsys.readouterr().out


def test_version_flag_exits_zero(capsys) -> None:
    with pytest.raises(SystemExit) as excinfo:
        main(["--version"])
    assert excinfo.value.code == 0
    assert voice_small_asr.__version__ in capsys.readouterr().out


def test_transcribe_args_parsed() -> None:
    args = build_parser().parse_args(
        ["transcribe", "a.wav", "-l", "yue", "-o", "a.srt", "-o", "a.json", "-t", "3"]
    )
    assert args.audio == Path("a.wav")
    assert args.language == "yue"
    assert args.output == [Path("a.srt"), Path("a.json")]
    assert args.threads == 3
    assert args.format == "srt"


def test_transcribe_rejects_unsupported_language() -> None:
    with pytest.raises(SystemExit):
        build_parser().parse_args(["transcribe", "a.wav", "-l", "fr"])


def test_live_args_have_sensible_defaults() -> None:
    args = build_parser().parse_args(["live"])
    assert args.language == "auto"
    assert args.chunk_ms == 100
    assert args.partial_interval is None
    assert args.device is None


def test_device_number_becomes_int() -> None:
    """sounddevice 把 str 当设备名子串查询，纯数字必须转成 int。"""
    assert build_parser().parse_args(["live", "--device", "6"]).device == 6


def test_device_name_stays_str() -> None:
    args = build_parser().parse_args(["live", "--device", "AirPods"])
    assert args.device == "AirPods"


def test_unsupported_output_format_fails_before_loading_model(tmp_path, capsys) -> None:
    """格式错误必须在识别前报出来，不能白跑几分钟解码。"""
    dummy = tmp_path / "in.wav"
    dummy.touch()
    code = main(["transcribe", str(dummy), "-o", str(tmp_path / "out.ass")])
    assert code == 1
    assert "不支持的输出格式" in capsys.readouterr().err
    assert not (tmp_path / "out.ass").exists()


def test_zero_threads_is_rejected(tmp_path, capsys) -> None:
    dummy = tmp_path / "in.wav"
    dummy.touch()
    code = main(["transcribe", str(dummy), "-t", "0"])
    assert code == 1
    assert "num_threads" in capsys.readouterr().err


def test_download_accepts_model_dir() -> None:
    args = build_parser().parse_args(["download", "--model-dir", "m"])
    assert args.model_dir == Path("m")


def test_missing_audio_file_reports_error(capsys) -> None:
    code = main(["transcribe", "no-such-file-12345.wav"])
    assert code == 1
    assert "错误" in capsys.readouterr().err


def test_devices_subcommand_is_registered() -> None:
    assert build_parser().parse_args(["devices"]).command == "devices"
