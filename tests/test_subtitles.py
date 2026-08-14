"""字幕导出与时间戳格式化测试（不依赖模型）。"""

from __future__ import annotations

import json

import pytest

from voice_small_asr import subtitles
from voice_small_asr.segments import Segment, TranscriptionResult, Word


def make_words(pairs: list[tuple[str, float, float]]) -> tuple[Word, ...]:
    return tuple(Word(text=t, start=s, end=e) for t, s, e in pairs)


@pytest.mark.parametrize(
    ("seconds", "expected"),
    [
        (0.0, "00:00:00,000"),
        (1.5, "00:00:01,500"),
        (61.25, "00:01:01,250"),
        (3661.234, "01:01:01,234"),
        (-5.0, "00:00:00,000"),
    ],
)
def test_format_timestamp(seconds: float, expected: str) -> None:
    assert subtitles.format_timestamp(seconds) == expected


def test_format_timestamp_vtt_uses_dot() -> None:
    assert subtitles.format_timestamp(1.5, sep=".") == "00:00:01.500"


def test_short_segment_is_not_split() -> None:
    segment = Segment(text="你好世界", start=0.0, end=1.0)
    assert list(subtitles.iter_cues([segment])) == [("你好世界", 0.0, 1.0)]


def test_empty_segment_is_skipped() -> None:
    assert list(subtitles.iter_cues([Segment(text="   ", start=0.0, end=1.0)])) == []


def test_long_segment_splits_on_word_timestamps() -> None:
    words = make_words([(char, float(i), i + 1.0) for i, char in enumerate("一二三四五六")])
    segment = Segment(text="一二三四五六", start=0.0, end=6.0, words=words)
    cues = list(subtitles.iter_cues([segment], max_chars=2, max_duration=99.0))
    assert [c[0] for c in cues] == ["一二", "三四", "五六"]
    assert cues[0][1] == 0.0
    assert cues[1][1] == 2.0
    assert cues[-1][2] == 6.0


def test_long_segment_splits_on_duration() -> None:
    words = make_words([(char, float(i) * 3, i * 3 + 3.0) for i, char in enumerate("甲乙丙")])
    segment = Segment(text="甲乙丙", start=0.0, end=9.0, words=words)
    cues = list(subtitles.iter_cues([segment], max_chars=99, max_duration=4.0))
    assert len(cues) == 3


def test_long_segment_without_words_splits_evenly() -> None:
    segment = Segment(text="abcdef", start=0.0, end=6.0)
    cues = list(subtitles.iter_cues([segment], max_chars=2, max_duration=99.0))
    assert [c[0] for c in cues] == ["ab", "cd", "ef"]
    assert cues[1][1] == pytest.approx(2.0)


def test_evenly_split_respects_max_duration() -> None:
    """没有 token 时间戳的长段也不能留下挂满屏的超长字幕。"""
    segment = Segment(text="一" * 40, start=0.0, end=20.0)
    cues = list(subtitles.iter_cues([segment], max_chars=28, max_duration=6.0))
    assert len(cues) > 1
    for _, start, end in cues:
        assert end - start <= 6.0 + 1e-6
    assert cues[0][1] == 0.0
    assert cues[-1][2] == pytest.approx(20.0)


def test_evenly_split_stops_at_one_char_per_cue() -> None:
    """文本太短、时长太长时切到单字为止，不会无限切分。"""
    segment = Segment(text="ab", start=0.0, end=20.0)
    cues = list(subtitles.iter_cues([segment], max_chars=28, max_duration=6.0))
    assert [c[0] for c in cues] == ["a", "b"]


def test_srt_structure_and_numbering() -> None:
    segments = [
        Segment(text="第一句", start=0.0, end=1.0, index=0),
        Segment(text="第二句", start=1.5, end=2.5, index=1),
    ]
    lines = subtitles.to_srt(segments).splitlines()
    assert lines[0] == "1"
    assert lines[1] == "00:00:00,000 --> 00:00:01,000"
    assert lines[2] == "第一句"
    assert lines[3] == ""
    assert lines[4] == "2"
    assert lines[5] == "00:00:01,500 --> 00:00:02,500"


def test_vtt_has_header_and_dot_timestamps() -> None:
    content = subtitles.to_vtt([Segment(text="hi", start=0.0, end=1.0)])
    assert content.startswith("WEBVTT")
    assert "00:00:00.000 --> 00:00:01.000" in content


def test_zero_length_cue_gets_minimal_span() -> None:
    content = subtitles.to_srt([Segment(text="x", start=2.0, end=2.0)])
    assert "00:00:02,000 --> 00:00:02,001" in content


def test_txt_one_line_per_segment() -> None:
    segments = [
        Segment(text="一", start=0.0, end=1.0),
        Segment(text="  ", start=1.0, end=2.0),
        Segment(text="二", start=2.0, end=3.0),
    ]
    assert subtitles.to_txt(segments) == "一\n二\n"


def test_render_json_roundtrip() -> None:
    result = TranscriptionResult(
        segments=[Segment(text="喂", start=0.0, end=1.0, language="yue", index=0)],
        duration=1.0,
        language="yue",
    )
    payload = json.loads(subtitles.render(result, "json"))
    assert payload["language"] == "yue"
    assert payload["text"] == "喂"
    assert payload["segments"][0]["language"] == "yue"


def test_render_rejects_unknown_format() -> None:
    with pytest.raises(ValueError, match="不支持的格式"):
        subtitles.render(TranscriptionResult(), "ass")


@pytest.mark.parametrize("fmt", subtitles.FORMATS)
def test_write_infers_format_from_suffix(tmp_path, fmt: str) -> None:
    result = TranscriptionResult(segments=[Segment(text="测试", start=0.0, end=1.0)], duration=1.0)
    target = subtitles.write(result, tmp_path / f"out.{fmt}")
    assert target.is_file()
    assert target.read_text(encoding="utf-8").strip()


def test_write_creates_parent_directory(tmp_path) -> None:
    result = TranscriptionResult(segments=[Segment(text="x", start=0.0, end=1.0)])
    target = subtitles.write(result, tmp_path / "nested" / "deep" / "out.srt")
    assert target.is_file()
