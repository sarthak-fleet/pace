# Pace-tuned planner v1 — training plan

Status: **export wired** — opt-in toggle in Settings → Models writes anonymized JSONL locally; copy into repo with `scripts/export-pace-tuned-turns.sh`. LoRA run still waits on enough collected turns.

## Target

- Base: `mlx-community/Qwen3-4B-Instruct-2507-bf16`
- Output: `pace-ai/pace-planner-v1` (HuggingFace + Sparkle manifest)
- Ship path: `RemoteModelManifestURL` or Info.plist `BundledMLXPlannerModelIdentifier` bump

## Dataset

1. Enable **Settings → Models → Contribute anonymized planner turns** (default OFF).
2. Use Pace locally — local planner turns append to `~/Library/Application Support/Pace/pace-tuned-turns.jsonl` (emails, phone numbers, home paths redacted; cloud bridge + research skipped).
3. Copy into the repo: `bash scripts/export-pace-tuned-turns.sh` → `evals/pace-tuned-export/export-YYYYMMDD.jsonl`.
4. Mix with existing `evals/fm-fixtures/*.txt` converted to v10 JSON envelope shape.
5. Hold out `evals/fm-fixtures-holdout/` — never train on holdout.

## Train

```bash
bash scripts/train-pace-tuned-model.sh --check
# follow printed mlx_lm.lora command after dataset exists
```

## Eval gate (must pass before default switch)

```bash
bash scripts/eval-v10-gate.sh
PACE_RUN_MLX_EVAL=1 bash scripts/eval-v10-gate.sh
python3 scripts/eval-planners.py --models <candidate-id>
```

Update `PaceBundledModelsSettingsTests.shippingDefaults` pin when the candidate wins.

## Ship

```bash
bash scripts/train-pace-tuned-model.sh --emit-manifest pace-ai/pace-planner-v1 > remote-model-manifest.json
```

Host manifest → set `RemoteModelManifestURL` in Info.plist → Sparkle release.
