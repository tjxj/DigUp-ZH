#!/bin/bash
# Launch DigUp-ZH against explicit test folders, with a separate index and settings.
#   scripts/dev-run.sh -debugQuery "报销" -debugSnapshot /tmp/panel.png -debugQuit YES
# ROOTS=a:b:c overrides test folders; ROOTS= launches with none (fresh setup).
# INDEX, MODELS, SUITE and APP may override the corresponding development paths.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "${DIGUP_WORKER_DIR+x}" ]]; then
  echo "DIGUP_WORKER_DIR 已停用，请移除此变量；本项目使用内置 Qwen 模型。" >&2
  exit 1
fi
TB="${TESTBED:-$HOME/DigUpTestbed}"
INDEX="${INDEX:-$PWD/.dev/app-index}"
MODELS="${MODELS:-$PWD/.dev/models}"
SUITE="${SUITE:-com.tjxj.DigUp-ZH.dev}"

# Reuse local model files without downloading. Prefer the release model directory,
# then the pinned Hugging Face cache. Copies remain separate from user model storage.
HUB="${HF_HUB_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}/hub}"
SNAPSHOT="$HUB/models--DevQuasar--Qwen.Qwen3-VL-Embedding-2B-GGUF/snapshots/6a1b927414664e0e17dd379913e3416a1ae1b48d"
if [[ "$MODELS" == "$PWD/.dev/models" ]]; then
  mkdir -p "$MODELS"
  for file in Qwen.Qwen3-VL-Embedding-2B.Q4_K_M.gguf mmproj-Qwen.Qwen3-VL-Embedding-2B.f16.gguf; do
    if [[ ! -e "$MODELS/$file" ]]; then
      for source in "${MODEL_DIR:-$PWD/.models}" "$SNAPSHOT"; do
        if [[ -f "$source/$file" ]]; then
          cp -cL "$source/$file" "$MODELS/$file"
          break
        fi
      done
    fi
  done
fi

# Stop only an earlier run of this exact development app, keeping installed copies alone.
APP="${APP:-build.noindex/DigUp-ZH.app}"
EXE="$(cd "$APP" && pwd -P)/Contents/MacOS/DigUp-ZH"
for pid in $(pgrep -x DigUp-ZH || true); do
  [[ "$(ps -o comm= -p "$pid")" == "$EXE" ]] && kill "$pid" && sleep 0.5
done
ARGS=(-indexDir "$INDEX" -modelsDir "$MODELS" -defaultsSuite "$SUITE")
if [[ -z "${ROOTS+set}" ]]; then
  ARGS+=(-roots "$TB/real:$TB/synthetic:$TB/traps")
elif [[ -n "$ROOTS" ]]; then
  ARGS+=(-roots "$ROOTS")
fi
open -n "$APP" --args "${ARGS[@]}" "$@"
