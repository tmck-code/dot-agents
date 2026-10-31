#!/usr/bin/env bash
#
# Import KEY="value" lines into a KeePassXC database.
#
# Each line becomes an entry whose title is KEY and whose password is the
# value. Blank lines and comment lines are ignored. The values are never
# printed and are never passed on the command line.
#
# Usage:
#   ./keepassxc-import.sh [options] SECRETS_FILE DATABASE [GROUP]
#
#   KEEPASSXC_DB_PASSWORD='...' ./keepassxc-import.sh secrets.env vault.kdbx
#
# If KEEPASSXC_DB_PASSWORD is not set, the database password is read from the
# terminal. Existing entries are not overwritten; a failed add is reported and
# the import continues.
#
# Progress and status are written to stderr. Colors and the live progress bar
# are only used when stderr is a terminal; set NO_COLOR to disable colors.

set -uo pipefail

usage() {
    cat <<'EOF'
Usage: keepassxc-import.sh [options] SECRETS_FILE DATABASE [GROUP]

Arguments:
  SECRETS_FILE         File containing export KEY="value" lines.
  DATABASE             Existing KeePassXC .kdbx database.
  GROUP                Optional existing group to put entries in.

Options:
  -k, --key-file PATH  Key file for the database.
  -g, --group GROUP    Same as passing GROUP as the third argument.
  -n, --no-password    Database has no password (key file only).
  -h, --help           Show this help.

Set KEEPASSXC_DB_PASSWORD to avoid the interactive password prompt. The
variable is unset in the script before keepassxc-cli is invoked.

Examples:
  ./keepassxc-import.sh secrets.env vault.kdbx
  KEEPASSXC_DB_PASSWORD="$(cat ~/.vault-pass)" \
      ./keepassxc-import.sh -g imported secrets.env vault.kdbx
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

# Output styling. Everything is written to stderr so stdout stays clean, and
# ANSI codes are only emitted when stderr is a terminal.
err_tty=0
C_RESET=''
C_BOLD=''
C_DIM=''
C_RED=''
C_GREEN=''
C_YELLOW=''
C_CYAN=''

setup_output() {
    [[ -t 2 ]] || return

    err_tty=1
    [[ -v NO_COLOR || ${TERM-} == dumb ]] && return

    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_CYAN=$'\033[36m'
}

warn() {
    if (( err_tty )); then
        printf '\r\033[K' >&2
    fi
    printf '%swarning:%s %s\n' "${C_YELLOW}${C_BOLD}" "$C_RESET" "$*" >&2
}

format_duration() {
    local seconds=$1

    if (( seconds >= 3600 )); then
        printf -v REPLY '%d:%02d:%02d' \
            $((seconds / 3600)) $((seconds % 3600 / 60)) $((seconds % 60))
    else
        printf -v REPLY '%02d:%02d' $((seconds / 60)) $((seconds % 60))
    fi
}

draw_progress() {
    local current=$1
    local total=$2
    local width=24
    local filled empty percent bar pad
    local elapsed elapsed_fmt remaining remaining_fmt

    (( err_tty && total > 0 )) || return

    filled=$((current * width / total))
    (( filled > width )) && filled=$width
    empty=$((width - filled))
    percent=$((current * 100 / total))

    printf -v bar '%*s' "$filled" ''
    bar=${bar// /#}
    printf -v pad '%*s' "$empty" ''
    pad=${pad// /-}

    elapsed=$((SECONDS - start_seconds))
    format_duration "$elapsed"
    elapsed_fmt=$REPLY

    if (( current > 0 && elapsed > 0 )); then
        remaining=$((elapsed * (total - current) / current))
        format_duration "$remaining"
        remaining_fmt=$REPLY
    else
        remaining_fmt='--:--'
    fi

    printf '\r\033[K  [%s%s%s%s]%s %3d%% %s(%d/%d)%s  %s%s elapsed%s  %sETA %s%s' \
        "$C_CYAN" "$bar" "$C_DIM" "$pad" "$C_RESET" \
        "$percent" "$C_DIM" "$current" "$total" "$C_RESET" \
        "$C_DIM" "$elapsed_fmt" "$C_RESET" \
        "$C_DIM" "$remaining_fmt" "$C_RESET" >&2
}

# Decode the contents of a double-quoted shell string without evaluating it.
# Handles the escapes that retain meaning inside double quotes; unknown
# escapes keep their backslash.
decode_double_quoted() {
    local s=$1
    local out=''
    local rest ch

    while [[ $s == *\\* ]]; do
        out+=${s%%\\*}
        rest=${s#*\\}
        ch=${rest:0:1}

        case $ch in
            \"|\\|\$|\`)
                out+=$ch
                s=${rest:1}
                ;;
            $'\n')
                s=${rest:1}
                ;;
            *)
                out+="\\"
                s=$rest
                ;;
        esac
    done

    REPLY=$out$s
}

parse_value() {
    local raw=$1

    if [[ $raw =~ ^\"(.*)\"[[:space:]]*$ ]]; then
        decode_double_quoted "${BASH_REMATCH[1]}"
        value=$REPLY
    elif [[ $raw =~ ^\'(.*)\'[[:space:]]*$ ]]; then
        value=${BASH_REMATCH[1]}
    else
        # Unquoted value: trim surrounding whitespace.
        raw=${raw#"${raw%%[![:space:]]*}"}
        raw=${raw%"${raw##*[![:space:]]}"}
        value=$raw
    fi
}

key_file=''
group=''
no_password=0

while (( $# > 0 )); do
    case $1 in
        -k|--key-file)
            (( $# >= 2 )) || die "$1 requires a path"
            key_file=$2
            shift 2
            ;;
        -g|--group)
            (( $# >= 2 )) || die "$1 requires a group name"
            group=$2
            shift 2
            ;;
        -n|--no-password)
            no_password=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            die "unknown option: $1 (try --help)"
            ;;
        *)
            break
            ;;
    esac
done

if (( $# < 2 || $# > 3 )); then
    usage >&2
    exit 2
fi

secrets_file=$1
database=$2
if (( $# == 3 )); then
    group=$3
fi

[[ -r $secrets_file ]] || die "cannot read secrets file: $secrets_file"
[[ -f $secrets_file ]] || die "secrets file is not a regular file: $secrets_file"
[[ -f $database ]] || die "database does not exist: $database"
command -v keepassxc-cli >/dev/null 2>&1 || die "keepassxc-cli is not installed"
[[ -n $key_file && ! -r $key_file ]] && die "cannot read key file: $key_file"

setup_output

total=0
while IFS= read -r count_line || [[ -n $count_line ]]; do
    count_line=${count_line%$'\r'}
    [[ $count_line =~ ^[[:space:]]*$ ]] && continue
    [[ $count_line =~ ^[[:space:]]*# ]] && continue
    total=$((total + 1))
done < "$secrets_file"

db_password=''
if (( ! no_password )); then
    if [[ -v KEEPASSXC_DB_PASSWORD ]]; then
        db_password=$KEEPASSXC_DB_PASSWORD
        unset KEEPASSXC_DB_PASSWORD
    else
        [[ -t 0 ]] || die "set KEEPASSXC_DB_PASSWORD when not running interactively"
        IFS= read -r -s -p 'KeePassXC database password: ' db_password
        printf '\n' >&2
    fi
fi

add_args=(add -q)
if (( no_password )); then
    add_args+=(--no-password)
fi
if [[ -n $key_file ]]; then
    add_args+=(-k "$key_file")
fi
add_args+=(-p "$database")

added=0
failed=0
malformed=0
line_no=0
processed=0
start_seconds=$SECONDS

if (( err_tty )); then
    line_label=lines
    (( total == 1 )) && line_label=line
    printf '%sImporting %d %s from %s%s\n' \
        "${C_BOLD}${C_CYAN}" "$total" "$line_label" "$secrets_file" "$C_RESET" >&2
fi
draw_progress 0 "$total"

while IFS= read -r line || [[ -n $line ]]; do
    line_no=$((line_no + 1))
    line=${line%$'\r'}

    [[ $line =~ ^[[:space:]]*$ ]] && continue
    [[ $line =~ ^[[:space:]]*# ]] && continue

    processed=$((processed + 1))

    if [[ ! $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        warn "line $line_no: skipping malformed line"
        malformed=$((malformed + 1))
        draw_progress "$processed" "$total"
        continue
    fi

    key=${BASH_REMATCH[2]}
    raw_value=${BASH_REMATCH[3]}
    parse_value "$raw_value"

    entry=$key
    if [[ -n $group ]]; then
        entry="${group%/}/$key"
    fi

    # Show what is happening before the (potentially slow) keepassxc-cli call.
    if (( err_tty )); then
        printf '\r\033[K' >&2
        printf '%s  adding%s %s[%d/%d]%s %s%s%s\n' \
            "$C_CYAN" "$C_RESET" "$C_DIM" "$processed" "$total" "$C_RESET" \
            "$C_BOLD" "$entry" "$C_RESET" >&2
        draw_progress "$((processed - 1))" "$total"
    else
        printf 'adding [%d/%d]: %s\n' "$processed" "$total" "$entry" >&2
    fi

    # Capture keepassxc-cli output so its error text cannot scribble over the
    # progress bar. The command substitution's status is the pipeline status.
    if (( no_password )); then
        cli_output=$(printf '%s\n' "$value" | keepassxc-cli "${add_args[@]}" "$entry" 2>&1)
        cli_status=$?
    else
        cli_output=$(printf '%s\n%s\n' "$db_password" "$value" | keepassxc-cli "${add_args[@]}" "$entry" 2>&1)
        cli_status=$?
    fi

    if (( err_tty )); then
        printf '\r\033[K' >&2
    fi

    if (( cli_status == 0 )); then
        added=$((added + 1))
        if (( ! err_tty )); then
            printf 'added: %s\n' "$entry" >&2
        fi
    else
        if [[ -n $cli_output ]]; then
            printf '%s\n' "$cli_output" >&2
        fi
        warn "failed to add: $entry"
        failed=$((failed + 1))
    fi

    draw_progress "$processed" "$total"
done < "$secrets_file"

if (( err_tty )); then
    printf '\r\033[K' >&2
fi

if (( failed > 0 )); then
    summary_color="${C_RED}${C_BOLD}"
elif (( malformed > 0 )); then
    summary_color="${C_YELLOW}${C_BOLD}"
else
    summary_color="${C_GREEN}${C_BOLD}"
fi

printf '%sAdded %d, failed %d, malformed %d.%s\n' \
    "$summary_color" "$added" "$failed" "$malformed" "$C_RESET" >&2
(( failed == 0 && malformed == 0 ))
