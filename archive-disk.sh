#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

PC_ID=""
OUTPUT_PARENT=""
OUTPUT_ROOT=""
TARGET_DISK=""
ALL_INTERNAL_DISKS=false
COMPRESSION="zstd"
REMOVE_RAW=false
RETRY_COUNT=3
ASSUME_YES=false
DOCUMENTATION_ONLY=false
MAX_READ_GB=""
MAX_READ_BYTES=""

ARCHIVE_DIR=""
LOGS_DIR=""
STARTED_AT=""
STARTED_EPOCH=0
SOURCE_DISKS_JSON='[]'
PARTIAL_COMPRESSED_IMAGE=""
declare -a TARGET_DISKS=()
declare -a OUTPUT_DISKS=()
declare -a WARNINGS=()

usage() {
    cat <<'EOF'
Usage:
  archive-disk.sh [options]

Archive identity and destination:
  --pc-id ID                      Identifier; prompted as text when omitted
  --output PATH                   Parent directory; prompted as a list when omitted

Disk selection:
  --target DEVICE                 Whole source disk; omit for an interactive list
  --all-internal-disks            Archive every non-removable internal disk
  (omit both)                     Show available disks and select by number

Options:
  --compress none|zstd            Compression format (default: zstd)
  --keep-raw                      Keep raw images after compression (default)
  --remove-raw-after-compress     Delete raw images after verified compression
  --retry-count N                 ddrescue retry passes (default: 3)
  --documentation-only            Generate records and documentation; do not image
  --max-read-gb NUMBER            Capture the first decimal GB amount of each disk
  --dry-run                       Describe actions without writing or imaging
  --yes                           Skip the interactive confirmation
  --debug                         Enable debug logging
  --help                          Show this help
EOF
}

add_warning() {
    WARNINGS+=("$*")
    log_warn "$*"
}

pc_id_is_valid() {
    local pc_id=$1

    [[ $pc_id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

prompt_for_pc_id() {
    local entered_pc_id

    while true; do
        printf 'Enter the PC ID (for example, PC-001): ' >&2
        if ! read -r entered_pc_id; then
            die "No PC ID was received."
        fi
        if pc_id_is_valid "$entered_pc_id"; then
            PC_ID=$entered_pc_id
            return 0
        fi
        printf '%s\n' \
            "Use letters, numbers, dots, underscores, or hyphens; the first character must be a letter or number." \
            >&2
    done
}

output_filesystem_is_system_only() {
    local filesystem=$1

    case $filesystem in
        autofs|devpts|devtmpfs|overlay|proc|ramfs|sysfs|tmpfs)
            return 0
            ;;
        bpf|binfmt_misc|cgroup|cgroup2|configfs|debugfs|efivarfs|fusectl)
            return 0
            ;;
        fuse.gvfsd-fuse|fuse.portal|hugetlbfs|mqueue|nsfs|pstore|rpc_pipefs)
            return 0
            ;;
        securityfs|selinuxfs|smackfs|tracefs)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

available_output_paths() {
    local filesystem
    local mount_point
    local -A seen_paths=()

    while IFS= read -r mount_point; do
        [[ -n $mount_point && $mount_point != / && -d $mount_point ]] || continue
        [[ -z ${seen_paths[$mount_point]+present} ]] || continue

        filesystem=$(findmnt --noheadings --first-only --output FSTYPE \
            --mountpoint "$mount_point" 2>/dev/null || true)
        filesystem=${filesystem//[[:space:]]/}
        output_filesystem_is_system_only "$filesystem" && continue

        seen_paths[$mount_point]=true
        printf '%s\n' "$mount_point"
    done < <(
        findmnt --json --list --options rw --output TARGET 2>/dev/null |
            jq --raw-output '.filesystems[]?.target // empty' 2>/dev/null
    )
}

print_output_summary() {
    local output_path=$1
    local available
    local filesystem
    local source

    source=$(findmnt --noheadings --output SOURCE --target "$output_path" 2>/dev/null || true)
    filesystem=$(findmnt --noheadings --output FSTYPE --target "$output_path" 2>/dev/null || true)
    available=$(df --human-readable --output=avail "$output_path" 2>/dev/null |
        awk 'NR == 2 {print $1}' || true)

    printf '%s (source: %s, filesystem: %s, available: %s)\n' \
        "$output_path" \
        "${source:-unknown}" \
        "${filesystem:-unknown}" \
        "${available:-unknown}"
}

prompt_for_custom_output_path() {
    local entered_path

    printf 'Enter the output parent directory: ' >&2
    if ! read -r entered_path; then
        die "No output directory was received."
    fi
    [[ -n $entered_path ]] || die "The output parent directory cannot be empty."
    OUTPUT_PARENT=$entered_path
}

prompt_for_output_parent() {
    local -a output_paths=()
    local custom_selection
    local index
    local selection

    mapfile -t output_paths < <(available_output_paths)
    if ((${#output_paths[@]} == 0)); then
        printf 'No writable non-root filesystem mount points were found.\n' >&2
        prompt_for_custom_output_path
        return 0
    fi

    custom_selection=$((${#output_paths[@]} + 1))
    printf 'Available output parent directories:\n' >&2
    for index in "${!output_paths[@]}"; do
        printf '  [%d] ' "$((index + 1))" >&2
        print_output_summary "${output_paths[index]}" >&2
    done
    printf '  [%d] Enter a different directory path\n' "$custom_selection" >&2
    printf '  [0] Cancel\n' >&2

    while true; do
        printf 'Select the output parent directory by number: ' >&2
        if ! read -r selection; then
            die "No output directory selection was received."
        fi
        if [[ $selection == 0 ]]; then
            die "Output directory selection was cancelled."
        fi
        if [[ $selection =~ ^[1-9][0-9]*$ ]] && \
            ((selection <= ${#output_paths[@]})); then
            OUTPUT_PARENT=${output_paths[selection - 1]}
            printf 'Selected output parent: %s\n' "$OUTPUT_PARENT" >&2
            return 0
        fi
        if [[ $selection == "$custom_selection" ]]; then
            prompt_for_custom_output_path
            return 0
        fi
        printf 'Enter an integer from 0 to %d.\n' "$custom_selection" >&2
    done
}

prompt_for_missing_arguments() {
    if [[ -z $PC_ID ]]; then
        prompt_for_pc_id
    fi
    if [[ -z $OUTPUT_PARENT ]]; then
        prompt_for_output_parent
    fi
}

parse_arguments() {
    while (($# > 0)); do
        case $1 in
            --pc-id)
                (($# >= 2)) || die "--pc-id requires a value."
                PC_ID=$2
                shift 2
                ;;
            --output)
                (($# >= 2)) || die "--output requires a value."
                OUTPUT_PARENT=$2
                shift 2
                ;;
            --target)
                (($# >= 2)) || die "--target requires a value."
                TARGET_DISK=$2
                shift 2
                ;;
            --all-internal-disks)
                ALL_INTERNAL_DISKS=true
                shift
                ;;
            --compress)
                (($# >= 2)) || die "--compress requires a value."
                COMPRESSION=$2
                shift 2
                ;;
            --keep-raw)
                REMOVE_RAW=false
                shift
                ;;
            --remove-raw-after-compress)
                REMOVE_RAW=true
                shift
                ;;
            --retry-count)
                (($# >= 2)) || die "--retry-count requires a value."
                RETRY_COUNT=$2
                shift 2
                ;;
            --documentation-only|--docs-only)
                DOCUMENTATION_ONLY=true
                shift
                ;;
            --max-read-gb)
                (($# >= 2)) || die "--max-read-gb requires a value."
                MAX_READ_GB=$2
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --yes)
                ASSUME_YES=true
                shift
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
    done
}

validate_arguments() {
    local whole_gb
    local fractional_gb

    [[ -n $PC_ID ]] || die "A PC ID is required."
    pc_id_is_valid "$PC_ID" || \
        die "--pc-id may contain only letters, numbers, dots, underscores, and hyphens."
    [[ -n $OUTPUT_PARENT ]] || die "An output parent directory is required."
    [[ $COMPRESSION == none || $COMPRESSION == zstd ]] || \
        die "--compress must be 'none' or 'zstd'."
    [[ $RETRY_COUNT =~ ^[0-9]+$ ]] || die "--retry-count must be a non-negative integer."
    if [[ -n $MAX_READ_GB ]]; then
        [[ $MAX_READ_GB =~ ^(0|[1-9][0-9]*)(\.[0-9]{1,9})?$ ]] || \
            die "--max-read-gb must be a positive number with no more than nine decimal places."
        whole_gb=${MAX_READ_GB%%.*}
        ((${#whole_gb} <= 10)) || die "--max-read-gb is too large."
        ((10#$whole_gb <= 9000000000)) || die "--max-read-gb is too large."
        fractional_gb=0
        if [[ $MAX_READ_GB == *.* ]]; then
            fractional_gb=${MAX_READ_GB#*.}000000000
            fractional_gb=${fractional_gb:0:9}
        fi
        MAX_READ_BYTES=$((10#$whole_gb * 1000000000 + 10#$fractional_gb))
        ((MAX_READ_BYTES > 0)) || die "--max-read-gb must be greater than zero."
    fi

    if [[ -n $TARGET_DISK && $ALL_INTERNAL_DISKS == true ]]; then
        die "Use either --target or --all-internal-disks, not both."
    fi
    if [[ $REMOVE_RAW == true && $COMPRESSION == none ]]; then
        die "--remove-raw-after-compress requires --compress zstd."
    fi
    if [[ $DOCUMENTATION_ONLY == true && $REMOVE_RAW == true ]]; then
        die "--remove-raw-after-compress cannot be used with --documentation-only."
    fi

    OUTPUT_PARENT=$(realpath --canonicalize-missing -- "$OUTPUT_PARENT")
    [[ $OUTPUT_PARENT != / ]] || \
        die "The filesystem root cannot be used as the --output parent."
    if [[ $(basename -- "$OUTPUT_PARENT") == "$PC_ID" ]]; then
        die \
            "--output expects the parent directory, but '$OUTPUT_PARENT' already ends with the PC ID." \
            "Use '$(dirname -- "$OUTPUT_PARENT")' instead."
    fi
    OUTPUT_ROOT=$(realpath --canonicalize-missing -- "$OUTPUT_PARENT/$PC_ID")
}

find_existing_parent() {
    local path=$1

    while [[ ! -e $path ]]; do
        path=$(dirname -- "$path")
    done
    printf '%s\n' "$path"
}

identify_output_disks() {
    local existing_parent
    local output_source
    local disk

    existing_parent=$(find_existing_parent "$OUTPUT_ROOT")
    output_source=$(findmnt --noheadings --output SOURCE --target "$existing_parent" 2>/dev/null || true)
    [[ -n $output_source ]] || return 0
    output_source=${output_source%%\[*}

    while IFS= read -r disk; do
        [[ -n $disk ]] && OUTPUT_DISKS+=("$disk")
    done < <(lsblk --inverse --noheadings --paths --output NAME,TYPE "$output_source" 2>/dev/null |
        awk '$2 == "disk" {print $1}')
}

is_output_disk() {
    local candidate=$1
    local output_disk

    for output_disk in "${OUTPUT_DISKS[@]}"; do
        if [[ $candidate == "$output_disk" ]]; then
            return 0
        fi
    done
    return 1
}

validate_target_disk() {
    local target=$1
    local device_type

    if [[ $DRY_RUN == true && ! -b $target ]]; then
        log_warn "Dry run: $target is not currently a block device; device checks were skipped."
        return 0
    fi

    [[ -b $target ]] || die "Target is not a block device: $target"
    device_type=$(lsblk --noheadings --nodeps --output TYPE "$target" | tr -d '[:space:]')
    [[ $device_type == disk ]] || die "Target must be a whole disk, not a partition: $target"

    if is_output_disk "$target"; then
        die "Refusing to archive $target because it contains the output directory."
    fi
}

select_target_disks() {
    local disk

    identify_output_disks

    if [[ -n $TARGET_DISK ]]; then
        if [[ -e $TARGET_DISK ]]; then
            TARGET_DISK=$(readlink --canonicalize -- "$TARGET_DISK")
        fi
        validate_target_disk "$TARGET_DISK"
        TARGET_DISKS+=("$TARGET_DISK")
        return 0
    fi

    if [[ $ALL_INTERNAL_DISKS == false ]]; then
        prompt_for_target_disk
        validate_target_disk "$TARGET_DISK"
        TARGET_DISKS+=("$TARGET_DISK")
        return 0
    fi

    while IFS= read -r disk; do
        [[ -n $disk ]] || continue
        if ! is_output_disk "$disk"; then
            TARGET_DISKS+=("$disk")
        fi
    done < <(lsblk --noheadings --nodeps --paths --output NAME,TYPE,RM,TRAN |
        awk '$2 == "disk" && $3 == "0" && $4 != "usb" {print $1}')

    ((${#TARGET_DISKS[@]} > 0)) || die "No eligible internal disks were found."
    for disk in "${TARGET_DISKS[@]}"; do
        validate_target_disk "$disk"
    done
}

available_disk_paths() {
    local disk

    while IFS= read -r disk; do
        [[ -n $disk ]] || continue
        if ! is_output_disk "$disk"; then
            printf '%s\n' "$disk"
        fi
    done < <(lsblk --noheadings --nodeps --paths --output NAME,TYPE |
        awk '$2 == "disk" {print $1}')
}

print_disk_summary() {
    local disk=$1

    lsblk --noheadings --nodeps --paths \
        --output PATH,SIZE,MODEL,SERIAL,TRAN "$disk"
}

prompt_for_target_disk() {
    local -a available_disks=()
    local index
    local selection

    mapfile -t available_disks < <(available_disk_paths)
    ((${#available_disks[@]} > 0)) || \
        die "No source disks are available after excluding the archive destination disk."

    printf 'Available whole disks (the archive destination disk is excluded):\n' >&2
    for index in "${!available_disks[@]}"; do
        printf '  [%d] ' "$((index + 1))" >&2
        print_disk_summary "${available_disks[index]}" >&2
    done
    printf '  [0] Cancel\n' >&2

    while true; do
        printf 'Select the disk to archive by number: ' >&2
        if ! read -r selection; then
            die "No disk selection was received."
        fi
        if [[ $selection == 0 ]]; then
            die "Disk selection was cancelled."
        fi
        if [[ $selection =~ ^[1-9][0-9]*$ ]] && \
            ((selection <= ${#available_disks[@]})); then
            TARGET_DISK=${available_disks[selection - 1]}
            printf 'Selected source disk: %s\n' "$TARGET_DISK" >&2
            return 0
        fi
        printf 'Enter an integer from 0 to %d.\n' "${#available_disks[@]}" >&2
    done
}

image_base_for_disk() {
    local disk=$1
    local image_base

    if ((${#TARGET_DISKS[@]} == 1)); then
        image_base=$PC_ID
    else
        image_base="$PC_ID-$(basename -- "$disk")"
    fi

    if [[ -n $MAX_READ_GB ]]; then
        image_base+=".first-${MAX_READ_GB}GB"
    fi

    printf '%s\n' "$image_base"
}

log_suffix_for_disk() {
    local image_base=$1

    if ((${#TARGET_DISKS[@]} == 1)); then
        printf '\n'
    else
        printf '%s\n' "-$image_base"
    fi
}

show_dry_run() {
    local disk
    local image_base

    printf 'Dry-run archive plan\n'
    printf '  PC ID: %s\n' "$PC_ID"
    printf '  Output parent: %s\n' "$OUTPUT_PARENT"
    printf '  Working directory: %s\n' "$OUTPUT_ROOT"
    printf '  Documentation only: %s\n' "$DOCUMENTATION_ONLY"
    if [[ $DOCUMENTATION_ONLY == true ]]; then
        printf '  Compression: not applicable\n'
    else
        printf '  Compression: %s\n' "$COMPRESSION"
    fi
    if [[ -n $MAX_READ_GB ]]; then
        printf '  Capture limit: first %s GB (%s bytes)\n' "$MAX_READ_GB" "$MAX_READ_BYTES"
    else
        printf '  Capture limit: full disk\n'
    fi
    if [[ $DOCUMENTATION_ONLY == false ]]; then
        printf '  Remove raw after verified compression: %s\n' "$REMOVE_RAW"
        printf '  Retry count: %s\n' "$RETRY_COUNT"
    fi
    printf '  Directories that would be created:\n'
    printf '    %s\n' \
        "$OUTPUT_ROOT/ARCHIVE/logs" \
        "$OUTPUT_ROOT/ARCHIVE/livecd" \
        "$OUTPUT_ROOT/ARCHIVE/hardware" \
        "$OUTPUT_ROOT/ARCHIVE/disks"

    for disk in "${TARGET_DISKS[@]}"; do
        image_base=$(image_base_for_disk "$disk")
        printf '  Source disk: %s\n' "$disk"
        if [[ $DOCUMENTATION_ONLY == true ]]; then
            printf '    Documentation would be generated; ddrescue, hashing, and compression would not run.\n'
            continue
        fi
        printf '    ddrescue image: %s/ARCHIVE/%s.img\n' "$OUTPUT_ROOT" "$image_base"
        printf '    ddrescue map: %s/ARCHIVE/%s.ddrescue.map\n' "$OUTPUT_ROOT" "$image_base"
        printf '    raw hash: %s/ARCHIVE/%s.img.raw.sha256\n' "$OUTPUT_ROOT" "$image_base"
        if [[ $COMPRESSION == zstd ]]; then
            printf '    compressed image: %s/ARCHIVE/%s.img.zst\n' "$OUTPUT_ROOT" "$image_base"
            printf '    compressed hash: %s/ARCHIVE/%s.img.zst.sha256\n' "$OUTPUT_ROOT" "$image_base"
        fi
    done

    if [[ $DOCUMENTATION_ONLY == true ]]; then
        printf '  Commands would include inventory collection and documentation generation only'
    else
        printf '  Commands would include inventory collection, two ddrescue passes, SHA256 hashing'
        if [[ $COMPRESSION == zstd ]]; then
            printf ', zstd compression, and compressed-image verification'
        fi
    fi
    printf '.\n'
}

prepare_output_tree() {
    ARCHIVE_DIR="$OUTPUT_ROOT/ARCHIVE"
    LOGS_DIR="$ARCHIVE_DIR/logs"
    safe_mkdir "$LOGS_DIR"
    safe_mkdir "$ARCHIVE_DIR/livecd"
    safe_mkdir "$ARCHIVE_DIR/hardware"
    safe_mkdir "$ARCHIVE_DIR/disks"

    LOG_FILE="$LOGS_DIR/archive-disk.log"
    COMMANDS_JSONL="$ARCHIVE_DIR/commands.jsonl"
    RECORD_ROOT="$ARCHIVE_DIR"
    touch -- "$LOG_FILE" "$COMMANDS_JSONL"
}

cleanup_archive() {
    if [[ -n $PARTIAL_COMPRESSED_IMAGE && -f $PARTIAL_COMPRESSED_IMAGE ]]; then
        if rm -- "$PARTIAL_COMPRESSED_IMAGE"; then
            log_warn "Removed incomplete compressed image: $PARTIAL_COMPRESSED_IMAGE"
        else
            log_error "Could not remove incomplete compressed image: $PARTIAL_COMPRESSED_IMAGE"
            return 1
        fi
    fi
    if [[ -n $PARTIAL_COMPRESSED_IMAGE && -f $PARTIAL_COMPRESSED_IMAGE.sha256 ]]; then
        rm -- "$PARTIAL_COMPRESSED_IMAGE.sha256" || return 1
    fi
}

print_tool_versions() {
    local tool
    local first_line

    for tool in ddrescue zstd lsblk smartctl parted sfdisk jq; do
        printf '## %s\n' "$tool"
        if command -v "$tool" >/dev/null 2>&1; then
            first_line=$("$tool" --version 2>&1 | head -n 1 || true)
            printf '%s\n\n' "$first_line"
        else
            printf 'not installed\n\n'
        fi
    done
}

collect_livecd_information() {
    local output_dir="$ARCHIVE_DIR/livecd"

    run_recorded_command collect_os_release \
        "$output_dir/os-release.txt" "$LOGS_DIR/collect_os_release.stderr.log" \
        cat /etc/os-release || add_warning "Could not collect /etc/os-release."
    run_recorded_command collect_uname \
        "$output_dir/uname.txt" "$LOGS_DIR/collect_uname.stderr.log" \
        uname -a || add_warning "Could not collect uname output."
    run_recorded_command collect_kernel_cmdline \
        "$output_dir/kernel-cmdline.txt" "$LOGS_DIR/collect_kernel_cmdline.stderr.log" \
        cat /proc/cmdline || add_warning "Could not collect the kernel command line."
    run_recorded_command collect_date \
        "$output_dir/date.txt" "$LOGS_DIR/collect_date.stderr.log" \
        record_time_now || add_warning "Could not collect the current date."
    run_optional_command collect_timedatectl \
        "$output_dir/timedatectl.txt" "$LOGS_DIR/collect_timedatectl.stderr.log" \
        timedatectl
    run_recorded_command collect_tool_versions \
        "$output_dir/tool-versions.txt" "$LOGS_DIR/collect_tool_versions.stderr.log" \
        print_tool_versions || add_warning "Could not collect tool versions."
}

collect_hardware_information() {
    local output_dir="$ARCHIVE_DIR/hardware"

    run_optional_command collect_dmidecode \
        "$output_dir/dmidecode.txt" "$LOGS_DIR/collect_dmidecode.stderr.log" \
        dmidecode
    run_optional_command collect_lshw \
        "$output_dir/lshw.json" "$LOGS_DIR/collect_lshw.stderr.log" \
        lshw -json
    run_optional_command collect_lscpu \
        "$output_dir/lscpu.txt" "$LOGS_DIR/collect_lscpu.stderr.log" \
        lscpu
    run_recorded_command collect_meminfo \
        "$output_dir/meminfo.txt" "$LOGS_DIR/collect_meminfo.stderr.log" \
        cat /proc/meminfo || add_warning "Could not collect /proc/meminfo."
    run_optional_command collect_lsusb \
        "$output_dir/lsusb.txt" "$LOGS_DIR/collect_lsusb.stderr.log" \
        lsusb
    run_optional_command collect_lspci \
        "$output_dir/lspci.txt" "$LOGS_DIR/collect_lspci.stderr.log" \
        lspci -nn
}

collect_disk_information() {
    local disk
    local disk_name
    local safe_name
    local output_dir="$ARCHIVE_DIR/disks"

    run_recorded_command collect_lsblk \
        "$output_dir/lsblk.json" "$LOGS_DIR/collect_lsblk.stderr.log" \
        lsblk -J -O || add_warning "Could not collect lsblk output."
    run_recorded_command collect_blkid \
        "$output_dir/blkid.txt" "$LOGS_DIR/collect_blkid.stderr.log" \
        blkid || add_warning "Could not collect blkid output."
    run_recorded_command collect_findmnt \
        "$output_dir/findmnt.txt" "$LOGS_DIR/collect_findmnt.stderr.log" \
        findmnt || add_warning "Could not collect findmnt output."

    for disk in "${TARGET_DISKS[@]}"; do
        disk_name=$(basename -- "$disk")
        safe_name=${disk_name//[^A-Za-z0-9._-]/_}
        run_optional_command "collect_smartctl_$safe_name" \
            "$output_dir/smartctl-$safe_name.txt" "$LOGS_DIR/collect_smartctl-$safe_name.stderr.log" \
            smartctl -x "$disk"
        run_optional_command "collect_parted_$safe_name" \
            "$output_dir/parted-$safe_name.txt" "$LOGS_DIR/collect_parted-$safe_name.stderr.log" \
            parted -s "$disk" unit s print
        run_optional_command "collect_sfdisk_$safe_name" \
            "$output_dir/sfdisk-$safe_name.dump" "$LOGS_DIR/collect_sfdisk-$safe_name.stderr.log" \
            sfdisk -d "$disk"
    done
}

check_source_mounts() {
    local disk=$1
    local mounts

    mounts=$(lsblk --noheadings --raw --paths --output MOUNTPOINTS "$disk" |
        sed '/^[[:space:]]*$/d' || true)
    if [[ -n $mounts ]]; then
        add_warning "Source $disk has mounted filesystems. The image may not be internally consistent."
    fi
}

confirm_targets() {
    local disk
    local answer

    if [[ -n $MAX_READ_GB ]]; then
        printf 'The first %s GB of the following whole disks will be read:\n' "$MAX_READ_GB" >&2
    else
        printf 'The following whole disks will be read in full:\n' >&2
    fi
    for disk in "${TARGET_DISKS[@]}"; do
        lsblk --nodeps --output NAME,SIZE,MODEL,SERIAL "$disk" >&2
    done
    printf 'Images will be written under: %s\n' "$ARCHIVE_DIR" >&2

    if [[ $ASSUME_YES == true ]]; then
        return 0
    fi

    printf 'Type %s to continue: ' "$PC_ID" >&2
    read -r answer
    [[ $answer == "$PC_ID" ]] || die "Confirmation did not match; no imaging was performed."
}

capture_byte_count() {
    local disk=$1
    local disk_bytes
    local sector_bytes
    local capture_bytes
    local limit_applied=false

    disk_bytes=$(blockdev --getsize64 "$disk")
    sector_bytes=$(blockdev --getss "$disk")
    if [[ -n $MAX_READ_BYTES && $MAX_READ_BYTES -lt $disk_bytes ]]; then
        capture_bytes=$MAX_READ_BYTES
        limit_applied=true
    else
        capture_bytes=$disk_bytes
    fi

    capture_bytes=$((capture_bytes / sector_bytes * sector_bytes))
    if ((capture_bytes == 0)); then
        die "The requested read limit is smaller than one logical sector on $disk."
    fi
    if [[ $limit_applied == true && $capture_bytes -ne $MAX_READ_BYTES ]]; then
        log_info "Adjusted the capture range to $capture_bytes bytes to match the $sector_bytes-byte logical sector size of $disk."
    fi

    printf '%s\n' "$capture_bytes"
}

check_free_space() {
    local disk=$1
    local required_bytes=$2
    local available_bytes

    available_bytes=$(df --output=avail --block-size=1 "$ARCHIVE_DIR" | awk 'NR == 2 {print $1}')

    if ((available_bytes < required_bytes)); then
        die "Not enough free space for the raw image of $disk (need $required_bytes bytes; have $available_bytes)."
    fi

    if [[ $COMPRESSION == zstd && $REMOVE_RAW == false && $available_bytes -lt $((required_bytes * 2)) ]]; then
        add_warning "Free space may not be enough to keep both raw and compressed images for $disk."
    fi
}

hash_file() {
    local file=$1
    local directory
    local filename

    directory=$(dirname -- "$file")
    filename=$(basename -- "$file")
    (
        cd -- "$directory"
        sha256sum -- "$filename"
    )
}

verify_hash_file() {
    local checksum_file=$1
    local directory
    local filename

    directory=$(dirname -- "$checksum_file")
    filename=$(basename -- "$checksum_file")
    (
        cd -- "$directory"
        sha256sum --check -- "$filename"
    )
}

disk_field() {
    local disk=$1
    local field=$2

    lsblk --bytes --nodeps --noheadings --output "$field" "$disk" 2>/dev/null |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

append_source_disk_json() {
    local disk=$1
    local image_base=$2
    local final_image=$3
    local raw_hash_file=$4
    local compressed_hash_file=$5
    local map_file=$6
    local raw_present=$7
    local log_suffix=$8
    local capture_bytes=$9
    local buffered_retry_used=${10}
    local capture_mode=full
    local disk_json

    [[ -z $MAX_READ_GB ]] || capture_mode=limited

    disk_json=$(jq --null-input \
        --arg device "$disk" \
        --arg model "$(disk_field "$disk" MODEL)" \
        --arg serial "$(disk_field "$disk" SERIAL)" \
        --argjson size_bytes "$(disk_field "$disk" SIZE)" \
        --arg image "$(basename -- "$final_image")" \
        --arg raw_sha256_file "$(basename -- "$raw_hash_file")" \
        --arg compressed_sha256_file "$compressed_hash_file" \
        --arg ddrescue_mapfile "$(basename -- "$map_file")" \
        --arg image_base "$image_base" \
        --arg log_suffix "$log_suffix" \
        --arg capture_mode "$capture_mode" \
        --arg max_read_gb "$MAX_READ_GB" \
        --arg max_read_bytes "$MAX_READ_BYTES" \
        --argjson rescue_domain_bytes "$capture_bytes" \
        --argjson raw_image_present "$raw_present" \
        --argjson buffered_retry_used "$buffered_retry_used" \
        '{
            device: $device,
            model: $model,
            serial: $serial,
            size_bytes: $size_bytes,
            capture_status: "completed",
            capture: {
                mode: $capture_mode,
                start_byte: 0,
                requested_limit_gb: (if $max_read_gb == "" then null else ($max_read_gb | tonumber) end),
                requested_limit_bytes: (if $max_read_bytes == "" then null else ($max_read_bytes | tonumber) end),
                rescue_domain_bytes: $rescue_domain_bytes
            },
            image: $image,
            raw_image_present: $raw_image_present,
            raw_sha256_file: $raw_sha256_file,
            compressed_sha256_file: (
                if $compressed_sha256_file == "" then null else $compressed_sha256_file end
            ),
            ddrescue_mapfile: $ddrescue_mapfile,
            ddrescue_logs: (
                [
                    ("logs/ddrescue-pass1" + $log_suffix + ".log"),
                    ("logs/ddrescue-pass1" + $log_suffix + ".stderr.log"),
                    ("logs/ddrescue-pass2" + $log_suffix + ".log"),
                    ("logs/ddrescue-pass2" + $log_suffix + ".stderr.log")
                ] + (
                    if $buffered_retry_used then
                        [
                            ("logs/ddrescue-pass2-buffered" + $log_suffix + ".log"),
                            ("logs/ddrescue-pass2-buffered" + $log_suffix + ".stderr.log")
                        ]
                    else
                        []
                    end
                )
            )
        }')

    SOURCE_DISKS_JSON=$(jq --compact-output --argjson disk "$disk_json" '. + [$disk]' \
        <<< "$SOURCE_DISKS_JSON")
}

append_documentation_only_disk_json() {
    local disk=$1
    local disk_json

    disk_json=$(jq --null-input \
        --arg device "$disk" \
        --arg model "$(disk_field "$disk" MODEL)" \
        --arg serial "$(disk_field "$disk" SERIAL)" \
        --argjson size_bytes "$(disk_field "$disk" SIZE)" \
        --arg max_read_gb "$MAX_READ_GB" \
        --arg max_read_bytes "$MAX_READ_BYTES" \
        '{
            device: $device,
            model: $model,
            serial: $serial,
            size_bytes: $size_bytes,
            capture_status: "not_run",
            capture: {
                mode: "documentation_only",
                start_byte: 0,
                requested_limit_gb: (if $max_read_gb == "" then null else ($max_read_gb | tonumber) end),
                requested_limit_bytes: (if $max_read_bytes == "" then null else ($max_read_bytes | tonumber) end),
                rescue_domain_bytes: 0
            },
            image: null,
            raw_image_present: false,
            raw_sha256_file: null,
            compressed_sha256_file: null,
            ddrescue_mapfile: null,
            ddrescue_logs: []
        }')

    SOURCE_DISKS_JSON=$(jq --compact-output --argjson disk "$disk_json" '. + [$disk]' \
        <<< "$SOURCE_DISKS_JSON")
}

archive_one_disk() {
    local disk=$1
    local image_base
    local raw_image
    local compressed_image
    local map_file
    local raw_hash_file
    local compressed_hash_file
    local final_image
    local raw_present=true
    local log_suffix
    local capture_bytes
    local buffered_retry_used=false

    image_base=$(image_base_for_disk "$disk")
    log_suffix=$(log_suffix_for_disk "$image_base")
    raw_image="$ARCHIVE_DIR/$image_base.img"
    compressed_image="$raw_image.zst"
    map_file="$ARCHIVE_DIR/$image_base.ddrescue.map"
    raw_hash_file="$ARCHIVE_DIR/$image_base.img.raw.sha256"
    compressed_hash_file="$ARCHIVE_DIR/$image_base.img.zst.sha256"
    capture_bytes=$(capture_byte_count "$disk")

    if [[ -e $raw_image && ! -e $map_file ]] || [[ ! -e $raw_image && -e $map_file ]]; then
        die "A raw image and ddrescue map must either both exist for resume or both be absent: $image_base"
    fi
    if [[ $COMPRESSION == zstd && -e $compressed_image ]]; then
        die "Refusing to overwrite existing compressed image: $compressed_image"
    fi

    check_source_mounts "$disk"
    check_free_space "$disk" "$capture_bytes"
    log_info "Starting ddrescue first pass for $disk."
    run_recorded_command_live "ddrescue_pass1_$image_base" \
        "$LOGS_DIR/ddrescue-pass1$log_suffix.log" \
        "$LOGS_DIR/ddrescue-pass1$log_suffix.stderr.log" \
        ddrescue --size="$capture_bytes" --no-scrape "$disk" "$raw_image" "$map_file" || \
        die "ddrescue first pass failed for $disk."

    log_info "Starting ddrescue direct-I/O retry pass for $disk."
    if ! run_recorded_command_live "ddrescue_pass2_$image_base" \
        "$LOGS_DIR/ddrescue-pass2$log_suffix.log" \
        "$LOGS_DIR/ddrescue-pass2$log_suffix.stderr.log" \
        ddrescue --size="$capture_bytes" --idirect --retry-passes="$RETRY_COUNT" \
        "$disk" "$raw_image" "$map_file"; then
        buffered_retry_used=true
        add_warning \
            "The direct-I/O ddrescue retry pass failed for $disk; retrying with buffered I/O."
        run_recorded_command_live "ddrescue_pass2_buffered_$image_base" \
            "$LOGS_DIR/ddrescue-pass2-buffered$log_suffix.log" \
            "$LOGS_DIR/ddrescue-pass2-buffered$log_suffix.stderr.log" \
            ddrescue --size="$capture_bytes" --retry-passes="$RETRY_COUNT" \
            "$disk" "$raw_image" "$map_file" || \
            die "Both direct and buffered ddrescue retry passes failed for $disk."
    fi

    run_recorded_command "sha256_raw_$image_base" \
        "$raw_hash_file" "$LOGS_DIR/sha256-raw$log_suffix.stderr.log" \
        hash_file "$raw_image" || die "Could not hash $raw_image."

    final_image=$raw_image
    if [[ $COMPRESSION == zstd ]]; then
        log_info "Compressing $raw_image with zstd."
        PARTIAL_COMPRESSED_IMAGE=$compressed_image
        run_recorded_command_live "zstd_$image_base" \
            "$LOGS_DIR/zstd$log_suffix.log" "$LOGS_DIR/zstd$log_suffix.stderr.log" \
            zstd --threads=0 --verbose --keep -o "$compressed_image" "$raw_image" || \
            die "Compression failed for $raw_image."
        run_recorded_command "sha256_compressed_$image_base" \
            "$compressed_hash_file" "$LOGS_DIR/sha256-compressed$log_suffix.stderr.log" \
            hash_file "$compressed_image" || die "Could not hash $compressed_image."
        run_recorded_command "verify_compressed_$image_base" \
            "$LOGS_DIR/verify-compressed$log_suffix.log" \
            "$LOGS_DIR/verify-compressed$log_suffix.stderr.log" \
            verify_hash_file "$compressed_hash_file" || \
            die "Compressed image verification failed for $compressed_image."
        run_recorded_command "test_zstd_$image_base" \
            "$LOGS_DIR/test-zstd$log_suffix.log" \
            "$LOGS_DIR/test-zstd$log_suffix.stderr.log" \
            zstd --test --no-progress "$compressed_image" || \
            die "The compressed zstd stream is not valid: $compressed_image"
        PARTIAL_COMPRESSED_IMAGE=""
        final_image=$compressed_image

        if [[ $REMOVE_RAW == true ]]; then
            run_recorded_command "remove_raw_$image_base" \
                "$LOGS_DIR/remove-raw$log_suffix.log" \
                "$LOGS_DIR/remove-raw$log_suffix.stderr.log" \
                rm -- "$raw_image" || die "Could not remove raw image: $raw_image"
            raw_present=false
            log_info "Removed verified raw image: $raw_image"
        fi
    else
        compressed_hash_file=""
    fi

    append_source_disk_json \
        "$disk" "$image_base" "$final_image" "$raw_hash_file" \
        "$(basename -- "$compressed_hash_file")" "$map_file" "$raw_present" "$log_suffix" \
        "$capture_bytes" "$buffered_retry_used"
}

write_archive_summary() {
    local completed_at=$1
    local completed_epoch=$2
    local warnings_json
    local summary_file="$ARCHIVE_DIR/$PC_ID.archive.json"
    local run_mode=full_capture

    if [[ $DOCUMENTATION_ONLY == true ]]; then
        run_mode=documentation_only
    elif [[ -n $MAX_READ_GB ]]; then
        run_mode=limited_capture
    fi

    warnings_json=$(jq --null-input '$ARGS.positional' --args "${WARNINGS[@]}")
    jq --null-input \
        --arg schema_version "1.0" \
        --arg script_name "archive-disk.sh" \
        --arg script_version "$SCRIPT_VERSION" \
        --arg pc_id "$PC_ID" \
        --arg started_at "$STARTED_AT" \
        --arg completed_at "$completed_at" \
        --arg timezone "$RECORD_TIMEZONE" \
        --arg run_mode "$run_mode" \
        --arg max_read_gb "$MAX_READ_GB" \
        --arg max_read_bytes "$MAX_READ_BYTES" \
        --argjson duration "$(duration_seconds "$STARTED_EPOCH" "$completed_epoch")" \
        --argjson source_disks "$SOURCE_DISKS_JSON" \
        --argjson warnings "$warnings_json" \
        '{
            schema_version: $schema_version,
            script: {name: $script_name, version: $script_version},
            pc_id: $pc_id,
            started_at: $started_at,
            completed_at: $completed_at,
            timezone: $timezone,
            duration_seconds: $duration,
            run: {
                mode: $run_mode,
                requested_limit_gb: (if $max_read_gb == "" then null else ($max_read_gb | tonumber) end),
                requested_limit_bytes: (if $max_read_bytes == "" then null else ($max_read_bytes | tonumber) end)
            },
            livecd: {
                os_release_file: "livecd/os-release.txt",
                uname_file: "livecd/uname.txt",
                tool_versions_file: "livecd/tool-versions.txt"
            },
            source_disks: $source_disks,
            warnings: $warnings
        }' > "$summary_file"

    jq empty "$summary_file"
}

write_archive_readmes() {
    local completed_at=$1
    local completed_epoch=$2
    local readme="$ARCHIVE_DIR/README.md"
    local top_readme="$OUTPUT_ROOT/README.md"
    local managed_block
    local disk
    local disk_rows=""
    local warning_lines="None."
    local source_disks_text
    local summary_text
    local image_text
    local ddrescue_text
    local hash_text
    local capture_mode_text

    for disk in "${TARGET_DISKS[@]}"; do
        disk_rows+="| \`$disk\` | $(disk_field "$disk" SIZE) | $(disk_field "$disk" MODEL) | $(disk_field "$disk" SERIAL) |"$'\n'
    done
    if ((${#WARNINGS[@]} > 0)); then
        warning_lines=""
        for disk in "${WARNINGS[@]}"; do
            warning_lines+="- $disk"$'\n'
        done
    fi
    source_disks_text=$(printf '%s, ' "${TARGET_DISKS[@]}")
    source_disks_text=${source_disks_text%, }

    if [[ $DOCUMENTATION_ONLY == true ]]; then
        capture_mode_text="Documentation only; no disk image was created"
        summary_text="This directory contains system inventory and documentation from a documentation-only run. No disk sectors were copied, and ddrescue, hashing, and compression were not run."
        image_text="No image files were created. See [$PC_ID.archive.json]($PC_ID.archive.json) for the selected source disks and requested settings."
        ddrescue_text="ddrescue was intentionally not run in documentation-only mode."
        hash_text="No image hashes were created because no disk image was captured."
    else
        if [[ -n $MAX_READ_GB ]]; then
            capture_mode_text="Limited capture of the first $MAX_READ_GB GB ($MAX_READ_BYTES bytes maximum)"
            summary_text="This directory contains limited disk images and records from the archive run. Only the first $MAX_READ_GB decimal GB of each source disk was requested. The source disks were not mounted by this script."
        else
            capture_mode_text="Full-disk capture"
            summary_text="This directory contains whole-disk images and records from the archive run. The source disks were read by GNU ddrescue and were not mounted by this script."
        fi
        image_text="See [$PC_ID.archive.json]($PC_ID.archive.json) for the exact image, map, hash, capture range, and log paths for each source disk."
        ddrescue_text="The ddrescue map files support resuming an interrupted read. Command output and errors are under [logs/](logs/)."
        hash_text="SHA256 files are next to their corresponding images. Raw-image hashes remain available if a raw image is removed after verified compression."
    fi

    cat > "$readme" <<EOF
# $PC_ID Archive

## Summary

$summary_text

## Image Files

$image_text

## Source Disk

| Device | Size (bytes) | Model | Serial |
|---|---:|---|---|
$disk_rows
## Archive Runtime

- Started ($RECORD_TIMEZONE): $STARTED_AT
- Completed ($RECORD_TIMEZONE): $completed_at
- Duration: $(duration_seconds "$STARTED_EPOCH" "$completed_epoch") seconds
- Script version: $SCRIPT_VERSION
- Capture mode: $capture_mode_text

## LiveCD OS Information

See [livecd/](livecd/) for the live environment and tool versions.

## Archive Machine Hardware Profile

See [hardware/](hardware/) for the machine profile collected during the run.

## Disk Inventory

See [disks/](disks/) for block-device, partition-table, and SMART information.

## ddrescue Summary

$ddrescue_text

## Hashes

$hash_text

## Logs and Supporting Files

- [commands.jsonl](commands.jsonl) records command timing and exit status.
- [$PC_ID.archive.json]($PC_ID.archive.json) is the structured run summary.
- [logs/](logs/) contains the main log and per-command output.

## Warnings

$warning_lines
EOF

    ensure_managed_readme "$top_readme" "$PC_ID"
    managed_block=$(mktemp "$OUTPUT_ROOT/.archive-readme-block.XXXXXX")
    cat > "$managed_block" <<EOF
## Archive Summary

- Archive completed ($RECORD_TIMEZONE): $completed_at
- Script version: $SCRIPT_VERSION
- Source disks: $source_disks_text
- Capture mode: $capture_mode_text
- Archive details: [ARCHIVE/README.md](ARCHIVE/README.md)
EOF
    update_readme_block "$top_readme" "archive-disk.sh" "$managed_block"
    rm -- "$managed_block"
}

validate_runtime() {
    require_tool jq jq
    require_tool lsblk util-linux
    require_tool findmnt util-linux
    if [[ $DOCUMENTATION_ONLY == true ]]; then
        return 0
    fi

    require_root
    require_tool blockdev util-linux
    require_tool ddrescue gddrescue
    require_tool sha256sum coreutils
    require_tool tee coreutils
    if [[ $COMPRESSION == zstd ]]; then
        require_tool zstd zstd
    fi
}

main() {
    local disk
    local completed_at
    local completed_epoch

    parse_arguments "$@"
    prompt_for_missing_arguments
    validate_arguments
    select_target_disks

    if [[ $DRY_RUN == true ]]; then
        show_dry_run
        exit 0
    fi

    validate_runtime
    prepare_output_tree
    register_cleanup_handler cleanup_archive
    install_cleanup_trap
    STARTED_AT=$(record_time_now)
    STARTED_EPOCH=$(date +%s)
    log_info "Archive run started for $PC_ID."

    collect_livecd_information
    collect_hardware_information
    collect_disk_information
    if [[ $DOCUMENTATION_ONLY == true ]]; then
        log_info "Documentation-only mode selected; disk imaging is being skipped."
        for disk in "${TARGET_DISKS[@]}"; do
            append_documentation_only_disk_json "$disk"
        done
    else
        confirm_targets
        for disk in "${TARGET_DISKS[@]}"; do
            archive_one_disk "$disk"
        done
    fi

    completed_at=$(record_time_now)
    completed_epoch=$(date +%s)
    write_archive_summary "$completed_at" "$completed_epoch"
    write_archive_readmes "$completed_at" "$completed_epoch"
    log_info "Archive run completed. Details: $ARCHIVE_DIR/README.md"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
