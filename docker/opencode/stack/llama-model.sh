#!/usr/bin/env bash
# Resolve a llama.cpp GGUF from the local Ollama store, or pass a standalone
# file through. Prints the path, or an `export LLAMA_MODEL_PATH=...` line.
#
#   ./stack/llama-model.sh --export
#   eval "$(./stack/llama-model.sh --export)"
#
#   ./stack/llama-model.sh --gguf /models/qwen3.5-4b.Q4_K_M.gguf
#   ./stack/llama-model.sh --projector
#
# The default Ollama manifest is qwen3.5:4b. It reads the manifest by media
# type rather than a hard-coded blob name. It never copies, chmods or chowns
# the weights.
set -euo pipefail

ollama_root="${OLLAMA_MODELS:-$HOME/.ollama/models}"
gguf=""
projector=0
export_line=0
uid="${LLAMA_UID:-1000}"
gid="${LLAMA_GID:-1000}"

usage() {
  cat <<'EOF'
Usage: llama-model.sh [options]

  --ollama-root DIR   Ollama models root (default: $OLLAMA_MODELS or ~/.ollama/models)
  --gguf PATH         Use a standalone GGUF instead of the Ollama manifest
  --projector         Print the Ollama vision projector blob instead of the model
  --export            Print `export LLAMA_MODEL_PATH='...'`
  -h, --help          Show this help
EOF
}

die() { echo "llama-model: $*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --ollama-root) ollama_root="${2:?--ollama-root needs a value}"; shift 2 ;;
    --gguf) gguf="${2:?--gguf needs a value}"; shift 2 ;;
    --projector) projector=1; shift ;;
    --export) export_line=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

absolute() {
  # Works for paths that do not exist yet.
  realpath -m -- "$1"
}

print_path() {
  local path="$1"
  if ((export_line)); then
    printf "export LLAMA_MODEL_PATH='%s'\n" "$path"
  else
    printf '%s\n' "$path"
  fi
}

warn_if_unreadable() {
  local path="$1"
  local owner_uid owner_gid mode owner_bits group_bits other_bits
  owner_uid="$(stat -c %u -- "$path")"
  owner_gid="$(stat -c %g -- "$path")"
  mode="$(stat -c %a -- "$path")"
  # Last three octal digits are owner/group/other.
  mode="${mode: -3}"
  owner_bits="${mode:0:1}"
  group_bits="${mode:1:1}"
  other_bits="${mode:2:1}"

  if [[ "$owner_uid" == "$uid" ]]; then
    (( (10#$owner_bits & 4) != 0 )) && return 0
  elif [[ "$owner_gid" == "$gid" ]]; then
    (( (10#$group_bits & 4) != 0 )) && return 0
  else
    (( (10#$other_bits & 4) != 0 )) && return 0
  fi

  echo "llama-model: warning: $path is not readable by UID $uid / GID $gid." >&2
  echo "llama-model: set LLAMA_UID and LLAMA_GID to a user that can read it; not changing host permissions." >&2
}

if [[ -n "$gguf" ]]; then
  path="$(absolute "$gguf")"
  print_path "$path"
  exit 0
fi

manifest="$ollama_root/manifests/registry.ollama.ai/library/qwen3.5/4b"
[[ -f "$manifest" ]] || die "Ollama manifest not found: $manifest (use --gguf PATH for a standalone file)"

media="application/vnd.ollama.image.model"
((projector)) && media="application/vnd.ollama.image.projector"

digest="$(jq -r --arg media "$media" '
  .layers[] | select(.mediaType == $media) | .digest
' "$manifest" | head -n 1)"
[[ -n "$digest" && "$digest" != "null" ]] || die "no $media layer in $manifest"

blob="$ollama_root/blobs/${digest/sha256:/sha256-}"
[[ -f "$blob" ]] || die "Ollama blob missing: $blob (use --gguf PATH for a standalone file)"
[[ -r "$blob" ]] || die "Ollama blob is not readable: $blob"

warn_if_unreadable "$blob"
print_path "$(absolute "$blob")"
