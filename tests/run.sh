#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp --directory)

cleanup_tests() {
    rm -rf -- "$TEST_TMP"
}
trap cleanup_tests EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_file_contains() {
    local file=$1
    local expected=$2

    grep --fixed-strings --quiet -- "$expected" "$file" || \
        fail "$file does not contain: $expected"
}

printf 'Checking Bash syntax...\n'
bash -n \
    "$PROJECT_DIR/archive-disk.sh" \
    "$PROJECT_DIR/extract-metadata.sh" \
    "$PROJECT_DIR/lib/common.sh"

printf 'Checking help and dry-run behavior...\n'
bash "$PROJECT_DIR/archive-disk.sh" --help >/dev/null
bash "$PROJECT_DIR/extract-metadata.sh" --help >/dev/null
touch "$TEST_TMP/fixture.img"
bash "$PROJECT_DIR/archive-disk.sh" \
    --pc-id PC-TEST \
    --output "$TEST_TMP/archive-output" \
    --target /dev/test-disk \
    --dry-run > "$TEST_TMP/archive-dry-run.txt" 2>&1
[[ ! -e $TEST_TMP/archive-output ]] || fail "archive dry run created its output directory"
assert_file_contains "$TEST_TMP/archive-dry-run.txt" "ddrescue image:"
assert_file_contains \
    "$TEST_TMP/archive-dry-run.txt" \
    "Working directory: $TEST_TMP/archive-output/PC-TEST"

if bash "$PROJECT_DIR/archive-disk.sh" \
    --pc-id PC-TEST \
    --output "$TEST_TMP/PC-TEST" \
    --target /dev/test-disk \
    --dry-run > "$TEST_TMP/old-output-form.txt" 2>&1; then
    fail "archive dry run accepted a working directory as its output parent"
fi
assert_file_contains "$TEST_TMP/old-output-form.txt" "--output expects the parent directory"

printf 'Checking interactive PC ID and output selection...\n'
(
    source "$PROJECT_DIR/archive-disk.sh"

    output_filesystem_is_system_only tmpfs || \
        fail "output picker did not exclude a system-only filesystem"
    if output_filesystem_is_system_only fuseblk; then
        fail "output picker excluded an external FUSE block filesystem"
    fi

    available_output_paths() {
        printf '%s\n' /mnt/fixture-a /mnt/fixture-b
    }

    print_output_summary() {
        printf '%s (fixture output location)\n' "$1"
    }

    prompt_for_missing_arguments <<< $'invalid id\nPC-PROMPT\n9\n2' \
        2> "$TEST_TMP/archive-setup-prompts.txt"
    validate_arguments
    [[ $PC_ID == PC-PROMPT ]] || fail "interactive prompt did not save the PC ID"
    [[ $OUTPUT_PARENT == /mnt/fixture-b ]] || \
        fail "interactive prompt did not save the output parent"
    [[ $OUTPUT_ROOT == /mnt/fixture-b/PC-PROMPT ]] || \
        fail "interactive prompt did not derive the PC working directory"
)
assert_file_contains "$TEST_TMP/archive-setup-prompts.txt" "Enter the PC ID"
assert_file_contains "$TEST_TMP/archive-setup-prompts.txt" "[1] /mnt/fixture-a"
assert_file_contains "$TEST_TMP/archive-setup-prompts.txt" "Enter an integer from 0 to 3."
assert_file_contains "$TEST_TMP/archive-setup-prompts.txt" "Selected output parent: /mnt/fixture-b"

(
    source "$PROJECT_DIR/archive-disk.sh"

    available_output_paths() {
        printf '%s\n' /mnt/fixture-a
    }

    print_output_summary() {
        printf '%s (fixture output location)\n' "$1"
    }

    prompt_for_output_parent <<< $'2\n/tmp/custom-output' 2>/dev/null
    [[ $OUTPUT_PARENT == /tmp/custom-output ]] || \
        fail "output picker did not accept a custom directory"
)

printf 'Checking dependency installation prompts...\n'
(
    source "$PROJECT_DIR/archive-disk.sh"
    dependencies_installed=false

    tool_is_available() {
        case $1 in
            ddrescue|smartctl)
                [[ $dependencies_installed == true ]]
                ;;
            *)
                return 0
                ;;
        esac
    }

    install_packages_with_apt() {
        printf '%s\n' "$@" > "$TEST_TMP/requested-packages.txt"
        dependencies_installed=true
    }

    COMPRESSION=none
    check_and_offer_dependencies <<< $'y\ny' \
        2> "$TEST_TMP/dependency-prompts.txt"
)
assert_file_contains "$TEST_TMP/dependency-prompts.txt" "Missing packages required"
assert_file_contains "$TEST_TMP/dependency-prompts.txt" "Missing optional packages"
assert_file_contains "$TEST_TMP/requested-packages.txt" "gddrescue"
assert_file_contains "$TEST_TMP/requested-packages.txt" "smartmontools"

bash "$PROJECT_DIR/archive-disk.sh" \
    --pc-id PC-DOCS \
    --output "$TEST_TMP/documentation-dry-output" \
    --target /dev/test-disk \
    --documentation-only \
    --max-read-gb 2 \
    --dry-run > "$TEST_TMP/documentation-dry-run.txt" 2>&1
[[ ! -e $TEST_TMP/documentation-dry-output ]] || \
    fail "documentation dry run created its output directory"
assert_file_contains "$TEST_TMP/documentation-dry-run.txt" "Documentation would be generated"
assert_file_contains "$TEST_TMP/documentation-dry-run.txt" "Capture limit: first 2 GB (2000000000 bytes)"

bash "$PROJECT_DIR/archive-disk.sh" \
    --pc-id PC-SMALL \
    --output "$TEST_TMP/fractional-limit-output" \
    --target /dev/test-disk \
    --max-read-gb 0.25 \
    --dry-run > "$TEST_TMP/fractional-limit-dry-run.txt" 2>&1
assert_file_contains \
    "$TEST_TMP/fractional-limit-dry-run.txt" \
    "Capture limit: first 0.25 GB (250000000 bytes)"
assert_file_contains \
    "$TEST_TMP/fractional-limit-dry-run.txt" \
    "PC-SMALL.first-0.25GB.img"

printf 'Checking interactive disk selection...\n'
(
    source "$PROJECT_DIR/archive-disk.sh"

    identify_output_disks() {
        return 0
    }

    available_disk_paths() {
        printf '%s\n' /dev/fixture-a /dev/fixture-b
    }

    print_disk_summary() {
        printf '%s 2G Fixture-Disk FIXTURE-SERIAL sata\n' "$1"
    }

    validate_target_disk() {
        [[ $1 == /dev/fixture-b ]] || fail "interactive picker selected the wrong disk"
    }

    select_target_disks <<< $'9\n2' 2> "$TEST_TMP/disk-picker.txt"
    [[ ${TARGET_DISKS[0]} == /dev/fixture-b ]] || \
        fail "interactive picker did not save the selected disk"
)
assert_file_contains "$TEST_TMP/disk-picker.txt" "[1] /dev/fixture-a"
assert_file_contains "$TEST_TMP/disk-picker.txt" "Enter an integer from 0 to 2."
assert_file_contains "$TEST_TMP/disk-picker.txt" "Selected source disk: /dev/fixture-b"

printf 'Checking smartctl status interpretation...\n'
(
    source "$PROJECT_DIR/archive-disk.sh"
    COMMANDS_JSONL="$TEST_TMP/smartctl-commands.jsonl"
    RECORD_ROOT="$TEST_TMP"

    smartctl() {
        printf 'SMART report with a recorded error log entry\n'
        return 64
    }

    run_smartctl_collection \
        collect_smartctl_sda \
        "$TEST_TMP/smartctl-sda.txt" \
        "$TEST_TMP/collect_smartctl-sda.stderr.log" \
        /dev/sda \
        2> "$TEST_TMP/smartctl-console.txt"
)
assert_file_contains "$TEST_TMP/smartctl-sda.txt" "SMART report"
assert_file_contains "$TEST_TMP/collect_smartctl-sda.stderr.log" "wrote no standard error"
assert_file_contains "$TEST_TMP/smartctl-console.txt" "contains recorded errors"
jq --exit-status '.name == "collect_smartctl_sda" and .exit_code == 64' \
    "$TEST_TMP/smartctl-commands.jsonl" >/dev/null || \
    fail "smartctl command record did not retain its bitmask exit status"

printf 'Checking smartctl standard-report fallback...\n'
(
    source "$PROJECT_DIR/archive-disk.sh"
    COMMANDS_JSONL="$TEST_TMP/smartctl-fallback-commands.jsonl"
    RECORD_ROOT="$TEST_TMP"

    smartctl() {
        if [[ $1 == -x ]]; then
            printf 'Partial extended SMART report\n'
            return 4
        fi

        printf 'Complete standard SMART report\n'
        return 0
    }

    run_smartctl_collection \
        collect_smartctl_sdb \
        "$TEST_TMP/smartctl-sdb.txt" \
        "$TEST_TMP/collect_smartctl-sdb.stderr.log" \
        /dev/sdb \
        2> "$TEST_TMP/smartctl-fallback-console.txt"
)
assert_file_contains "$TEST_TMP/smartctl-sdb.txt" "Partial extended SMART report"
assert_file_contains "$TEST_TMP/smartctl-sdb.basic.txt" "Complete standard SMART report"
assert_file_contains \
    "$TEST_TMP/smartctl-fallback-console.txt" \
    "smartctl -a fallback report was collected"
jq --exit-status --slurp '
    length == 2 and
    .[0].name == "collect_smartctl_sdb" and
    .[0].exit_code == 4 and
    .[1].name == "collect_smartctl_sdb_basic" and
    .[1].exit_code == 0
' "$TEST_TMP/smartctl-fallback-commands.jsonl" >/dev/null || \
    fail "smartctl fallback commands were not recorded correctly"

if bash "$PROJECT_DIR/archive-disk.sh" \
    --pc-id PC-TEST \
    --output "$TEST_TMP/invalid-limit-output" \
    --target /dev/test-disk \
    --max-read-gb 0 \
    --dry-run >/dev/null 2>&1; then
    fail "archive dry run accepted a zero capture limit"
fi

(
    source "$PROJECT_DIR/archive-disk.sh"
    MAX_READ_BYTES=250000000
    blockdev() {
        case $1 in
            --getsize64) printf '1000000000\n' ;;
            --getss) printf '512\n' ;;
        esac
    }
    aligned_bytes=$(capture_byte_count /dev/test-disk)
    [[ $aligned_bytes == 249999872 ]] || \
        fail "capture limit was not aligned to the disk sector size"
)

bash "$PROJECT_DIR/extract-metadata.sh" \
    --pc-id PC-TEST \
    --root "$TEST_TMP/metadata-output" \
    --image "$TEST_TMP/fixture.img" \
    --dry-run > "$TEST_TMP/metadata-dry-run.txt"
[[ ! -e $TEST_TMP/metadata-output ]] || fail "metadata dry run created its output directory"
assert_file_contains "$TEST_TMP/metadata-dry-run.txt" "read-only guestmount mounts"

printf 'Checking shared command records and README blocks...\n'
# shellcheck source=../lib/common.sh
source "$PROJECT_DIR/lib/common.sh"
COMMANDS_JSONL="$TEST_TMP/commands.jsonl"
RECORD_ROOT="$TEST_TMP"
run_recorded_command fixture_command \
    "$TEST_TMP/stdout.txt" "$TEST_TMP/stderr.txt" \
    printf '%s\n' fixture
jq --exit-status '
    .name == "fixture_command"
    and .exit_code == 0
    and .stdout == "stdout.txt"
    and .timezone == "America/New_York"
    and (.started_at | test("-0[45]:00$"))
    and (.completed_at | test("-0[45]:00$"))
' "$COMMANDS_JSONL" >/dev/null || fail "command record is invalid"

run_recorded_command_live visible_fixture_command \
    "$TEST_TMP/visible-stdout.txt" "$TEST_TMP/visible-stderr.txt" \
    bash -c 'printf "visible stdout\n"; printf "visible stderr\n" >&2' \
    > "$TEST_TMP/visible-console-stdout.txt" \
    2> "$TEST_TMP/visible-console-stderr.txt"
assert_file_contains "$TEST_TMP/visible-stdout.txt" "visible stdout"
assert_file_contains "$TEST_TMP/visible-stderr.txt" "visible stderr"
assert_file_contains "$TEST_TMP/visible-console-stdout.txt" "visible stdout"
assert_file_contains "$TEST_TMP/visible-console-stderr.txt" "visible stderr"

run_optional_command optional_empty_stderr \
    "$TEST_TMP/optional-stdout.txt" "$TEST_TMP/optional-stderr.txt" \
    bash -c 'printf "failure details on stdout\n"; exit 7'
assert_file_contains "$TEST_TMP/optional-stdout.txt" "failure details on stdout"
assert_file_contains "$TEST_TMP/optional-stderr.txt" "wrote no standard error"
assert_file_contains "$TEST_TMP/optional-stderr.txt" "$TEST_TMP/optional-stdout.txt"

printf '# Fixture\n\nManual text.\n' > "$TEST_TMP/README.md"
printf 'First generated value.\n' > "$TEST_TMP/block.md"
update_readme_block "$TEST_TMP/README.md" fixture-owner "$TEST_TMP/block.md"
printf 'Replacement generated value.\n' > "$TEST_TMP/block.md"
update_readme_block "$TEST_TMP/README.md" fixture-owner "$TEST_TMP/block.md"
assert_file_contains "$TEST_TMP/README.md" "Manual text."
assert_file_contains "$TEST_TMP/README.md" "Replacement generated value."
if grep --fixed-strings --quiet "First generated value." "$TEST_TMP/README.md"; then
    fail "managed README block was appended instead of replaced"
fi

printf 'Checking metadata parsers and guest path containment...\n'
# shellcheck source=../extract-metadata.sh
source "$PROJECT_DIR/extract-metadata.sh"
METADATA_DIR="$TEST_TMP/metadata"
SESSION_DIR="$TEST_TMP/session"
WORK_DIR="$TEST_TMP/work"
LOGS_DIR="$TEST_TMP/logs"
COMMANDS_JSONL="$TEST_TMP/metadata-commands.jsonl"
RECORD_ROOT="$METADATA_DIR"
mkdir -p \
    "$METADATA_DIR/linux" \
    "$METADATA_DIR/windows" \
    "$SESSION_DIR" \
    "$WORK_DIR" \
    "$LOGS_DIR" \
    "$TEST_TMP/guest/etc" \
    "$TEST_TMP/guest/Users/Alice" \
    "$TEST_TMP/outside"

cat > "$TEST_TMP/dpkg-status" <<'EOF'
Package: installed-package
Status: install ok installed
Version: 1.2.3
Architecture: amd64

Package: removed-package
Status: deinstall ok config-files
Version: 4.5.6
Architecture: amd64
EOF
parse_dpkg_packages "$TEST_TMP/dpkg-status" > "$TEST_TMP/packages.json"
jq --exit-status '
    .package_manager == "dpkg"
    and (.packages | length) == 1
    and .packages[0].name == "installed-package"
' "$TEST_TMP/packages.json" >/dev/null || fail "dpkg parser returned unexpected data"

printf '%s\n' 'psk=keep-out' 'password: keep-out-too' 'address=192.0.2.10' \
    | redact_network_content > "$TEST_TMP/redacted.txt"
if grep --fixed-strings --quiet "keep-out" "$TEST_TMP/redacted.txt"; then
    fail "network secret redaction retained a fixture secret"
fi
assert_file_contains "$TEST_TMP/redacted.txt" "address=192.0.2.10"

mkdir -p "$TEST_TMP/guest/etc/NetworkManager/system-connections"
printf '%s\n' 'psk=a-different-secret' \
    > "$TEST_TMP/guest/etc/NetworkManager/system-connections/wifi.nmconnection"
: > "$TEST_TMP/network-records.jsonl"
REDACT_SECRETS=true
add_linux_network_file \
    "$TEST_TMP/guest" \
    "$TEST_TMP/guest/etc/NetworkManager/system-connections/wifi.nmconnection" \
    "$TEST_TMP/network-records.jsonl"
jq --exit-status '.[0].content == "<redacted: sensitive connection file omitted>"' \
    --slurp "$TEST_TMP/network-records.jsonl" >/dev/null || \
    fail "sensitive network connection file was not omitted"

ln -s "$TEST_TMP/outside" "$TEST_TMP/guest/etc/escaping-link"
if safe_existing_guest_path "$TEST_TMP/guest" etc/escaping-link >/dev/null; then
    fail "guest path containment accepted an escaping symlink"
fi

cat > "$TEST_TMP/apps.reg" <<'EOF'
[HKEY_LOCAL_MACHINE\Software\Fixture]
"DisplayName"="Fixture App"
"DisplayVersion"="9.0"
"Publisher"="Fixture Publisher"
EOF
: > "$TEST_TMP/apps.tsv"
parse_windows_applications \
    "$TEST_TMP/apps.reg" "$METADATA_DIR/windows/applications.json" "$TEST_TMP/apps.tsv"
parse_windows_applications \
    "$TEST_TMP/missing.reg" "$METADATA_DIR/windows/applications.json" "$TEST_TMP/apps.tsv"
jq --exit-status '
    length == 1
    and .[0].display_name == "Fixture App"
' "$METADATA_DIR/windows/applications.json" >/dev/null || \
    fail "Windows application parser returned unexpected data"

cat > "$TEST_TMP/profiles.reg" <<'EOF'
[HKEY_LOCAL_MACHINE\Software\ProfileList\S-1-5-21-1000]
"ProfileImagePath"="C:\\Users\\Alice"
EOF
extract_windows_profiles "$TEST_TMP/guest" "$TEST_TMP/profiles.reg"
jq --exit-status '
    length == 1
    and .[0].sid == "S-1-5-21-1000"
    and .[0].profile_directory_exists == true
' "$METADATA_DIR/windows/profiles.json" >/dev/null || \
    fail "Windows profile parser returned unexpected data"

printf 'Checking the archive workflow with command doubles...\n'
(
    # Exercise orchestration and reports without reading a physical disk.
    source "$PROJECT_DIR/archive-disk.sh"

    select_target_disks() {
        TARGET_DISKS=(/dev/test-disk)
    }

    validate_runtime() {
        return 0
    }

    check_and_offer_dependencies() {
        return 0
    }

    collect_livecd_information() {
        return 0
    }

    collect_hardware_information() {
        return 0
    }

    collect_disk_information() {
        return 0
    }

    confirm_targets() {
        return 0
    }

    check_source_mounts() {
        return 0
    }

    check_free_space() {
        return 0
    }

    capture_byte_count() {
        printf '1000000000\n'
    }

    disk_field() {
        case $2 in
            SIZE) printf '2000000000\n' ;;
            MODEL) printf 'Fixture Disk\n' ;;
            SERIAL) printf 'FIXTURE-SERIAL\n' ;;
        esac
    }

    ddrescue() {
        local -a arguments=("$@")
        local argument_count=${#arguments[@]}
        local raw_image=${arguments[argument_count - 2]}
        local map_file=${arguments[argument_count - 1]}
        local argument
        local direct_io=false
        local size_argument_found=false

        for argument in "${arguments[@]}"; do
            if [[ $argument == --size=1000000000 ]]; then
                size_argument_found=true
            elif [[ $argument == --idirect ]]; then
                direct_io=true
            elif [[ $argument == --direct ]]; then
                fail "ddrescue was called with the unsupported --direct option"
            fi
        done
        [[ $size_argument_found == true ]] || fail "limited ddrescue command omitted its byte limit"

        printf 'fixture ddrescue progress\n' >&2
        if [[ $direct_io == true ]]; then
            printf 'fixture direct I/O is unavailable\n' >&2
            return 1
        fi

        if [[ ! -f $raw_image ]]; then
            printf 'fixture disk image\n' > "$raw_image"
        fi
        touch "$map_file"
    }

    zstd() {
        local input_file=""
        local output_file=""

        if [[ $1 == --test ]]; then
            return 0
        fi

        while (($# > 0)); do
            case $1 in
                -o)
                    output_file=$2
                    shift 2
                    ;;
                --output*)
                    fail "zstd was called with the unsupported --output option"
                    ;;
                --*)
                    shift
                    ;;
                *)
                    input_file=$1
                    shift
                    ;;
            esac
        done

        [[ -n $input_file && -n $output_file ]] || \
            fail "zstd did not receive its input and output paths"
        cp -- "$input_file" "$output_file"
        printf 'fixture zstd progress\n' >&2
    }

    main \
        --pc-id PC-ARCHIVE-WORKFLOW \
        --output "$TEST_TMP/archive-workflow-output" \
        --target /dev/test-disk \
        --max-read-gb 1 \
        --compress zstd \
        --yes
)
ARCHIVE_WORKFLOW_ROOT="$TEST_TMP/archive-workflow-output/PC-ARCHIVE-WORKFLOW"
jq --exit-status '
    .pc_id == "PC-ARCHIVE-WORKFLOW"
    and .timezone == "America/New_York"
    and .run.mode == "limited_capture"
    and .run.requested_limit_bytes == 1000000000
    and (.started_at | test("-0[45]:00$"))
    and (.completed_at | test("-0[45]:00$"))
    and (.source_disks | length) == 1
    and .source_disks[0].image == "PC-ARCHIVE-WORKFLOW.first-1GB.img.zst"
    and .source_disks[0].capture.mode == "limited"
    and .source_disks[0].capture.rescue_domain_bytes == 1000000000
    and .source_disks[0].compressed_sha256_file == "PC-ARCHIVE-WORKFLOW.first-1GB.img.zst.sha256"
    and .source_disks[0].ddrescue_logs == [
        "logs/ddrescue-pass1.log",
        "logs/ddrescue-pass1.stderr.log",
        "logs/ddrescue-pass2.log",
        "logs/ddrescue-pass2.stderr.log",
        "logs/ddrescue-pass2-buffered.log",
        "logs/ddrescue-pass2-buffered.stderr.log"
    ]
' "$ARCHIVE_WORKFLOW_ROOT/ARCHIVE/PC-ARCHIVE-WORKFLOW.archive.json" >/dev/null || \
    fail "archive workflow summary returned unexpected data"
jq --slurp --exit-status '
    length == 8
    and ([.[] | select(.exit_code != 0) | .exit_code] == [1])
    and any(.[]; .name | startswith("ddrescue_pass2_buffered_"))
' "$ARCHIVE_WORKFLOW_ROOT/ARCHIVE/commands.jsonl" >/dev/null || \
    fail "archive workflow command records returned unexpected data"
[[ -f $ARCHIVE_WORKFLOW_ROOT/ARCHIVE/PC-ARCHIVE-WORKFLOW.first-1GB.img.zst ]] || \
    fail "archive workflow did not create its compressed image"

printf 'Checking the documentation-only archive workflow...\n'
(
    source "$PROJECT_DIR/archive-disk.sh"

    select_target_disks() {
        TARGET_DISKS=(/dev/documented-disk)
    }

    validate_runtime() {
        return 0
    }

    check_and_offer_dependencies() {
        return 0
    }

    collect_livecd_information() {
        return 0
    }

    collect_hardware_information() {
        return 0
    }

    collect_disk_information() {
        return 0
    }

    disk_field() {
        case $2 in
            SIZE) printf '4000000000\n' ;;
            MODEL) printf 'Documentation Fixture Disk\n' ;;
            SERIAL) printf 'DOCS-SERIAL\n' ;;
        esac
    }

    ddrescue() {
        fail "documentation-only mode invoked ddrescue"
    }

    main \
        --pc-id PC-DOCUMENTATION \
        --output "$TEST_TMP/documentation-output" \
        --target /dev/documented-disk \
        --documentation-only \
        --max-read-gb 2
)
DOCUMENTATION_ROOT="$TEST_TMP/documentation-output/PC-DOCUMENTATION"
jq --exit-status '
    .run.mode == "documentation_only"
    and .run.requested_limit_bytes == 2000000000
    and (.source_disks | length) == 1
    and .source_disks[0].capture_status == "not_run"
    and .source_disks[0].capture.mode == "documentation_only"
    and .source_disks[0].capture.requested_limit_bytes == 2000000000
    and .source_disks[0].capture.rescue_domain_bytes == 0
    and .source_disks[0].image == null
' "$DOCUMENTATION_ROOT/ARCHIVE/PC-DOCUMENTATION.archive.json" >/dev/null || \
    fail "documentation-only summary returned unexpected data"
if find "$DOCUMENTATION_ROOT/ARCHIVE" -maxdepth 1 \
    \( -name '*.img' -o -name '*.zst' -o -name '*.sha256' -o -name '*.map' \) \
    -print -quit | grep --quiet .; then
    fail "documentation-only mode created an image-related file"
fi
assert_file_contains \
    "$DOCUMENTATION_ROOT/ARCHIVE/README.md" \
    "No image files were created."

printf 'Checking the metadata workflow with read-only command doubles...\n'
(
    # Exercise the orchestration without requiring root, FUSE, or a real image.
    source "$PROJECT_DIR/extract-metadata.sh"

    require_root() {
        return 0
    }

    require_tool() {
        return 0
    }

    fixture_mount_is_active=false

    mountpoint() {
        [[ $fixture_mount_is_active == true ]]
    }

    guestfish() {
        printf '/dev/sda1: ext4\n'
    }

    guestmount() {
        local argument
        local mount_dir=${@: -1}
        local previous_argument=""

        for argument in "$@"; do
            if [[ $previous_argument == --pid-file ]]; then
                printf '%s\n' 999999999 > "$argument"
            fi
            previous_argument=$argument
        done

        fixture_mount_is_active=true
        mkdir -p "$mount_dir/etc" "$mount_dir/var/lib/dpkg"
        printf '%s\n' 'NAME="Workflow Linux"' 'VERSION_ID="1"' \
            > "$mount_dir/etc/os-release"
        printf '%s\n' workflow-host > "$mount_dir/etc/hostname"
        printf '%s\n' 'root:x:0:0:root:/root:/bin/bash' \
            > "$mount_dir/etc/passwd"
        printf '%s\n' 'root:x:0:' > "$mount_dir/etc/group"
        printf '%s\n' 'UUID=fixture / ext4 defaults 0 1' > "$mount_dir/etc/fstab"
        printf '%s\n' \
            'Package: workflow-package' \
            'Status: install ok installed' \
            'Version: 1.0' \
            'Architecture: amd64' \
            > "$mount_dir/var/lib/dpkg/status"
    }

    guestunmount() {
        # Reproduce guestmount removing its PID file during shutdown.
        fixture_mount_is_active=false
        rm -f -- "$ACTIVE_MOUNT_PID_FILE"
        return 0
    }

    main \
        --pc-id PC-WORKFLOW \
        --root "$TEST_TMP/workflow-output" \
        --image "$TEST_TMP/fixture.img"
)
jq --exit-status '
    .pc_id == "PC-WORKFLOW"
    and .timezone == "America/New_York"
    and (.started_at | test("-0[45]:00$"))
    and (.completed_at | test("-0[45]:00$"))
    and .extraction.linux.extracted == true
    and .extraction.linux.users == 1
    and .extraction.linux.packages == 1
' "$TEST_TMP/workflow-output/METADATA/PC-WORKFLOW.metadata.json" >/dev/null || \
    fail "metadata workflow summary returned unexpected data"
assert_file_contains \
    "$TEST_TMP/workflow-output/METADATA/logs/extract-metadata.log" \
    "Inspecting selected image: $TEST_TMP/fixture.img"
assert_file_contains \
    "$TEST_TMP/workflow-output/METADATA/logs/extract-metadata.log" \
    "image filesystem /dev/sda1"
if find "$TEST_TMP/workflow-output/METADATA/work" \
    -maxdepth 1 -type d -name 'session.*' -print -quit | grep --quiet .; then
    fail "metadata workflow retained a temporary session directory"
fi

printf 'All tests passed.\n'
