#!/usr/bin/env bash

# Shared helpers for the archive-pc scripts.
# This file is sourced by the command-line scripts; it is not run directly.

SCRIPT_VERSION="0.1.0"
RECORD_TIMEZONE="America/New_York"
DEBUG=${DEBUG:-false}
DRY_RUN=${DRY_RUN:-false}
LOG_FILE=${LOG_FILE:-}
COMMANDS_JSONL=${COMMANDS_JSONL:-}

declare -ag CLEANUP_HANDLERS=()

# Use one timezone for generated timestamps and for tools that render local time.
export TZ="$RECORD_TIMEZONE"

record_time_now() {
    date +"%Y-%m-%dT%H:%M:%S%:z"
}

duration_seconds() {
    local started_epoch=$1
    local completed_epoch=$2

    printf '%s\n' "$((completed_epoch - started_epoch))"
}

log_message() {
    local level=$1
    shift

    local message
    local message_text
    printf -v message_text '%s ' "$@"
    message_text=${message_text% }
    message="$(record_time_now) [$level] $message_text"
    printf '%s\n' "$message" >&2

    if [[ -n ${LOG_FILE:-} && -d $(dirname "$LOG_FILE") ]]; then
        printf '%s\n' "$message" >> "$LOG_FILE"
    fi
}

log_info() {
    log_message INFO "$@"
}

log_warn() {
    log_message WARN "$@"
}

log_error() {
    log_message ERROR "$@"
}

log_debug() {
    if [[ ${DEBUG:-false} == true ]]; then
        log_message DEBUG "$@"
    fi
}

die() {
    log_error "$@"
    exit 1
}

require_root() {
    if ((EUID != 0)); then
        die "This operation must be run as root."
    fi
}

require_tool() {
    local tool=$1
    local install_hint=${2:-}

    if command -v "$tool" >/dev/null 2>&1; then
        return 0
    fi

    if [[ -n $install_hint ]]; then
        die "Required tool '$tool' was not found. Install package: $install_hint"
    fi

    die "Required tool '$tool' was not found."
}

safe_mkdir() {
    local directory=$1

    if [[ ${DRY_RUN:-false} == true ]]; then
        printf 'Would create directory: %s\n' "$directory"
        return 0
    fi

    mkdir -p -- "$directory"
}

json_escape() {
    local value=${1:-}
    jq --null-input --compact-output --arg value "$value" '$value'
}

write_jsonl_command_record() {
    local name=$1
    local started_at=$2
    local completed_at=$3
    local duration=$4
    local exit_code=$5
    local stdout_file=$6
    local stderr_file=$7

    [[ -n ${COMMANDS_JSONL:-} ]] || return 0

    jq --null-input --compact-output \
        --arg name "$name" \
        --arg started_at "$started_at" \
        --arg completed_at "$completed_at" \
        --arg timezone "$RECORD_TIMEZONE" \
        --argjson duration "$duration" \
        --argjson exit_code "$exit_code" \
        --arg stdout "$stdout_file" \
        --arg stderr "$stderr_file" \
        '{
            name: $name,
            started_at: $started_at,
            completed_at: $completed_at,
            timezone: $timezone,
            duration_seconds: $duration,
            exit_code: $exit_code,
            stdout: $stdout,
            stderr: $stderr
        }' >> "$COMMANDS_JSONL"
}

path_for_record() {
    local path=$1
    local record_root=${RECORD_ROOT:-}

    if [[ -n $record_root && $path == "$record_root"/* ]]; then
        printf '%s\n' "${path#"$record_root"/}"
    else
        printf '%s\n' "$path"
    fi
}

run_recorded_command_with_mode() {
    local show_output=$1
    shift

    local name=$1
    local stdout_file=$2
    local stderr_file=$3
    shift 3

    if [[ ${DRY_RUN:-false} == true ]]; then
        printf 'Would run [%s]:' "$name"
        printf ' %q' "$@"
        printf '\n  stdout: %s\n  stderr: %s\n' "$stdout_file" "$stderr_file"
        return 0
    fi

    local started_at
    local completed_at
    local started_epoch
    local completed_epoch
    local elapsed
    local exit_code
    local stdout_record
    local stderr_record

    mkdir -p -- "$(dirname "$stdout_file")" "$(dirname "$stderr_file")"
    started_at=$(record_time_now)
    started_epoch=$(date +%s)
    log_debug "Running command '$name': $(printf '%q ' "$@")"

    if [[ $show_output == true ]]; then
        if "$@" > >(tee -- "$stdout_file") 2> >(tee -- "$stderr_file" >&2); then
            exit_code=0
        else
            exit_code=$?
        fi
    else
        if "$@" > "$stdout_file" 2> "$stderr_file"; then
            exit_code=0
        else
            exit_code=$?
        fi
    fi

    completed_epoch=$(date +%s)
    completed_at=$(record_time_now)
    elapsed=$(duration_seconds "$started_epoch" "$completed_epoch")
    stdout_record=$(path_for_record "$stdout_file")
    stderr_record=$(path_for_record "$stderr_file")

    write_jsonl_command_record \
        "$name" \
        "$started_at" \
        "$completed_at" \
        "$elapsed" \
        "$exit_code" \
        "$stdout_record" \
        "$stderr_record"

    return "$exit_code"
}

run_recorded_command() {
    run_recorded_command_with_mode false "$@"
}

run_recorded_command_live() {
    run_recorded_command_with_mode true "$@"
}

record_skipped_command() {
    local name=$1
    local stdout_file=$2
    local stderr_file=$3
    local reason=$4
    local timestamp

    if [[ ${DRY_RUN:-false} == true ]]; then
        printf 'Would attempt [%s]; skip reason if unavailable: %s\n' "$name" "$reason"
        return 0
    fi

    timestamp=$(record_time_now)
    printf '%s\n' "$reason" > "$stderr_file"
    : > "$stdout_file"
    write_jsonl_command_record \
        "$name" \
        "$timestamp" \
        "$timestamp" \
        0 \
        127 \
        "$(path_for_record "$stdout_file")" \
        "$(path_for_record "$stderr_file")"
}

run_optional_command() {
    local name=$1
    local stdout_file=$2
    local stderr_file=$3
    local tool=$4
    local exit_code
    shift 4

    if ! command -v "$tool" >/dev/null 2>&1; then
        record_skipped_command \
            "$name" \
            "$stdout_file" \
            "$stderr_file" \
            "Optional tool '$tool' is not installed; this collection step was skipped."
        if declare -F add_warning >/dev/null 2>&1; then
            add_warning "Optional tool '$tool' is not installed; skipped '$name'."
        else
            log_warn "Optional tool '$tool' is not installed; skipped '$name'."
        fi
        return 0
    fi

    if run_recorded_command "$name" "$stdout_file" "$stderr_file" "$tool" "$@"; then
        return 0
    else
        exit_code=$?
    fi

    add_missing_stderr_context "$exit_code" "$stdout_file" "$stderr_file"
    if declare -F add_warning >/dev/null 2>&1; then
        add_warning \
            "Optional collection command '$name' exited with status $exit_code;" \
            "see $stdout_file and $stderr_file"
    else
        log_warn \
            "Optional collection command '$name' exited with status $exit_code;" \
            "see $stdout_file and $stderr_file"
    fi
    return 0
}

add_missing_stderr_context() {
    local exit_code=$1
    local stdout_file=$2
    local stderr_file=$3

    if [[ ! -s $stderr_file ]]; then
        printf '%s\n' \
            "Command exited with status $exit_code but wrote no standard error." \
            "Review its captured standard output: $stdout_file" \
            > "$stderr_file"
    fi
}

ensure_managed_readme() {
    local readme=$1
    local title=$2

    if [[ -e $readme ]]; then
        return 0
    fi

    cat > "$readme" <<EOF
# $title

## Overview

Archived personal PC.

## Directory Layout

| Directory | Purpose |
|---|---|
| ARCHIVE/ | Disk image and archival-run records |
| METADATA/ | OS, user, and application metadata extracted from the image |
| VM/ | Future VM conversion output |
| RECOVERED/ | Future recovered personal files |

## Manual Notes

Add notes here.
EOF
}

update_readme_block() {
    local readme=$1
    local block_name=$2
    local block_file=$3
    local begin_marker="<!-- BEGIN $block_name -->"
    local end_marker="<!-- END $block_name -->"
    local temporary_file
    local begin_count
    local end_count

    begin_count=$(grep -Fxc "$begin_marker" "$readme" || true)
    end_count=$(grep -Fxc "$end_marker" "$readme" || true)

    if ((begin_count != end_count || begin_count > 1)); then
        die "Cannot safely update $readme: malformed '$block_name' managed block."
    fi

    temporary_file=$(mktemp "${readme}.tmp.XXXXXX")

    awk \
        -v begin_marker="$begin_marker" \
        -v end_marker="$end_marker" \
        -v block_file="$block_file" '
        $0 == begin_marker {
            print
            while ((getline block_line < block_file) > 0) {
                print block_line
            }
            close(block_file)
            inside_block = 1
            found_block = 1
            next
        }
        inside_block && $0 == end_marker {
            print
            inside_block = 0
            next
        }
        inside_block {
            next
        }
        {
            print
        }
        END {
            if (!found_block) {
                if (NR > 0) {
                    print ""
                }
                print begin_marker
                while ((getline block_line < block_file) > 0) {
                    print block_line
                }
                close(block_file)
                print end_marker
            }
        }
    ' "$readme" > "$temporary_file"

    mv -- "$temporary_file" "$readme"
}

register_cleanup_handler() {
    local handler=$1
    CLEANUP_HANDLERS+=("$handler")
}

run_cleanup_handlers() {
    local exit_code=$?
    local index
    local handler

    trap - EXIT INT TERM

    for ((index = ${#CLEANUP_HANDLERS[@]} - 1; index >= 0; index--)); do
        handler=${CLEANUP_HANDLERS[index]}
        if ! "$handler"; then
            log_warn "Cleanup handler '$handler' did not complete successfully."
            if ((exit_code == 0)); then
                exit_code=1
            fi
        fi
    done

    exit "$exit_code"
}

install_cleanup_trap() {
    trap run_cleanup_handlers EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}
