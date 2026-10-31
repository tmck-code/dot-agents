#!/usr/bin/env bash
# Resolve named secrets from SOPS+age or a dedicated KeePassXC database into
# host-side env files for the OpenCode stack.
#
# The agent never mounts the encrypted store, the age key, the .kdbx file or the
# decrypted output. Only the host-side Compose interpolation and LiteLLM
# container read these files.
#
#   scripts/opencode-secrets.sh --source sops --file secrets.enc.yaml \
#       --keys GITHUB_APP_ID,ANTHROPIC_API_KEY,LITELLM_MASTER_KEY
#
#   scripts/opencode-secrets.sh --source keepassxc \
#       --db ~/vaults/opencode.kdbx \
#       --entry GITHUB_APP_ID=github/app-id \
#       --entry ANTHROPIC_API_KEY=providers/anthropic
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
source_kind="sops"
sops_file="${OPENCODE_SOPS_FILE:-$repo_root/secrets.enc.yaml}"
keepass_db="${KEEPASSXC_DB:-}"
out_dir="${OPENCODE_SECRETS_OUT:-$repo_root/docker/opencode/stack/secrets}"
age_key_file="${SOPS_AGE_KEY_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt}"

declare -a keys=()
declare -a keepass_entries=()

usage() {
  cat <<'EOF'
Usage: opencode-secrets.sh [options]

  --source sops|keepassxc   Secret backend (default: sops)
  --file PATH               SOPS-encrypted YAML file
  --keys A,B,C              SOPS keys to resolve (repeatable or comma-separated)
  --db PATH                 KeePassXC database
  --entry KEY=ENTRY         KeePassXC entry path (repeatable)
  --out DIR                 Output directory (default: docker/opencode/stack/secrets)

Outputs (mode 0600):
  DIR/stack.env     Compose interpolation: GITHUB_APP_ID, BROKER_ADMIN_TOKEN, ...
  DIR/litellm.env   Provider/LiteLLM keys only: ANTHROPIC_API_KEY, ...

Never commit DIR/. It is ignored by git. Do not mount the .kdbx or age key into
the agent; only the host-side stack reads the resolved files.
EOF
}

split_keys() {
  local raw="$1" item
  local IFS=','
  for item in $raw; do
    item="$(printf '%s' "$item" | xargs)"
    [[ -n "$item" ]] && keys+=("$item")
  done
}

while (($#)); do
  case "$1" in
    --source) source_kind="${2:?--source needs a value}"; shift 2 ;;
    --file) sops_file="${2:?--file needs a value}"; shift 2 ;;
    --keys) split_keys "${2:?--keys needs a value}"; shift 2 ;;
    --db) keepass_db="${2:?--db needs a value}"; shift 2 ;;
    --entry) keepass_entries+=("${2:?--entry needs a value}"); shift 2 ;;
    --out) out_dir="${2:?--out needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "opencode-secrets: unknown option: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$out_dir"
chmod 700 "$out_dir"
stack_env="$out_dir/stack.env"
litellm_env="$out_dir/litellm.env"
umask 077
: > "$stack_env"
: > "$litellm_env"
chmod 600 "$stack_env" "$litellm_env"

write_value() {
  local key="$1" value="$2"
  case "$key" in
    ANTHROPIC_API_KEY|OPENAI_API_KEY|DEEPSEEK_API_KEY|GOOGLE_API_KEY|GROQ_API_KEY|MISTRAL_API_KEY|XAI_API_KEY|LITELLM_MASTER_KEY)
      printf '%s=%s\n' "$key" "$value" >> "$litellm_env"
      ;;
    *)
      printf '%s=%s\n' "$key" "$value" >> "$stack_env"
      ;;
  esac
}

resolve_sops() {
  command -v sops >/dev/null 2>&1 || {
    echo "opencode-secrets: sops is not installed" >&2
    exit 1
  }
  [[ -f "$sops_file" ]] || { echo "opencode-secrets: no such file: $sops_file" >&2; exit 1; }
  [[ -f "$age_key_file" ]] || {
    echo "opencode-secrets: age key not found: $age_key_file" >&2
    echo "Create one with: age-keygen -o \"$age_key_file\" (then chmod 600)" >&2
    exit 1
  }
  (( ${#keys[@]} )) || { echo "opencode-secrets: --keys is required for sops" >&2; exit 1; }
  for key in "${keys[@]}"; do
    value="$(SOPS_AGE_KEY_FILE="$age_key_file" sops decrypt --extract "[\"$key\"]" "$sops_file" 2>/dev/null || true)"
    [[ -n "$value" ]] || { echo "opencode-secrets: missing or undecryptable key: $key" >&2; exit 1; }
    write_value "$key" "$value"
  done
}

resolve_keepass() {
  command -v keepassxc-cli >/dev/null 2>&1 || {
    echo "opencode-secrets: keepassxc-cli is not installed" >&2
    exit 1
  }
  [[ -n "$keepass_db" && -f "$keepass_db" ]] || {
    echo "opencode-secrets: --db must point at a KeePassXC database" >&2
    exit 1
  }
  (( ${#keepass_entries[@]} )) || {
    echo "opencode-secrets: --entry KEY=ENTRY is required for keepassxc" >&2
    exit 1
  }
  for mapping in "${keepass_entries[@]}"; do
    key="${mapping%%=*}"
    entry="${mapping#*=}"
    if [[ -z "$key" || -z "$entry" || "$key" == "$mapping" ]]; then
      echo "opencode-secrets: invalid --entry (want KEY=ENTRY): $mapping" >&2
      exit 1
    fi
    if [[ -n "${KEEPASSXC_PASSWORD:-}" ]]; then
      value="$(printf '%s\n' "$KEEPASSXC_PASSWORD" | keepassxc-cli show -q -a password "$keepass_db" "$entry" 2>/dev/null || true)"
    else
      value="$(keepassxc-cli show -q -a password "$keepass_db" "$entry" 2>/dev/null || true)"
    fi
    [[ -n "$value" ]] || { echo "opencode-secrets: could not read entry: $entry" >&2; exit 1; }
    write_value "$key" "$value"
  done
}

case "$source_kind" in
  sops) resolve_sops ;;
  keepassxc|keepass) resolve_keepass ;;
  *) echo "opencode-secrets: unknown source: $source_kind" >&2; exit 2 ;;
esac

echo "opencode-secrets: wrote $stack_env and $litellm_env (mode 600)" >&2
echo "Next: docker compose -f docker/opencode/stack/docker-compose.yml --env-file $stack_env up -d" >&2
