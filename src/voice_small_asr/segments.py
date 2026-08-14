"""识别结果的数据结构。

这些类型构成本库对外的稳定契约，集成方按它们消费结果即可，
不需要接触 sherpa-onnx 的原生对象。
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True, slots=True)
class Word:
    """一个 token 及其时间范围（秒，相对整段音频起点）。

    粒度随语言而变：中文、日文、粤语为单字，英文为 subword 或整词。
    """

    text: str
    start: float
    end: float

    @property
    def duration(self) -> float:
        return max(0.0, self.end - self.start)

    def to_dict(self) -> dict[str, Any]:
        return {"text": self.text, "start": round(self.start, 3), "end": round(self.end, 3)}


@dataclass(frozen=True, slots=True)
class Segment:
    """一个语音段（通常对应一句话）的识别结果。

    Attributes:
        text: 识别文本。
        start: 段起点（秒）。
        end: 段终点（秒）。
        words: token 级时间戳，可能为空。
        language: 模型判定或调用方指定的语言代码。
        is_final: ``False`` 表示这是流式过程中的局部结果，
            后续会被同一句的最终结果替换；集成方可据此决定是否覆盖 UI。
        index: 最终段的序号，从 0 开始；局部结果为 ``-1``。
    """

    text: str
    start: float
    end: float
    words: tuple[Word, ...] = ()
    language: str = ""
    is_final: bool = True
    index: int = -1

    @property
    def duration(self) -> float:
        return max(0.0, self.end - self.start)

    def to_dict(self) -> dict[str, Any]:
        return {
            "index": self.index,
            "text": self.text,
            "start": round(self.start, 3),
            "end": round(self.end, 3),
            "language": self.language,
            "is_final": self.is_final,
            "words": [w.to_dict() for w in self.words],
        }


@dataclass(slots=True)
class TranscriptionResult:
    """整段音频的识别结果。"""

    segments: list[Segment] = field(default_factory=list)
    #: 音频总时长（秒）。
    duration: float = 0.0
    #: 调用方请求的语言（``auto`` 时为 ``auto``）。
    language: str = "auto"

    @property
    def text(self) -> str:
        """拼接所有最终段的文本。"""
        return " ".join(s.text for s in self.segments if s.text).strip()

    def to_dict(self) -> dict[str, Any]:
        return {
            "language": self.language,
            "duration": round(self.duration, 3),
            "text": self.text,
            "segments": [s.to_dict() for s in self.segments],
        }

    def to_json(self, *, indent: int = 2) -> str:
        return json.dumps(self.to_dict(), ensure_ascii=False, indent=indent)

    def __len__(self) -> int:
        return len(self.segments)

    def __iter__(self):
        return iter(self.segments)
