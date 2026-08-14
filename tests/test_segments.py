"""结果数据结构测试（不依赖模型）。"""

from __future__ import annotations

import json

from voice_small_asr.segments import Segment, TranscriptionResult, Word


def test_word_duration() -> None:
    assert Word(text="喂", start=1.0, end=1.5).duration == 0.5


def test_word_duration_never_negative() -> None:
    assert Word(text="x", start=2.0, end=1.0).duration == 0.0


def test_word_is_immutable() -> None:
    word = Word(text="a", start=0.0, end=1.0)
    try:
        word.text = "b"  # type: ignore[misc]
    except AttributeError:
        return
    raise AssertionError("Word 应当是不可变的")


def test_segment_defaults() -> None:
    segment = Segment(text="你好", start=0.0, end=1.0)
    assert segment.words == ()
    assert segment.is_final is True
    assert segment.index == -1
    assert segment.language == ""


def test_segment_to_dict_includes_words() -> None:
    segment = Segment(
        text="喂",
        start=0.0,
        end=1.0,
        words=(Word(text="喂", start=0.1, end=0.4),),
        language="yue",
        index=3,
    )
    payload = segment.to_dict()
    assert payload["index"] == 3
    assert payload["language"] == "yue"
    assert payload["words"] == [{"text": "喂", "start": 0.1, "end": 0.4}]


def test_result_text_joins_segments() -> None:
    result = TranscriptionResult(
        segments=[
            Segment(text="第一句", start=0.0, end=1.0),
            Segment(text="第二句", start=1.0, end=2.0),
        ]
    )
    assert result.text == "第一句 第二句"


def test_result_text_ignores_blank_segments() -> None:
    result = TranscriptionResult(
        segments=[
            Segment(text="有内容", start=0.0, end=1.0),
            Segment(text="", start=1.0, end=2.0),
        ]
    )
    assert result.text == "有内容"


def test_result_len_and_iter() -> None:
    segments = [Segment(text=f"s{i}", start=float(i), end=i + 1.0) for i in range(3)]
    result = TranscriptionResult(segments=segments)
    assert len(result) == 3
    assert [s.text for s in result] == ["s0", "s1", "s2"]


def test_result_to_json_is_valid_utf8_json() -> None:
    result = TranscriptionResult(
        segments=[Segment(text="唔係", start=0.0, end=1.0)], duration=1.0, language="yue"
    )
    payload = json.loads(result.to_json())
    assert payload["duration"] == 1.0
    assert payload["segments"][0]["text"] == "唔係"
    assert "唔係" in result.to_json(), "中文不应被转义成 \\u 序列"


def test_empty_result() -> None:
    result = TranscriptionResult()
    assert len(result) == 0
    assert result.text == ""
    assert result.duration == 0.0
