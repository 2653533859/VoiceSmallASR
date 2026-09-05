"""Synthetic evaluator checks; these are not real model quality results."""

import json
from pathlib import Path

import pytest

from voice_small_asr.evaluation import evaluate, sha256_file, text_metrics, timing_metrics


def test_text_metrics_normalization_and_errors():
    scores = text_metrics("Ａbc，你好！", "abc你号")
    assert scores["cer"] == {"errors": 1, "reference_units": 5, "rate": 0.2}
    assert text_metrics("one two", "one extra two")["wer"]["rate"] == 0.5
    assert text_metrics("", "inserted")["cer"]["rate"] is None
    assert text_metrics("你好", "")["cer"]["rate"] == 1
    assert text_metrics("안녕 세계", "안녕 세상")["wer"]["rate"] == 0.5


def test_timing_missing_and_boundary_error():
    result = timing_metrics(
        [{"start": 1, "end": 2, "text": "a"}, {"start": 8, "end": 9, "text": "b"}],
        [{"start": 1.25, "end": 2.5, "text": "a"}],
    )
    assert result["missed_segments"] == 1
    assert result["missed_segment_rate"] == 0.5
    assert result["start_mae_seconds"] == 0.25
    assert result["end_mae_seconds"] == 0.5
    assert timing_metrics([], [])["start_mae_seconds"] is None
    with pytest.raises(ValueError):
        timing_metrics([{"start": 1, "end": float("nan"), "text": "a"}], [])


def fixture_data(tmp_path: Path):
    # Only evaluator file provenance is tested; bytes are not playable speech.
    audio = tmp_path / "synthetic.wav"
    audio.write_bytes(b"synthetic evaluator fixture, not real speech")
    checksum = sha256_file(audio)
    manifest = {
        "schema_version": 1,
        "corpus_id": "synthetic-test-only",
        "items": [
            {
                "id": "test",
                "audio": audio.name,
                "audio_sha256": checksum,
                "annotation_status": "human_verified",
                "reference_text": "one two",
                "reference_segments": [{"start": 0, "end": 2, "text": "one two"}],
            }
        ],
    }
    predictions = {
        "model_id": "synthetic-test",
        "config": {},
        "items": [
            {
                "id": "test",
                "audio_sha256": checksum,
                "text": "one",
                "segments": [{"start": 0, "end": 2, "text": "one"}],
            }
        ],
    }
    path = tmp_path / "manifest.json"
    path.write_text(json.dumps(manifest))
    return path, manifest, predictions


def test_complete_report_contains_provenance(tmp_path):
    path, _, predictions = fixture_data(tmp_path)
    report = evaluate(path, predictions)
    assert report["status"] == "complete"
    assert report["quality_gate"] == "not_evaluated"
    assert report["aggregate"]["wer"]["rate"] == 0.5
    assert report["manifest_sha256"] == sha256_file(path)
    assert report["items"][0]["timing"]["missed_segments"] == 0


@pytest.mark.parametrize(
    "failure,reason",
    [
        ("audio", "missing_audio"),
        ("reference", "missing_human_reference"),
        ("hash", "missing_or_mismatched_audio_sha256"),
        ("prediction_hash", "prediction_audio_sha256_mismatch"),
        ("prediction", "missing_prediction"),
        ("segments", "missing_prediction_segments"),
    ],
)
def test_incomplete_is_never_a_pass(tmp_path, failure, reason):
    path, manifest, predictions = fixture_data(tmp_path)
    if failure == "audio":
        (tmp_path / "synthetic.wav").unlink()
    elif failure == "reference":
        manifest["items"][0]["annotation_status"] = "planned"
    elif failure == "hash":
        manifest["items"][0]["audio_sha256"] = "wrong"
    elif failure == "prediction_hash":
        predictions["items"][0]["audio_sha256"] = "wrong"
    elif failure == "prediction":
        predictions["items"] = []
    else:
        del predictions["items"][0]["segments"]
    path.write_text(json.dumps(manifest))
    report = evaluate(path, predictions)
    assert report["status"] == "incomplete"
    assert report["scored_items"] == 0
    assert report["items"][0]["reason"] == reason
    assert report["aggregate"]["wer"]["rate"] is None


def test_duplicate_and_unknown_ids_rejected(tmp_path):
    path, _, predictions = fixture_data(tmp_path)
    predictions["items"] *= 2
    with pytest.raises(ValueError, match="重复"):
        evaluate(path, predictions)
    predictions["items"] = [{"id": "unknown"}]
    with pytest.raises(ValueError, match="不存在"):
        evaluate(path, predictions)
