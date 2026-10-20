#!/usr/bin/env bash
# gate.sh — run a test/lint gate once, capture everything to a log, watch the
# process, and propagate a truthful exit code.
#
#   gate.sh [-t TIMEOUT] [-s STALL] [-L] OUTPUT_FILE COMMAND [ARGS...]
#
#   -t TIMEOUT  hard kill after this many seconds        (default 900)
#   -s STALL    kill if the log stops growing for this   (default 120)
#               many seconds while the process is alive
#   -L          do not take the machine-wide gate lock (only for a gate the
#               caller knows is independent, e.g. a tsc-only check)
#
# Only one gate runs at a time per toolchain (rust or frontend; make -k sweeps are rust):
# gate.sh takes flock on ${XDG_RUNTIME_DIR:-/tmp}/claude-gate-<kind>.lock and WAITS for it, logging
# "[waiting for another gate: held by ...]" every 30 s. TIMEOUT and STALL start
# only once the lock is held. The command runs under nice -n 10 / ionice -c3
# when those exist.
#
# Writes:  OUTPUT_FILE          full combined stdout+stderr, unfiltered, each
#                               line prefixed "[HH:MM:SS +MM:SS] " (wall, elapsed)
#          OUTPUT_FILE.status   one line: exit=<code> reason=<why> secs=<n> lockwait=<secs>
#          stderr               a short verdict + the interesting log lines
#
# Exit code = the command's exit code, or 124 timeout / 125 stall / 137 killed.
# Never pipe this through tail/grep; grep OUTPUT_FILE afterwards instead.

set -uo pipefail

TIMEOUT=900
STALL=120
NOLOCK=0
while getopts 't:s:L' o; do
  case $o in
    t) TIMEOUT=$OPTARG ;;
    s) STALL=$OPTARG ;;
    L) NOLOCK=1 ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[ $# -ge 2 ] || { echo "usage: gate.sh [-t secs] [-s secs] [-L] OUTPUT_FILE COMMAND..." >&2; exit 2; }

OUT=$1; shift
rm -f "$OUT.status"
# Tokens of the command (quotes stripped) for classification and the guardrail.
CMD_TOKENS=$(printf '%s' "$*" | tr -d "'\"" | tr -s '[:space:]' '\n')

# Guardrail (only in repos whose Makefile has a `test-fast` target, i.e. audiovis): a lone plain
# `make test` is the once-per-stage sweep. Refuse it unless FULL=1 is in the environment or on
# the command line. Writes no .status file. Other repos are unaffected.
if [ "${FULL:-}" != 1 ] && grep -qs "^test-fast:" Makefile; then
  _full=0 _make=0 _rk=0 _targets=()
  while IFS= read -r _t; do
    [ -n "$_t" ] || continue
    case $_t in
      FULL=1) _full=1 ;;
      RK=*) _rk=1 ;;
      make) _make=1 ;;
      -*|*=*) ;;
      *) [ "$_make" -eq 1 ] && _targets+=("$_t") ;;
    esac
  done <<< "$CMD_TOKENS"
  if [ "$_full" -eq 0 ] && [ "$_rk" -eq 0 ] && [ "${#_targets[@]}" -eq 1 ] && [ "${_targets[0]}" = test ]; then
    echo "plain make test is the once-per-stage sweep: use make test-fast, RK=…, or make test FULL=1" >&2
    exit 2
  fi
fi

mkdir -p "$(dirname "$OUT")"
: > "$OUT"
rm -f "$OUT.status"

# Per-toolchain lock (rust|frontend): one gate at a time per toolchain. Wait (never fail); the log shows we are queued.
LOCKWAIT=0
if [ "$NOLOCK" -eq 0 ] && command -v flock > /dev/null; then
  # One lock per toolchain: "frontend" only if the command has frontend tokens and no rust tokens.
  _fe=0 _rs=0
  while IFS= read -r _t; do
    case $_t in
      check-ui|test-ui|build-ui-deps|frontend-run|npm) _fe=1 ;;
      lint|typecheck|test|test-fast|check-sync|gen|cargo|rust-run|build-rust-dev) _rs=1 ;;
    esac
  done <<< "$CMD_TOKENS"
  KIND=rust; [ "$_fe" -eq 1 ] && [ "$_rs" -eq 0 ] && KIND=frontend
  LOCK=${XDG_RUNTIME_DIR:-/tmp}/claude-gate-$KIND.lock
  exec 9> "$LOCK"
  WAIT_START=$(date +%s)
  while ! flock -n 9; do
    printf '[%(%T)T] [waiting for another gate: held by %s]\n' -1 "$(cat "$LOCK.info" 2>/dev/null || echo unknown)" >> "$OUT"
    flock -w 30 9 && break
  done
  LOCKWAIT=$(( $(date +%s) - WAIT_START ))
  printf 'pid=%s since %s cmd=%s' "$$" "$(date +%T)" "$*" > "$LOCK.info"
fi

START=$(date +%s)
START_RT=$EPOCHREALTIME

# Prefix every line with wall-clock and elapsed time. Builtins only: no fork per line.
stamp() {
  local line t0=${START_RT/./} now el
  while IFS= read -r line || [ -n "$line" ]; do
    now=${EPOCHREALTIME/./}; el=$(( (now - t0) / 1000000 ))
    printf '[%(%T)T +%02d:%02d] %s\n' -1 $((el / 60)) $((el % 60)) "$line"
  done
}

FIFO=$(mktemp -u "${TMPDIR:-/tmp}/gate.XXXXXX"); mkfifo "$FIFO"
stamp < "$FIFO" >> "$OUT" 9>&- &
STAMP=$!
# Line-buffer the child where possible so stamps reflect emit time, not flush time.
export PYTHONUNBUFFERED=1
if command -v stdbuf > /dev/null; then set -- stdbuf -oL -eL "$@"; fi
if command -v ionice > /dev/null; then set -- ionice -c3 "$@"; fi
if command -v nice > /dev/null; then set -- nice -n 10 "$@"; fi
# Close the lock fd in the child: only gate.sh holds the lock, so a daemon the
# command leaves running cannot keep it held after the gate ends.
setsid "$@" > "$FIFO" 2>&1 < /dev/null 9>&- &
PID=$!
REASON=exit

last_size=0; last_change=$START
while kill -0 "$PID" 2>/dev/null; do
  sleep 2
  now=$(date +%s)
  size=$(stat -c %s "$OUT" 2>/dev/null || echo 0)
  if [ "$size" != "$last_size" ]; then last_size=$size; last_change=$now; fi
  if [ $((now - START)) -ge "$TIMEOUT" ]; then REASON=timeout; break; fi
  if [ $((now - last_change)) -ge "$STALL" ]; then REASON=stall; break; fi
done

if [ "$REASON" != exit ]; then
  kill -TERM -- -"$PID" 2>/dev/null; sleep 3; kill -KILL -- -"$PID" 2>/dev/null
fi
wait "$PID"; CODE=$?
wait "$STAMP"; rm -f "$FIFO"
case $REASON in timeout) CODE=124 ;; stall) CODE=125 ;; esac
SECS=$(( $(date +%s) - START ))

# Crash signatures that a "green-looking" tail would hide.
CRASH=$(grep -nE 'node down|worker .* crashed|Segmentation fault|Error 137|Killed|OOM|MemoryError|INTERNALERROR|Traceback \(most recent call last\)' "$OUT" | head -5)
[ "$CODE" -eq 0 ] && [ -n "$CRASH" ] && REASON=crash-in-log

echo "exit=$CODE reason=$REASON secs=$SECS lockwait=$LOCKWAIT" > "$OUT.status"
{
  echo "=== gate: exit=$CODE reason=$REASON secs=${SECS}s log=$OUT"
  [ -n "$CRASH" ] && { echo "--- crash signatures:"; echo "$CRASH"; }
  echo "--- summary lines:"
  grep -nE '\] (FAILED|ERROR) |[0-9]+ (passed|failed|errors?)|\] Tests:|\] Test Suites:|✓|✗|FAIL |PASS ' "$OUT" | tail -25
  echo "=== full log: $OUT (grep it; do NOT rerun to re-filter)"
} >&2
exit "$CODE"
