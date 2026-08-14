"""VoiceSmallASR 命令行入口。

子命令：

* ``download``   预先下载模型（之后可完全离线运行）
* ``transcribe`` 转写音频文件，输出字幕或文本
* ``live``       麦克风实时识别
* ``devices``    列出可用录音设备
"""

from __future__ import annotations

import argparse
import sys
import tarfile
from pathlib import Path

from voice_small_asr import (
    StreamingTranscriber,
    Transcriber,
    __version__,
    audio,
    models,
    subtitles,
)
from voice_small_asr.config import LANGUAGES, ASRConfig
from voice_small_asr.segments import Segment, TranscriptionResult

_MB = 1024 * 1024


def _device(value: str) -> int | str:
    """``--device`` 既接受设备编号也接受名称片段。

    sounddevice 把 ``str`` 当作设备名的子串查询，所以纯数字必须转成 ``int``，
    否则 ``--device 6`` 会去搜名字里含 "6" 的设备而不是 6 号设备。
    """
    return int(value) if value.lstrip("-").isdigit() else value


def _progress(stage: str, done: int, total: int) -> None:
    """把下载进度写到 stderr，避免污染 stdout 的转写结果。"""
    if total:
        end = "\n" if done >= total else ""
        print(
            f"\r{stage} {done * 100 // total:3d}% ({done / _MB:.1f}/{total / _MB:.1f} MB)",
            end=end,
            file=sys.stderr,
            flush=True,
        )
    else:
        print(stage, file=sys.stderr, flush=True)


def _config_from(args: argparse.Namespace) -> ASRConfig:
    kwargs: dict[str, object] = {
        "language": args.language,
        "model_dir": args.model_dir,
    }
    # 用 is not None 而不是真值判断：--threads 0 应当被 ASRConfig 拒绝，
    # 而不是静默退回自动选择的线程数。
    if getattr(args, "threads", None) is not None:
        kwargs["num_threads"] = args.threads
    if getattr(args, "partial_interval", None) is not None:
        kwargs["partial_interval"] = args.partial_interval
    return ASRConfig(**kwargs)  # type: ignore[arg-type]


def _check_formats(outputs: list[Path] | None) -> None:
    """在开始识别前校验输出格式，避免转写几分钟后才因扩展名报错。"""
    for target in outputs or []:
        suffix = target.suffix.lstrip(".").lower() or "srt"
        if suffix not in subtitles.FORMATS:
            raise ValueError(
                f"不支持的输出格式 {target.suffix!r}（{target}），可选 {subtitles.FORMATS}"
            )


def _write_outputs(result: TranscriptionResult, outputs: list[Path] | None) -> None:
    for target in outputs or []:
        written = subtitles.write(result, target)
        print(f"已写入 {written}", file=sys.stderr)


def cmd_download(args: argparse.Namespace) -> int:
    """下载并解压模型。"""
    paths = models.ensure(args.model_dir, progress=_progress)
    print(f"模型目录：{paths.asr_model.parent}")
    print(f"识别模型：{paths.asr_model.name}（{paths.asr_model.stat().st_size / _MB:.0f} MB）")
    print(f"VAD 模型：{paths.vad_model.name}")
    return 0


def cmd_transcribe(args: argparse.Namespace) -> int:
    """转写音频文件。"""
    if not args.audio.is_file():
        raise FileNotFoundError(f"音频文件不存在：{args.audio}")
    _check_formats(args.output)

    transcriber = Transcriber(_config_from(args), progress=_progress)
    result = transcriber.transcribe(args.audio)
    _write_outputs(result, args.output)
    if not args.output:
        print(subtitles.render(result, args.format))
    print(
        f"共 {len(result)} 段，音频时长 {result.duration:.2f}s",
        file=sys.stderr,
    )
    return 0


def _show_live(segment: Segment) -> None:
    """临时结果原地刷新，最终结果换行留存。"""
    prefix = f"[{segment.start:7.2f}s] "
    if segment.is_final:
        print(f"\r\x1b[K{prefix}{segment.text}", flush=True)
    else:
        print(f"\r\x1b[K{prefix}{segment.text} …", end="", flush=True)


def cmd_live(args: argparse.Namespace) -> int:
    """麦克风实时识别。"""
    _check_formats(args.output)

    streamer = StreamingTranscriber(_config_from(args), progress=_progress)
    finals: list[Segment] = []
    print("开始录音，按 Ctrl+C 结束。", file=sys.stderr)
    try:
        for chunk in audio.iter_microphone(device=args.device, chunk_ms=args.chunk_ms):
            for segment in streamer.accept(chunk):
                _show_live(segment)
                if segment.is_final:
                    finals.append(segment)
    except KeyboardInterrupt:
        print("\r\x1b[K已停止录音。", file=sys.stderr)
    for segment in streamer.flush():
        _show_live(segment)
        finals.append(segment)

    if args.output:
        duration = finals[-1].end if finals else 0.0
        result = TranscriptionResult(segments=finals, duration=duration, language=args.language)
        _write_outputs(result, args.output)
    return 0


def cmd_devices(args: argparse.Namespace) -> int:
    """列出录音设备。"""
    del args
    devices = audio.list_input_devices()
    if not devices:
        print("未找到录音设备，或未安装 sounddevice（uv add sounddevice）")
        return 1
    print("可用录音设备：")
    for line in devices:
        print(f"  {line}")
    return 0


def _add_model_dir(sub: argparse.ArgumentParser) -> None:
    sub.add_argument(
        "--model-dir",
        type=Path,
        default=None,
        help="模型目录，默认用户缓存目录，也可用环境变量 VSASR_MODEL_DIR 指定",
    )


def _add_language(sub: argparse.ArgumentParser) -> None:
    sub.add_argument(
        "-l",
        "--language",
        choices=LANGUAGES,
        default="auto",
        help="识别语言；粤语传 yue，默认 auto 自动检测",
    )


def build_parser() -> argparse.ArgumentParser:
    """构建命令行参数解析器。"""
    parser = argparse.ArgumentParser(
        prog="vsasr",
        description="VoiceSmallASR - 本地离线的多语种（中/英/粤/日/韩）语音识别",
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    subparsers = parser.add_subparsers(dest="command", metavar="命令")

    download = subparsers.add_parser("download", help="预先下载模型，之后可离线运行")
    _add_model_dir(download)
    download.set_defaults(func=cmd_download)

    transcribe = subparsers.add_parser("transcribe", help="转写音频文件")
    transcribe.add_argument("audio", type=Path, help="音频或视频文件路径")
    transcribe.add_argument(
        "-o",
        "--output",
        type=Path,
        action="append",
        help="输出文件，按扩展名决定格式（.srt/.vtt/.json/.txt），可重复指定",
    )
    transcribe.add_argument(
        "-f",
        "--format",
        choices=subtitles.FORMATS,
        default="srt",
        help="未指定 -o 时打印到标准输出的格式，默认 srt",
    )
    transcribe.add_argument("-t", "--threads", type=int, default=None, help="CPU 推理线程数")
    _add_language(transcribe)
    _add_model_dir(transcribe)
    transcribe.set_defaults(func=cmd_transcribe)

    live = subparsers.add_parser("live", help="麦克风实时识别（需要 sounddevice）")
    live.add_argument(
        "-o", "--output", type=Path, action="append", help="结束后保存字幕/文本，可重复指定"
    )
    live.add_argument(
        "--device", type=_device, default=None, help="录音设备编号或名称，见 devices 子命令"
    )
    live.add_argument("--chunk-ms", type=int, default=100, help="采集块大小（毫秒），默认 100")
    live.add_argument(
        "--partial-interval",
        type=float,
        default=None,
        help="临时结果刷新间隔（秒），0 表示只输出定稿句子",
    )
    live.add_argument("-t", "--threads", type=int, default=None, help="CPU 推理线程数")
    _add_language(live)
    _add_model_dir(live)
    live.set_defaults(func=cmd_live)

    devices = subparsers.add_parser("devices", help="列出可用录音设备")
    devices.set_defaults(func=cmd_devices)

    return parser


def main(argv: list[str] | None = None) -> int:
    """命令行主入口，返回进程退出码。"""
    parser = build_parser()
    args = parser.parse_args(argv)
    handler = getattr(args, "func", None)
    if handler is None:
        parser.print_help()
        return 0
    try:
        return int(handler(args))
    except (OSError, RuntimeError, ValueError, tarfile.TarError) as exc:
        # OSError 覆盖 FileNotFoundError 与 urllib 的 URLError/HTTPError，
        # TarError 覆盖压缩包损坏；都应当变成一行中文错误而不是 traceback。
        print(f"错误：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
