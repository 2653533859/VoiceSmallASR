"""端到端集成测试：真实模型识别中/英/粤/日音频、时间戳、字幕、流式。

模型未下载时整个文件跳过（见 ``conftest.py``）。
"""

from __future__ import annotations

from itertools import pairwise
from pathlib import Path

import pytest

from voice_small_asr import ASRConfig, StreamingTranscriber, Transcriber, audio, subtitles

#: 每种语言的示例音频里必须出现的关键词。
#: 粤语用 唔 / 嘅 这类粤语专有字，确认模型没把粤语转写成书面普通话。
EXPECTED = {
    "zh": ("开饭", "时间"),
    "en": ("tribal", "boy"),
    "ja": ("中学", "弁当"),
    "yue": ("唔", "嘅"),
}


@pytest.mark.parametrize("language", sorted(EXPECTED))
def test_transcribe_each_language(transcriber: Transcriber, test_wavs: Path, language: str) -> None:
    result = transcriber.transcribe(test_wavs / f"{language}.wav")
    assert result.segments, f"{language}.wav 未识别出任何语音段"
    text = result.text
    for keyword in EXPECTED[language]:
        assert keyword in text, f"{language} 识别结果缺少 {keyword!r}：{text!r}"


def test_detected_language_is_reported(transcriber: Transcriber, test_wavs: Path) -> None:
    result = transcriber.transcribe(test_wavs / "yue.wav")
    assert result.segments[0].language == "yue"


def test_explicit_cantonese_keeps_cantonese_characters(test_wavs: Path) -> None:
    result = Transcriber(ASRConfig(language="yue"), allow_download=False).transcribe(
        test_wavs / "yue.wav"
    )
    assert "唔" in result.text
    assert "嘅" in result.text


def test_itn_produces_punctuation(transcriber: Transcriber, test_wavs: Path) -> None:
    result = transcriber.transcribe(test_wavs / "zh.wav")
    assert any(mark in result.text for mark in "。，、？！"), "开启 ITN 后应带标点"


def test_segment_timestamps_are_ordered_and_bounded(
    transcriber: Transcriber, test_wavs: Path
) -> None:
    result = transcriber.transcribe(test_wavs / "en.wav")
    previous_end = 0.0
    for segment in result:
        assert 0.0 <= segment.start < segment.end <= result.duration + 0.05
        assert segment.start >= previous_end - 0.05, "语音段不应重叠"
        previous_end = segment.end


def test_word_timestamps_are_monotonic_within_segment(
    transcriber: Transcriber, test_wavs: Path
) -> None:
    result = transcriber.transcribe(test_wavs / "zh.wav")
    segment = result.segments[0]
    assert segment.words, "应产出 token 级时间戳"
    for previous, current in pairwise(segment.words):
        assert previous.start <= current.start
    assert segment.words[0].start >= segment.start - 0.05
    assert segment.words[-1].end <= segment.end + 0.05


def test_tokens_reconstruct_text(transcriber: Transcriber, test_wavs: Path) -> None:
    """token 拼接应还原识别文本（标点可能只在整句里出现，故用包含判断）。"""
    result = transcriber.transcribe(test_wavs / "yue.wav")
    segment = result.segments[0]
    joined = "".join(word.text for word in segment.words).strip()
    assert joined.rstrip("。") in segment.text


def test_english_tokens_keep_word_spacing(transcriber: Transcriber, test_wavs: Path) -> None:
    """SenseVoice 把词间空格作为独立 token，丢掉它会拼出 "with50"。"""
    result = transcriber.transcribe(test_wavs / "en.wav")
    for segment in result:
        joined = "".join(word.text for word in segment.words).strip()
        assert joined.rstrip(".") in segment.text, f"token 拼接与文本不一致：{joined!r}"
    assert "50" in result.text
    assert "with50" not in result.text


def test_english_subtitle_cues_keep_spacing(transcriber: Transcriber, test_wavs: Path) -> None:
    """字幕条目由 token 拼接而来，同样不能粘连单词。"""
    result = transcriber.transcribe(test_wavs / "en.wav")
    cues = list(subtitles.iter_cues(result.segments, max_chars=8, max_duration=2.0))
    assert cues, "长英文段应被切成多条字幕"
    assert not any("with50" in text for text, _, _ in cues)


def test_segments_are_indexed_consecutively(transcriber: Transcriber, test_wavs: Path) -> None:
    result = transcriber.transcribe(test_wavs / "en.wav")
    assert [s.index for s in result] == list(range(len(result)))


def test_accepts_numpy_input(transcriber: Transcriber, test_wavs: Path) -> None:
    samples = audio.load(test_wavs / "zh.wav")
    assert transcriber.transcribe(samples).text


def test_srt_export_is_wellformed(
    transcriber: Transcriber, test_wavs: Path, tmp_path: Path
) -> None:
    result = transcriber.transcribe(test_wavs / "ja.wav")
    target = subtitles.write(result, tmp_path / "out.srt")
    lines = target.read_text(encoding="utf-8").splitlines()
    assert lines[0] == "1"
    assert " --> " in lines[1]
    assert lines[2].strip()


def test_streaming_produces_final_segment(test_wavs: Path) -> None:
    streamer = StreamingTranscriber(ASRConfig(language="yue"), allow_download=False)
    finals = []
    partials = []
    for chunk in audio.iter_chunks(audio.load(test_wavs / "yue.wav"), chunk_ms=100):
        for segment in streamer.accept(chunk):
            (finals if segment.is_final else partials).append(segment)
    finals.extend(streamer.flush())

    assert finals, "流式识别应产出至少一个最终段"
    assert "唔" in " ".join(s.text for s in finals)
    assert streamer.final_count == len(finals)


def test_streaming_partials_can_be_disabled(test_wavs: Path) -> None:
    config = ASRConfig(language="yue", partial_interval=0.0)
    streamer = StreamingTranscriber(config, allow_download=False)
    produced = []
    for chunk in audio.iter_chunks(audio.load(test_wavs / "yue.wav"), chunk_ms=100):
        produced.extend(streamer.accept(chunk))
    produced.extend(streamer.flush())
    assert produced
    assert all(segment.is_final for segment in produced)


def test_streaming_reset_clears_state(test_wavs: Path) -> None:
    streamer = StreamingTranscriber(ASRConfig(language="yue"), allow_download=False)
    for chunk in audio.iter_chunks(audio.load(test_wavs / "yue.wav"), chunk_ms=100):
        streamer.accept(chunk)
    streamer.flush()
    assert streamer.final_count > 0
    streamer.reset()
    assert streamer.final_count == 0
