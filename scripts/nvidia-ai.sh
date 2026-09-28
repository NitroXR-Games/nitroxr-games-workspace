#!/usr/bin/env bash
#
# Generate 3D assets with NVIDIA Trellis (build.nvidia.com) and optionally
# publish them straight into the NitroXR cloud (R2 + registry).
#
# Single generation:
#   scripts/nvidia-ai.sh --prompt "low-poly concrete maze wall" --out wall.json
#
# Generate + publish (decode GLB, PUT to R2, POST registry):
#   scripts/nvidia-ai.sh --prompt "..." --out wall.json --register \
#     --asset-id maze_wall_concrete --game maze
#
# Batch file (one `asset_id|prompt` per line, `#` comments allowed):
#   scripts/nvidia-ai.sh --batch maze-assets.txt --game maze --register
#
# Required: NVIDIA token JSON `{"NVIDIA_API_TOKEN": "..."}` (default:
# <repo-root>/.credentials/nvidia-api-token.json, override with --token-file).
# --register additionally needs Cloudflare creds
# `{"CLOUDFLARE_API_TOKEN": "..."}` (--cf-token-file) and resolves the
# account id via the API, so nothing sensitive lives in flags.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_FILE="${SCRIPT_DIR}/../.credentials/nvidia-api-token.json"
CF_TOKEN_FILE="${SCRIPT_DIR}/../.credentials/cloudflare-nitroxr-credentials.json"
INVOKE_URL="${INVOKE_URL:-https://ai.api.nvidia.com/v1/genai/microsoft/trellis}"
OUT=""
PROMPT=""
BATCH=""
REGISTER=0
ASSET_ID=""
ORG="nitroxr-games"
GAME="maze"
KIND="models"
SEED=0
STEPS=25

usage() {
  sed -n '2,/^set /p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prompt) PROMPT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --batch) BATCH="$2"; shift 2 ;;
    --register) REGISTER=1; shift ;;
    --asset-id) ASSET_ID="$2"; shift 2 ;;
    --org) ORG="$2"; shift 2 ;;
    --game) GAME="$2"; shift 2 ;;
    --kind) KIND="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;
    --steps) STEPS="$2"; shift 2 ;;
    --token-file) TOKEN_FILE="$2"; shift 2 ;;
    --cf-token-file) CF_TOKEN_FILE="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "unknown flag: $1" >&2; usage 1 ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 1; }; }
need curl
need python3

# Minimal jq replacement (only dependency besides curl is python3).
jget() { python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], '') or '')" "$1" "$2"; }

[ -f "$TOKEN_FILE" ] || { echo "NVIDIA token file not found: $TOKEN_FILE" >&2; exit 1; }
NVIDIA_TOKEN="$(jget "$TOKEN_FILE" NVIDIA_API_TOKEN)"
[ -n "$NVIDIA_TOKEN" ] || { echo "NVIDIA_API_TOKEN missing in $TOKEN_FILE" >&2; exit 1; }

# Generate one asset with retries on 5xx. Args: prompt, out_path, seed
generate() {
  local prompt="$1" out_path="$2" seed="$3"
  local payload body_file code attempt
  payload="$(PROMPT_TEXT="$prompt" SLAT="$STEPS" SS_STEPS="$STEPS" SEED_N="$seed" python3 -c "import json,os; print(json.dumps({'prompt': os.environ['PROMPT_TEXT'], 'slat_cfg_scale': 3, 'ss_cfg_scale': 7.5, 'slat_sampling_steps': int(os.environ['SLAT']), 'ss_sampling_steps': int(os.environ['SS_STEPS']), 'seed': int(os.environ['SEED_N'])}))")"
  body_file="$(mktemp)"
  attempt=1
  while [ "$attempt" -le 3 ]; do
    code="$(curl --silent --show-error --max-time 900 --request POST \
      --url "$INVOKE_URL" \
      --header "Authorization: Bearer ${NVIDIA_TOKEN}" \
      --header 'Accept: application/json' \
      --header 'Content-Type: application/json' \
      --data "$payload" \
      --output "$body_file" \
      --write-out '%{http_code}')" || code="000"
    if [ "$code" = "200" ]; then
      mv "$body_file" "$out_path"
      echo "saved: $out_path ($(python3 -c "import json; print(len(json.load(open('$out_path'))['artifacts']))") artifact(s))"
      return 0
    fi
    echo "attempt $attempt: HTTP $code for: $prompt" >&2
    attempt=$((attempt + 1))
    sleep 10
  done
  echo "generation failed after 3 attempts; response kept at: ${out_path}.failed" >&2
  head -c 500 "$body_file" >&2; echo >&2
  cp "$body_file" "${out_path}.failed"
  rm -f "$body_file"
  return 1
}

# Publish one generated response: decode GLB, validate, PUT to R2, POST registry.
# Args: response_path, asset_id
publish() {
  local response_path="$1" asset_id="$2"
  [ -f "$CF_TOKEN_FILE" ] || { echo "Cloudflare token file not found: $CF_TOKEN_FILE" >&2; return 1; }
  local key="tmp Glb"
  key="$(python3 - "$response_path" <<'EOF'
import json, base64, struct, sys
d = json.load(open(sys.argv[1]))
raw = base64.b64decode(d['artifacts'][0]['base64'])
magic, ver, length = struct.unpack('<4sII', raw[:12])
assert magic == b'glTF' and ver == 2 and length == len(raw), 'not a valid GLB'
open('/tmp/nitro-publish.glb', 'wb').write(raw)
print(len(raw))
EOF
)" || return 1
  echo "decoded GLB: ${key} bytes"
  local r2_key="${ORG}/${GAME}/${KIND}/${asset_id}.glb"
  local cf_token account_id
  cf_token="$(jget "$CF_TOKEN_FILE" CLOUDFLARE_API_TOKEN)"
  account_id="$(curl --silent --fail -H "Authorization: Bearer ${cf_token}" \
    'https://api.cloudflare.com/client/v4/accounts' |
    python3 -c "import json,sys; print(json.load(sys.stdin)['result'][0]['id'])")" || { echo 'failed to resolve Cloudflare account id' >&2; return 1; }
  curl --silent --show-error --fail -X PUT \
    -H "Authorization: Bearer ${cf_token}" \
    -H 'Content-Type: model/gltf-binary' \
    --data-binary @/tmp/nitro-publish.glb \
    "https://api.cloudflare.com/client/v4/accounts/${account_id}/r2/buckets/nitroxr-games-assets/objects/${r2_key}" >/dev/null \
    || { echo 'R2 upload failed' >&2; return 1; }
  rm -f /tmp/nitro-publish.glb
  echo "uploaded: ${r2_key}"
  local glb_url="https://games-assets.nitroxr.com/${r2_key}"
  local reg_body
  reg_body="$(REG_ID="$asset_id" REG_ORG="$ORG" REG_GAME="$GAME" REG_URL="$glb_url" python3 -c "import json,os; print(json.dumps({'id': os.environ['REG_ID'], 'org': os.environ['REG_ORG'], 'game': os.environ['REG_GAME'], 'type': 'model', 'glb_url': os.environ['REG_URL']}))")"
  curl --silent --show-error --fail -X POST https://cloud.nitroxr.com/assets \
    -H 'Content-Type: application/json' \
    --data "$reg_body" >/dev/null \
    || { echo 'registry update failed' >&2; return 1; }
  echo "registered: ${asset_id} -> ${glb_url}"
}

run_one() {
  local prompt="$1" out_path="$2" asset_id="$3" seed="$4"
  generate "$prompt" "$out_path" "$seed" || return 1
  if [ "$REGISTER" = 1 ]; then
    [ -n "$asset_id" ] || { echo '--register needs --asset-id (or batch with ids)' >&2; return 1; }
    publish "$out_path" "$asset_id" || return 1
  fi
}

if [ -n "$BATCH" ]; then
  [ -f "$BATCH" ] || { echo "batch file not found: $BATCH" >&2; exit 1; }
  n=0
  while IFS='|' read -r asset_id prompt rest; do
    case "$asset_id" in ''|'#'*) continue ;; esac
    [ -n "$prompt" ] || { echo "skipping ${asset_id}: empty prompt" >&2; continue; }
    n=$((n + 1))
    echo "=== [$n] ${asset_id} ==="
    run_one "$prompt" "${asset_id}.json" "$asset_id" "$SEED" || exit 1
  done < "$BATCH"
  echo "done: $n asset(s)"
  exit 0
fi

[ -n "$PROMPT" ] || { echo '--prompt or --batch required' >&2; usage 1; }
[ -n "$OUT" ] || OUT="response-$(date +%s).json"
run_one "$PROMPT" "$OUT" "$ASSET_ID" "$SEED"
