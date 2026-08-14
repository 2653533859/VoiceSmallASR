"""字幕与文本导出：SRT / VTT / JSON / 纯文本。"""

from __future__ import annotations

from collections.abc import Iterable, Iterator
from pathlib import Path

from voice_small_asr.segments import Segment, TranscriptionResult, Word

#: 支持的导出格式。
FORMATS: tuple[str, ...] = ("srt", "vtt", "json", "txt")

#: 单条字幕的默认字符上限（CJK 按字计，约两行的量）。
DEFAULT_MAX_CHARS = 28
#: 单条字幕的默认时长上限（秒）。
DEFAULT_MAX_DURATION = 6.0


def format_timestamp(seconds: float, *, sep: str = ",") -> str:
    """格式化为 ``HH:MM:SS,mmm``（SRT）或 ``HH:MM:SS.mmm``（VTT）。"""
    if seconds < 0:
        seconds = 0.0
    total_ms = int(round(seconds * 1000))
    hours, rem = divmod(total_ms, 3_600_000)
    minutes, rem = divmod(rem, 60_000)
    secs, ms = divmod(rem, 1000)
    return f"{hours:02d}:{minutes:02d}:{secs:02d}{sep}{ms:03d}"


def _split_by_words(
    words: tuple[Word, ...], text: str, max_chars: int, max_duration: float
) -> Iterator[tuple[str, float, float]]:
    """按 token 时间戳把长段切成多条字幕。"""
    chunk: list[Word] = []
    for word in words:
        too_long = len("".join(w.text for w in chunk)) + len(word.text) > max_chars
        too_slow = bool(chunk) and word.end - chunk[0].start > max_duration
        if chunk and (too_long or too_slow):
            yield "".join(w.text for w in chunk).strip(), chunk[0].start, chunk[-1].end
            chunk = []
        chunk.append(word)
    if chunk:
        yield "".join(w.text for w in chunk).strip(), chunk[0].start, chunk[-1].end


def _split_evenly(
    text: str, start: float, end: float, max_chars: int, max_duration: float
) -> Iterator[tuple[str, float, float]]:
    """没有 token 时间戳时，按字符数均分时间。

    除字符上限外还要收紧到 ``max_duration``：VAD 会在
    ``max_speech_duration``（默认 20 秒）处硬切，这种长段若没有 token
    时间戳，只按字符切会留下挂在屏幕上二十秒的字幕。
    """
    if not text:
        return
    span = max(end - start, 0.0)
    total = len(text)
    step = max_chars
    if max_duration > 0 and span > max_duration:
        seconds_per_char = span / total
        step = max(1, min(step, int(max_duration / seconds_per_char)))
    for offset in range(0, total, step):
        piece = text[offset : offset + step]
        yield (
            piece,
            start + span * offset / total,
            start + span * min(offset + step, total) / total,
        )


def iter_cues(
    segments: Iterable[Segment],
    *,
    max_chars: int = DEFAULT_MAX_CHARS,
    max_duration: float = DEFAULT_MAX_DURATION,
) -> Iterator[tuple[str, float, float]]:
    """把识别段展开为字幕条目 ``(文本, 起, 止)``，过长的段会被切分。"""
    for seg in segments:
        text = seg.text.strip()
        if not text:
            continue
        short_enough = len(text) <= max_chars and seg.duration <= max_duration
        if short_enough:
            yield text, seg.start, seg.end
        elif seg.words:
            yield from _split_by_words(seg.words, text, max_chars, max_duration)
        else:
            yield from _split_evenly(text, seg.start, seg.end, max_chars, max_duration)


def to_srt(segments: Iterable[Segment], **kwargs: float) -> str:
    """生成 SRT 字幕内容。"""
    lines: list[str] = []
    for number, (text, start, end) in enumerate(iter_cues(segments, **kwargs), start=1):
        lines.append(str(number))
        lines.append(f"{format_timestamp(start)} --> {format_timestamp(max(end, start + 0.001))}")
        lines.append(text)
        lines.append("")
    return "\n".join(lines)


def to_vtt(segments: Iterable[Segment], **kwargs: float) -> str:
    """生成 WebVTT 字幕内容。"""
    lines = ["WEBVTT", ""]
    for text, start, end in iter_cues(segments, **kwargs):
        begin = format_timestamp(start, sep=".")
        finish = format_timestamp(max(end, start + 0.001), sep=".")
        lines.append(f"{begin} --> {finish}")
        lines.append(text)
        lines.append("")
    return "\n".join(lines)


def to_txt(segments: Iterable[Segment]) -> str:
    """生成纯文本（每段一行）。"""
    return "\n".join(s.text.strip() for s in segments if s.text.strip()) + "\n"


def render(result: TranscriptionResult, fmt: str, **kwargs: float) -> str:
    """按格式渲染识别结果。"""
    fmt = fmt.lower()
    if fmt == "srt":
        return to_srt(result.segments, **kwargs)
    if fmt == "vtt":
        return to_vtt(result.segments, **kwargs)
    if fmt == "json":
        return result.to_json()
    if fmt == "txt":
        return to_txt(result.segments)
    raise ValueError(f"不支持的格式 {fmt!r}，可选 {FORMATS}")


def write(
    result: TranscriptionResult, path: str | Path, fmt: str | None = None, **kwargs: float
) -> Path:
    """把结果写入文件，格式默认由扩展名推断。"""
    target = Path(path).expanduser()
    resolved = (fmt or target.suffix.lstrip(".") or "srt").lower()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(render(result, resolved, **kwargs), encoding="utf-8")
    return target
