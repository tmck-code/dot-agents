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
declare -A touched=()
merge=0
pem_spec=""

usage() {
  cat <<'USAGE'
Usage: opencode-secrets.sh [options]

  --source sops|keepassxc   Secret backend (default: sops)
  --file PATH               SOPS-encrypted YAML file
  --keys A,B,C              SOPS keys to resolve (repeatable or comma-separated)
  --db PATH                 KeePassXC database
  --entry KEY=ENTRY         KeePassXC entry path (repeatable)
  --pem ENTRY[:ATTACHMENT]  KeePassXC entry whose attachment is the GitHub App
                            private key (default attachment: github-app.pem).
                            keepassxc only.
  --out DIR                 Output directory (default: docker/opencode/stack/secrets)
  --merge                   Update the named keys in place; keep other values

Outputs (mode 0600), one file per secret where a service needs only that value:
  DIR/litellm-master.key  LITELLM_MASTER_KEY (bare value)
  DIR/broker-admin.token  BROKER_ADMIN_TOKEN (bare value)
  DIR/github-app.pem      --pem attachment
  DIR/litellm.env         Provider keys only: ANTHROPIC_API_KEY, OPENROUTER_API_KEY,
                          GEMINI_API_KEY, ...
  DIR/stack.env           Non-secret settings: GITHUB_APP_ID, ...

By default only the files this run writes are rewritten, using only the
requested keys. With --merge they are updated in place, so existing generated
tokens survive.

Never commit DIR/. It is ignored by git. Do not mount the .kdbx or age key into
the agent; only the host-side stack reads the resolved files.
USAGE
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
    --pem) pem_spec="${2:?--pem needs a value}"; shift 2 ;;
    --out) out_dir="${2:?--out needs a value}"; shift 2 ;;
    --merge) merge=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "opencode-secrets: unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -n "$pem_spec" && "$source_kind" == "sops" ]]; then
  echo "opencode-secrets: --pem needs --source keepassxc" >&2
  exit 2
fi

umask 077
mkdir -p "$out_dir"
chmod 700 "$out_dir"
stack_env="$out_dir/stack.env"
litellm_env="$out_dir/litellm.env"

# Create a file on first use. Without --merge, truncate it once so only files
# this run writes are reset.
prepare_file() {
  local target="$1"
  [[ -n "${touched[$target]:-}" ]] && return 0
  touched[$target]=1
  if (( merge )); then
    touch "$target"
  else
    : > "$target"
  fi
  chmod 600 "$target"
}

# Write a bare value (no KEY=) to its own file.
write_bare() {
  local target="$out_dir/$1" value="$2"
  touched[$target]=1
  printf '%s\n' "$value" > "$target"
  chmod 600 "$target"
}

write_value() {
  local key="$1" value="$2" target
  case "$key" in
    LITELLM_MASTER_KEY)
      write_bare litellm-master.key "$value"
      return 0
      ;;
    BROKER_ADMIN_TOKEN)
      write_bare broker-admin.token "$value"
      return 0
      ;;
    ANTHROPIC_API_KEY|OPENAI_API_KEY|DEEPSEEK_API_KEY|GOOGLE_API_KEY|GROQ_API_KEY|MISTRAL_API_KEY|XAI_API_KEY|OPENROUTER_API_KEY|GEMINI_API_KEY)
      target="$litellm_env"
      ;;
    *)
      target="$stack_env"
      ;;
  esac
  prepare_file "$target"

  if grep -q "^${key}=" "$target"; then
    # Rewrite in place without putting the value in argv (visible in ps).
    local tmp
    tmp="$(mktemp "${target}.XXXXXX")"
    while IFS= read -r line; do
      if [[ "$line" == "$key="* ]]; then
        printf '%s=%s\n' "$key" "$value"
      else
        printf '%s\n' "$line"
      fi
    done < "$target" > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$target"
  else
    printf '%s=%s\n' "$key" "$value" >> "$target"
  fi
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

# Run keepassxc-cli with the password on stdin when KEEPASSXC_PASSWORD is set.
# Otherwise stderr and stdin stay attached so the CLI can prompt.
keepass_run() {
  if [[ -n "${KEEPASSXC_PASSWORD:-}" ]]; then
    printf '%s\n' "$KEEPASSXC_PASSWORD" | keepassxc-cli "$@" 2>/dev/null
  else
    keepassxc-cli "$@"
  fi
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
  (( ${#keepass_entries[@]} )) || [[ -n "$pem_spec" ]] || {
    echo "opencode-secrets: --entry KEY=ENTRY or --pem is required for keepassxc" >&2
    exit 1
  }
  for mapping in "${keepass_entries[@]}"; do
    key="${mapping%%=*}"
    entry="${mapping#*=}"
    if [[ -z "$key" || -z "$entry" || "$key" == "$mapping" ]]; then
      echo "opencode-secrets: invalid --entry (want KEY=ENTRY): $mapping" >&2
      exit 1
    fi
    value="$(keepass_run show -q -a password "$keepass_db" "$entry" || true)"
    [[ -n "$value" ]] || { echo "opencode-secrets: could not read entry: $entry" >&2; exit 1; }
    write_value "$key" "$value"
  done
  if [[ -n "$pem_spec" ]]; then
    resolve_keepass_pem
  fi
}

resolve_keepass_pem() {
  local entry="${pem_spec%%:*}" attachment="github-app.pem"
  [[ "$pem_spec" == *:* ]] && attachment="${pem_spec#*:}"
  if [[ -z "$entry" || -z "$attachment" ]]; then
    echo "opencode-secrets: invalid --pem (want ENTRY[:ATTACHMENT]): $pem_spec" >&2
    exit 1
  fi
  local pem="$out_dir/github-app.pem"
  keepass_run attachment-export -q "$keepass_db" "$entry" "$attachment" "$pem" >/dev/null || {
    echo "opencode-secrets: could not export attachment $attachment from $entry" >&2
    exit 1
  }
  [[ -s "$pem" ]] || { echo "opencode-secrets: exported PEM is empty: $attachment" >&2; exit 1; }
  chmod 600 "$pem"
}

case "$source_kind" in
  sops) resolve_sops ;;
  keepassxc|keepass) resolve_keepass ;;
  *) echo "opencode-secrets: unknown source: $source_kind" >&2; exit 2 ;;
esac

echo "opencode-secrets: wrote ${#touched[@]} file(s) under $out_dir (mode 600)" >&2
echo "Next: docker compose -f docker/opencode/stack/docker-compose.yml up -d" >&2
