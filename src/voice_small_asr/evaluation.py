"""固定人工参考语料评测；只用标准库，不加载或下载模型权重。"""

from __future__ import annotations

import hashlib
import json
import math
import unicodedata
from pathlib import Path
from typing import Any


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalize(text: str) -> str:
    """NFKC、casefold、删除 Unicode 标点；保留数字/符号，不繁简转换。"""
    return "".join(
        c
        for c in unicodedata.normalize("NFKC", text).casefold()
        if not unicodedata.category(c).startswith("P")
    )


def edit_distance(reference: list[str], hypothesis: list[str]) -> int:
    previous = list(range(len(hypothesis) + 1))
    for i, expected in enumerate(reference, 1):
        current = [i]
        for j, actual in enumerate(hypothesis, 1):
            current.append(
                min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (expected != actual),
                )
            )
        previous = current
    return previous[-1]


def text_metrics(reference: str, hypothesis: str) -> dict[str, Any]:
    ref, hyp = normalize(reference), normalize(hypothesis)
    result: dict[str, Any] = {}
    for name, expected, actual in (
        ("cer", list("".join(ref.split())), list("".join(hyp.split()))),
        ("wer", ref.split(), hyp.split()),
    ):
        errors = edit_distance(expected, actual)
        result[name] = {
            "errors": errors,
            "reference_units": len(expected),
            "rate": errors / len(expected) if expected else None,
        }
    return result


def _segments(segments: list[dict[str, Any]]) -> list[dict[str, Any]]:
    previous = -1.0
    for segment in segments:
        start, end = segment["start"], segment["end"]
        if (
            not isinstance(start, (int, float))
            or not isinstance(end, (int, float))
            or not math.isfinite(start)
            or not math.isfinite(end)
            or start < 0
            or end <= start
            or start < previous
        ):
            raise ValueError("segments 必须按 start 排序，且时间为有限、非负、正长度秒数")
        if not isinstance(segment.get("text"), str):
            raise ValueError("segment.text 必须是字符串")
        previous = start
    return segments


def timing_metrics(
    reference: list[dict[str, Any]], hypothesis: list[dict[str, Any]]
) -> dict[str, Any]:
    """时间重叠覆盖指标，不将其冒充语义对齐或词级强制对齐。"""
    _segments(reference)
    _segments(hypothesis)
    missing = 0
    start_errors, end_errors = [], []
    for ref in reference:
        overlaps = [
            hyp
            for hyp in hypothesis
            if hyp["text"].strip() and min(ref["end"], hyp["end"]) > max(ref["start"], hyp["start"])
        ]
        if not overlaps:
            missing += 1
            continue
        start_errors.append(abs(min(h["start"] for h in overlaps) - ref["start"]))
        end_errors.append(abs(max(h["end"] for h in overlaps) - ref["end"]))
    return {
        "method": "positive_time_overlap_envelope_v1",
        "reference_segments": len(reference),
        "missed_segments": missing,
        "missed_segment_rate": missing / len(reference) if reference else None,
        "matched_segments": len(start_errors),
        "start_mae_seconds": sum(start_errors) / len(start_errors) if start_errors else None,
        "end_mae_seconds": sum(end_errors) / len(end_errors) if end_errors else None,
    }


def evaluate(manifest_path: Path, predictions: dict[str, Any]) -> dict[str, Any]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema_version") != 1 or not manifest.get("corpus_id"):
        raise ValueError("manifest 需要 schema_version=1 和 corpus_id")
    if not manifest.get("items"):
        raise ValueError("manifest.items 不能为空")
    if not predictions.get("model_id") or not isinstance(predictions.get("config"), dict):
        raise ValueError("predictions 需要 model_id 和 config 对象")
    supplied = predictions.get("items", [])
    by_id = {item["id"]: item for item in supplied}
    ids = [item["id"] for item in manifest["items"]]
    if len(by_id) != len(supplied) or len(set(ids)) != len(ids):
        raise ValueError("重复的语料或预测 id")
    if set(by_id) - set(ids):
        raise ValueError("预测包含 manifest 中不存在的 id")
    rows = []
    for item in manifest["items"]:
        row: dict[str, Any] = {"id": item["id"], "tags": item.get("tags", [])}
        rows.append(row)
        audio = manifest_path.parent / item["audio"]
        if not audio.is_file():
            row.update(status="blocked", reason="missing_audio")
            continue
        row["audio_sha256"] = sha256_file(audio)
        if not item.get("audio_sha256") or row["audio_sha256"] != item["audio_sha256"]:
            row.update(status="blocked", reason="missing_or_mismatched_audio_sha256")
            continue
        if item.get("annotation_status") != "human_verified" or not isinstance(
            item.get("reference_text"), str
        ):
            row.update(status="blocked", reason="missing_human_reference")
            continue
        pred = by_id.get(item["id"])
        if pred is None:
            row.update(status="blocked", reason="missing_prediction")
            continue
        if pred.get("audio_sha256") != row["audio_sha256"]:
            row.update(status="blocked", reason="prediction_audio_sha256_mismatch")
            continue
        if not isinstance(pred.get("text"), str):
            raise ValueError("prediction.text 必须是字符串")
        row.update(status="scored", **text_metrics(item["reference_text"], pred["text"]))
        if "reference_segments" in item:
            if "segments" not in pred:
                row.update(status="blocked", reason="missing_prediction_segments")
            else:
                row["timing"] = timing_metrics(item["reference_segments"], pred["segments"])
    scored = [row for row in rows if row["status"] == "scored"]
    aggregate = {}
    for metric in ("cer", "wer"):
        errors = sum(row[metric]["errors"] for row in scored)
        units = sum(row[metric]["reference_units"] for row in scored)
        aggregate[metric] = {
            "errors": errors,
            "reference_units": units,
            "rate": errors / units if units else None,
        }
    return {
        "schema_version": 1,
        "corpus_id": manifest["corpus_id"],
        "manifest_sha256": sha256_file(manifest_path),
        "model_id": predictions["model_id"],
        "config": predictions["config"],
        "model_files": predictions.get("model_files", {}),
        "normalization": "nfkc_casefold_drop_unicode_punctuation_v1",
        "wer_tokenization": "whitespace (Chinese/Cantonese use CER as primary)",
        "status": "complete" if len(scored) == len(rows) else "incomplete",
        "quality_gate": "not_evaluated",
        "total_items": len(rows),
        "scored_items": len(scored),
        "aggregate": aggregate,
        "items": rows,
    }
