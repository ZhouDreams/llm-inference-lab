#!/usr/bin/env bash
#
# start.sh — 启动 vLLM 服务（docker compose up 的薄包装）
#
# 用法：
#   ./scripts/start.sh                                    # 默认：manifest 第一个 enabled 模型
#   ./scripts/start.sh -m awq                             # 模型关键词（对 manifest 里 id 做包含匹配）
#   ./scripts/start.sh -m Qwen/Qwen3.8-27B                # 也可以传完整 id
#   ./scripts/start.sh -m awq --max-model-len 8192        # 透传 vLLM 参数
#   ./scripts/start.sh --max-model-len 16384              # 只调参数不换模型
#
# 说明：
#   · -m/--model 的值同时用于选择模型与 served-model-name（取 id 的最后一段）
#   · --model <路径> 与 -m 语义不同：--model 直接把参数透传给 vllm（含路径/任意参数）
#   · 其余参数（--max-model-len、--gpu-memory-utilization …）原样透传给 vLLM
#   · 模型必须已在 manifest 中且 enabled，且本地 models/<org>/<name>/ 已有权重
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/models/manifest.json"
COMPOSE_FILE="$ROOT/docker-compose.yml"

# ---------------------------------- 参数解析 ----------------------------------

model_selector=""
extra_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--model)
      [[ $# -ge 2 ]] || { echo "✗ $1 需要一个值" >&2; exit 1; }
      model_selector="$2"; shift 2 ;;
    -m*)
      model_selector="${1#-m}"; shift ;;                      # -mawq 连写
    --model=*)
      model_selector="${1#*=}"; shift ;;
    -h|--help)
      sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)
      extra_args+=("$1"); shift ;;
  esac
done

# ---------------------------------- 前置检查 ----------------------------------

[[ -f "$MANIFEST" ]]  || { echo "✗ 找不到 $MANIFEST" >&2; exit 1; }
[[ -f "$COMPOSE_FILE" ]] || { echo "✗ 找不到 $COMPOSE_FILE" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || { echo "✗ docker 未安装" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "✗ 需要 docker compose V2（docker compose 子命令）" >&2; exit 1; }

# ---------------------------------- 模型解析 ----------------------------------

# 从 manifest 选模型：keyword 匹配 id（不区分大小写），不写死任何模型
select_model() {
  local selector="$1"
  python3 - "$MANIFEST" "$selector" <<'PYEOF'
import json, sys, os

manifest_path, selector = sys.argv[1], sys.argv[2]
root = os.path.dirname(os.path.dirname(os.path.abspath(manifest_path)))

try:
    with open(manifest_path, encoding="utf-8") as f:
        m = json.load(f)
except Exception as e:
    sys.exit(f"manifest 解析失败：{e}")

models = [e for e in m.get("models", []) if e.get("enabled", True)]
if not models:
    sys.exit("manifest 中没有 enabled 的模型")

if selector:
    s = selector.lower()
    cands = [e for e in models if s in e["id"].lower()]
    if len(cands) == 0:
        sys.exit(f"manifest 中没有匹配 \"{selector}\" 的 enabled 模型")
    if len(cands) > 1:
        sys.exit("匹配到多个模型，请用更长的关键词：\n  " + "\n  ".join(e["id"] for e in cands))
    entry = cands[0]
else:
    entry = models[0]

repo_id = entry["id"]
local_dir = os.path.join(root, "models", *repo_id.split("/"))
if not os.path.isdir(local_dir):
    sys.exit(f"本地未找到权重目录：{local_dir}\n先下载：huggingface-cli download {repo_id} --local-dir models/{repo_id}")

print(f"/models/{repo_id}")
PYEOF
}

if ! model_path="$(select_model "$model_selector")"; then
  echo "$model_path" >&2
  exit 1
fi
served_name="$(basename "$model_path")"

# ---------------------------------- 组装并启动 ----------------------------------

export VLLM_MODEL="$model_path"
VLLM_EXTRA_ARGS="${extra_args[*]}"
export VLLM_EXTRA_ARGS

echo "▸ 模型     : $model_path"
echo "▸ 别名     : $served_name"
echo "▸ 透传参数 : ${VLLM_EXTRA_ARGS:-(无)}"
echo

cd "$ROOT"
exec docker compose -f "$COMPOSE_FILE" up -d
