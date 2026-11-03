#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp --directory)
trap 'rm -rf -- "$TEST_TMP"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

[[ -f $PROJECT_DIR/extract-hostname.sh ]] || fail "hostname lookup script is missing"

# A real disk and libguestfs appliance are external dependencies. Model their
# documented command boundary while running the script's actual orchestration.
run_lookup() (
    source "$PROJECT_DIR/extract-hostname.sh"
    local scenario=$1
    local output_prefix="$TEST_TMP/$scenario"

    require_root() { return 0; }
    hostname_tool_is_available() { return 0; }
    validate_hostname_target() {
        [[ $TARGET_DISK == /dev/fixture ]] || fail "wrong source disk selected"
    }

    guestfish() {
        printf '%s\n' "$*" >> "$output_prefix.calls"
        if [[ $1 == --listen ]]; then
            [[ $# == 5 && $2 == --ro && $3 == --format=raw &&
                $4 == --add && $5 == /dev/fixture ]] || \
                fail "source was not attached read-only as raw"
            printf 'GUESTFISH_PID=4242; export GUESTFISH_PID\n'
            return 0
        fi
        [[ $1 == --remote=4242 ]] || fail "command did not reuse the listener"
        case $2 in
            run)
                if [[ $scenario == signal ]]; then
                    kill -TERM "$BASHPID"
                fi
                [[ $scenario != launch-failure ]]
                ;;
            inspect-os)
                case $scenario in
                    inspection-failure) return 1 ;;
                    no-os) return 0 ;;
                    multiple|same-name) printf '/dev/sda1\n/dev/sda2\n' ;;
                    *) printf '/dev/sda1\n' ;;
                esac
                ;;
            inspect-get-type)
                if [[ $scenario == windows ]]; then
                    printf 'windows\n'
                else
                    printf 'linux\n'
                fi
                ;;
            inspect-get-hostname)
                case $scenario in
                    windows) printf 'DESKTOP-ABC123\n' ;;
                    unknown) printf 'unknown\n' ;;
                    invalid) printf '../not-an-id\n' ;;
                    query-failure) return 1 ;;
                    multiple)
                        if [[ $3 == /dev/sda1 ]]; then
                            printf 'old-host\n'
                        else
                            printf 'current-host\n'
                        fi
                        ;;
                    *) printf 'linux-host.example\n' ;;
                esac
                ;;
            shutdown)
                [[ $scenario != shutdown-failure ]]
                ;;
            exit)
                [[ $scenario != cleanup-failure ]]
                ;;
            *) fail "unexpected guestfish operation: $*" ;;
        esac
    }

    main --target /dev/fixture > "$output_prefix.stdout" 2> "$output_prefix.stderr"
)

printf 'Checking Linux and Windows hostname output...\n'
for scenario in linux windows same-name; do
    run_lookup "$scenario" || fail "$scenario hostname lookup failed"
done
[[ $(cat "$TEST_TMP/linux.stdout") == linux-host.example ]] || fail "wrong Linux hostname"
[[ $(cat "$TEST_TMP/windows.stdout") == DESKTOP-ABC123 ]] || fail "wrong Windows hostname"
[[ $(cat "$TEST_TMP/same-name.stdout") == linux-host.example ]] || fail "duplicate names were ambiguous"
[[ $(wc -l < "$TEST_TMP/linux.stdout") == 1 ]] || fail "diagnostics leaked to stdout"

printf 'Checking selection between different hostnames...\n'
run_lookup multiple <<< $'9\n2' || fail "hostname selection failed"
[[ $(cat "$TEST_TMP/multiple.stdout") == current-host ]] || fail "wrong installation selected"
if run_lookup multiple <<< 0; then
    fail "cancelling hostname selection incorrectly succeeded"
fi
[[ ! -s $TEST_TMP/multiple.stdout ]] || fail "cancelled selection emitted a hostname"
if run_lookup multiple < /dev/null; then
    fail "missing hostname selection incorrectly succeeded"
fi
[[ ! -s $TEST_TMP/multiple.stdout ]] || fail "missing selection emitted a hostname"

printf 'Checking missing/invalid hostnames and session cleanup...\n'
for scenario in unknown invalid no-os launch-failure inspection-failure query-failure shutdown-failure cleanup-failure; do
    if run_lookup "$scenario"; then
        fail "$scenario incorrectly succeeded"
    fi
    [[ ! -s $TEST_TMP/$scenario.stdout ]] || fail "$scenario emitted a successful hostname"
    grep --fixed-strings --quiet -- '--remote=4242' "$TEST_TMP/$scenario.calls" || \
        fail "$scenario never used the listener"
    grep --fixed-strings --quiet -- 'exit' "$TEST_TMP/$scenario.calls" || \
        fail "$scenario did not close the session"
done

printf 'Checking cleanup after termination...\n'
if run_lookup signal; then
    fail "terminated lookup incorrectly succeeded"
else
    signal_status=$?
fi
[[ $signal_status == 143 ]] || fail "termination returned the wrong exit status"
[[ ! -s $TEST_TMP/signal.stdout ]] || fail "terminated lookup emitted a hostname"
grep --fixed-strings --quiet -- 'exit' "$TEST_TMP/signal.calls" || \
    fail "terminated lookup did not close its guestfish session"

printf 'Checking numbered disk selection...\n'
(
    source "$PROJECT_DIR/extract-hostname.sh"
    lsblk() {
        if [[ $* == *TYPE* ]]; then
            printf '/dev/fixture-a disk\n/dev/fixture-b disk\n'
        else
            printf '%s 1T Fixture disk\n' "${@: -1}"
        fi
    }
    select_hostname_target <<< $'9\n2' 2> "$TEST_TMP/disk-selection.stderr"
    [[ $TARGET_DISK == /dev/fixture-b ]] || fail "wrong disk selected"
)

printf 'Checking dependency installation and recheck...\n'
(
    source "$PROJECT_DIR/extract-hostname.sh"
    installed=false
    hostname_tool_is_available() {
        [[ $1 != guestfish || $installed == true ]]
    }
    install_hostname_packages() {
        [[ $# == 1 && $1 == libguestfs-tools ]] || fail "wrong package requested"
        installed=true
    }
    check_hostname_dependencies <<< y 2> "$TEST_TMP/dependencies.stderr"
    [[ $installed == true ]] || fail "installation was skipped"
)
if (
    source "$PROJECT_DIR/extract-hostname.sh"
    hostname_tool_is_available() { [[ $1 != guestfish ]]; }
    install_hostname_packages() { fail "installed a declined package"; }
    check_hostname_dependencies <<< n
) > "$TEST_TMP/decline.stdout" 2> "$TEST_TMP/decline.stderr"; then
    fail "declining a required dependency did not stop lookup"
fi
if (
    source "$PROJECT_DIR/extract-hostname.sh"
    hostname_tool_is_available() { [[ $1 != guestfish ]]; }
    install_hostname_packages() { return 0; }
    check_hostname_dependencies <<< y
) > "$TEST_TMP/recheck.stdout" 2> "$TEST_TMP/recheck.stderr"; then
    fail "lookup continued when installation did not provide guestfish"
fi

printf 'Checking CLI validation...\n'
bash "$PROJECT_DIR/extract-hostname.sh" --help > "$TEST_TMP/help.stdout"
if bash "$PROJECT_DIR/extract-hostname.sh" --target > /dev/null 2>&1; then
    fail "missing target argument was accepted"
fi
if (
    source "$PROJECT_DIR/extract-hostname.sh"
    TARGET_DISK=/dev/null
    validate_hostname_target
) > /dev/null 2>&1; then
    fail "a character device was accepted as a source disk"
fi

printf 'Hostname lookup tests passed.\n'
