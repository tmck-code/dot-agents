#!/usr/bin/env bash
# Pre-commit secret scan.
#
# Uses gitleaks when installed (preferred; it understands more providers and
# supports an allowlist), and otherwise a small built-in scanner over staged
# files. Bypass with SKIP_SECRET_SCAN=1 for a reviewed false positive.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

if [[ "${SKIP_SECRET_SCAN:-}" == "1" ]]; then
  echo "secret-scan: skipped by SKIP_SECRET_SCAN=1" >&2
  exit 0
fi

if command -v gitleaks >/dev/null 2>&1; then
  if gitleaks help git >/dev/null 2>&1; then
    gitleaks git --staged --redact --no-banner
  else
    gitleaks protect --staged --redact --no-banner
  fi
  exit $?
fi

echo "secret-scan: gitleaks not found; using the built-in staged-file scanner" >&2

mapfile -t files < <(git diff --cached --name-only --diff-filter=ACMR)
if ((${#files[@]} == 0)); then
  exit 0
fi

patterns=(
  '-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'
  '\b(AKIA|ASIA)[0-9A-Z]{16}\b'
  '\bgh[pousr]_[A-Za-z0-9]{20,}\b'
  '\bgithub_pat_[A-Za-z0-9_]{20,}\b'
  '\bsk-[A-Za-z0-9_-]{20,}\b'
  '\bxox[baprs]-[A-Za-z0-9-]{10,}\b'
)

status=0
for file in "${files[@]}"; do
  [[ -f "$file" ]] || continue
  case "$file" in
    docs/*|*.md|openspec/*) continue ;;
  esac
  if file --mime-encoding "$file" 2>/dev/null | grep -q binary; then
    continue
  fi
  for pattern in "${patterns[@]}"; do
    if grep -nEI -- "$pattern" "$file"; then
      echo "secret-scan: possible secret in $file" >&2
      status=1
    fi
  done
done

if ((status)); then
  echo "secret-scan: blocked. Remove the secret, or set SKIP_SECRET_SCAN=1 for a reviewed false positive." >&2
fi
exit "$status"
