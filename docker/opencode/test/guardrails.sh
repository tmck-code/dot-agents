#!/usr/bin/env bash
# Guardrail regression suite: protected paths, external directories, explicit
# deny finality, proxy env injection, audit redaction and lease refresh.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if ! node --experimental-strip-types --version >/dev/null 2>&1; then
  echo "guardrails: node with --experimental-strip-types is required (Node >= 22.6)" >&2
  exit 1
fi

node --experimental-strip-types ./test/plugin-harness.mjs

# Claude credential files are protected at any depth, by the guard plugin and by
# the static deny rules in opencode.jsonc.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/plugins" "$tmp/node_modules/@opencode/plugin"
cp config/plugins/*.ts "$tmp/plugins/"
printf '{"name":"@opencode/plugin","type":"module","main":"index.js"}\n' \
  >"$tmp/node_modules/@opencode/plugin/package.json"
printf 'export const Plugin = { define: (value) => value }\n' \
  >"$tmp/node_modules/@opencode/plugin/index.js"
cat >"$tmp/check.mjs" <<'JS'
const guard = (await import(process.argv[2])).default
const hooks = { permission: {} }
const hook = () => (name, fn) => { hooks.permission[name] = fn }
await guard.setup({
  permission: { hook: hook() },
  tool: { hook: () => {} },
  shell: { hook: () => {} },
  session: { hook: () => {} },
})
let failed = 0
for (const name of [".credentials.json", ".claude.json", "history.jsonl"]) {
  for (const prefix of ["/tmp", "/tmp/a/b/c"]) {
    const event = { action: "read", resources: [`${prefix}/${name}`], effect: "allow" }
    await hooks.permission.evaluate(event)
    const ok = event.effect === "deny"
    console.log(`${ok ? "ok  " : "FAIL"} guard denies ${prefix}/${name}`)
    if (!ok) failed += 1
  }
}
process.exit(failed ? 1 : 0)
JS
node --experimental-strip-types "$tmp/check.mjs" "file://$tmp/plugins/guard.ts"

for name in .credentials.json .claude.json history.jsonl; do
  for action in read edit; do
    if ! grep -Fq "{ \"action\": \"$action\", \"resource\": \"**/$name\", \"effect\": \"deny\" }" config/opencode.jsonc; then
      echo "guardrails: opencode.jsonc lacks $action deny for $name" >&2
      exit 1
    fi
  done
done
echo "ok   opencode.jsonc denies read and edit for the Claude credential files"
