#!/usr/bin/env python3
"""评估已有预测或运行本地模型；完整评测退出 0，缺语料退出 2。"""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict
from pathlib import Path

from voice_small_asr.evaluation import evaluate, sha256_file


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--predictions", type=Path)
    mode.add_argument("--run-model", action="store_true")
    parser.add_argument("--config", type=Path, help="模型模式 ASRConfig JSON（含可选 vad）")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.predictions:
        if args.config:
            parser.error("已有预测模式使用预测 JSON 内的 config，不接受 --config")
        predictions = json.loads(args.predictions.read_text(encoding="utf-8"))
    else:
        from voice_small_asr.config import ASRConfig, VADConfig
        from voice_small_asr.engine import Transcriber
        from voice_small_asr.models import ASR_MODEL

        config_data = json.loads(args.config.read_text(encoding="utf-8")) if args.config else {}
        config_data["vad"] = VADConfig(**config_data.get("vad", {}))
        config = ASRConfig(**config_data)
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
        predictions = {"model_id": ASR_MODEL.name, "config": asdict(config), "items": []}
        transcriber = None
        for item in manifest["items"]:
            audio = args.manifest.parent / item["audio"]
            if not audio.is_file() or item.get("annotation_status") != "human_verified":
                continue
            checksum = sha256_file(audio)
            if checksum != item.get("audio_sha256"):
                continue
            if transcriber is None:
                transcriber = Transcriber(config, allow_download=False)
                predictions["model_files"] = {
                    name: sha256_file(getattr(transcriber.paths, name))
                    for name in ("asr_model", "tokens", "vad_model")
                }
            predictions["items"].append(
                {
                    "id": item["id"],
                    "audio_sha256": checksum,
                    **transcriber.transcribe(audio).to_dict(),
                }
            )
        prediction_path = args.output.with_suffix(".predictions.json")
        prediction_path.parent.mkdir(parents=True, exist_ok=True)
        prediction_path.write_text(
            json.dumps(predictions, ensure_ascii=False, indent=2, default=str) + "\n",
            encoding="utf-8",
        )
    report = evaluate(args.manifest, predictions)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, default=str) + "\n", encoding="utf-8"
    )
    print(f"{report['status']}: {report['scored_items']}/{report['total_items']} → {args.output}")
    return 0 if report["status"] == "complete" else 2


if __name__ == "__main__":
    raise SystemExit(main())
