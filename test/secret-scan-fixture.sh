#!/usr/bin/env bash
# Verify the pre-commit secret scanner blocks a staged fixture secret and
# passes once the fixture is removed. Uses a temporary git repository, so the
# fake secret never enters this repo.
set -euo pipefail

source_repo="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
tmp="$(mktemp -d /tmp/secret-scan.XXXXXX)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

mkdir -p "$tmp/scripts"
cp "$source_repo/scripts/secret-scan.sh" "$tmp/scripts/secret-scan.sh"
chmod +x "$tmp/scripts/secret-scan.sh"
git -C "$tmp" init -q -b main
git -C "$tmp" config user.name "Secret Scan Test"
git -C "$tmp" config user.email "secret-scan@example.invalid"

# Build the fake token at runtime so this script itself stays clean.
fake="ghp_$(printf 'a%.0s' {1..36})"
printf 'token = "%s"\n' "$fake" > "$tmp/app.env"
git -C "$tmp" add app.env

if (cd "$tmp" && ./scripts/secret-scan.sh >/dev/null 2>&1); then
  echo "secret-scan-fixture: fixture secret was not blocked" >&2
  exit 1
fi
echo "secret-scan-fixture: fixture secret blocked"

printf 'token = "REDACTED"\n' > "$tmp/app.env"
git -C "$tmp" add app.env
if ! (cd "$tmp" && ./scripts/secret-scan.sh >/dev/null 2>&1); then
  echo "secret-scan-fixture: clean file was blocked" >&2
  exit 1
fi

echo "secret-scan-fixture: ok"
