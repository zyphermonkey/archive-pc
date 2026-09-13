#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

PC_ID=""
OUTPUT_ROOT=""
TARGET_DISK=""
ALL_INTERNAL_DISKS=false
COMPRESSION="zstd"
REMOVE_RAW=false
RETRY_COUNT=3
ASSUME_YES=false

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
  archive-disk.sh --pc-id ID --output PATH --target DEVICE [options]
  archive-disk.sh --pc-id ID --output PATH --all-internal-disks [options]

Required:
  --pc-id ID                      Short identifier, for example PC-001
  --output PATH                   Root directory for this PC archive
  --target DEVICE                 Whole source disk to archive
  --all-internal-disks            Archive every non-removable internal disk

Options:
  --compress none|zstd            Compression format (default: zstd)
  --keep-raw                      Keep raw images after compression (default)
  --remove-raw-after-compress     Delete raw images after verified compression
  --retry-count N                 ddrescue retry passes (default: 3)
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
                OUTPUT_ROOT=$2
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
    [[ -n $PC_ID ]] || die "--pc-id is required."
    [[ $PC_ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
        die "--pc-id may contain only letters, numbers, dots, underscores, and hyphens."
    [[ -n $OUTPUT_ROOT ]] || die "--output is required."
    [[ $OUTPUT_ROOT != / ]] || die "The filesystem root cannot be used as --output."
    [[ $COMPRESSION == none || $COMPRESSION == zstd ]] || \
        die "--compress must be 'none' or 'zstd'."
    [[ $RETRY_COUNT =~ ^[0-9]+$ ]] || die "--retry-count must be a non-negative integer."

    if [[ -n $TARGET_DISK && $ALL_INTERNAL_DISKS == true ]]; then
        die "Use either --target or --all-internal-disks, not both."
    fi
    if [[ -z $TARGET_DISK && $ALL_INTERNAL_DISKS == false ]]; then
        die "Either --target or --all-internal-disks is required."
    fi
    if [[ $REMOVE_RAW == true && $COMPRESSION == none ]]; then
        die "--remove-raw-after-compress requires --compress zstd."
    fi

    OUTPUT_ROOT=$(realpath --canonicalize-missing -- "$OUTPUT_ROOT")
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

image_base_for_disk() {
    local disk=$1

    if ((${#TARGET_DISKS[@]} == 1)); then
        printf '%s\n' "$PC_ID"
    else
        printf '%s-%s\n' "$PC_ID" "$(basename -- "$disk")"
    fi
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
    printf '  Output root: %s\n' "$OUTPUT_ROOT"
    printf '  Compression: %s\n' "$COMPRESSION"
    printf '  Remove raw after verified compression: %s\n' "$REMOVE_RAW"
    printf '  Retry count: %s\n' "$RETRY_COUNT"
    printf '  Directories that would be created:\n'
    printf '    %s\n' \
        "$OUTPUT_ROOT/ARCHIVE/logs" \
        "$OUTPUT_ROOT/ARCHIVE/livecd" \
        "$OUTPUT_ROOT/ARCHIVE/hardware" \
        "$OUTPUT_ROOT/ARCHIVE/disks"

    for disk in "${TARGET_DISKS[@]}"; do
        image_base=$(image_base_for_disk "$disk")
        printf '  Source disk: %s\n' "$disk"
        printf '    ddrescue image: %s/ARCHIVE/%s.img\n' "$OUTPUT_ROOT" "$image_base"
        printf '    ddrescue map: %s/ARCHIVE/%s.ddrescue.map\n' "$OUTPUT_ROOT" "$image_base"
        printf '    raw hash: %s/ARCHIVE/%s.img.raw.sha256\n' "$OUTPUT_ROOT" "$image_base"
        if [[ $COMPRESSION == zstd ]]; then
            printf '    compressed image: %s/ARCHIVE/%s.img.zst\n' "$OUTPUT_ROOT" "$image_base"
            printf '    compressed hash: %s/ARCHIVE/%s.img.zst.sha256\n' "$OUTPUT_ROOT" "$image_base"
        fi
    done

    printf '  Commands would include: inventory collection, two ddrescue passes, SHA256 hashing'
    if [[ $COMPRESSION == zstd ]]; then
        printf ', zstd compression, and compressed-image verification'
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

    printf 'The following whole disks will be read in full:\n' >&2
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

check_free_space() {
    local disk=$1
    local required_bytes
    local available_bytes

    required_bytes=$(blockdev --getsize64 "$disk")
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
    local disk_json

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
        --argjson raw_image_present "$raw_present" \
        '{
            device: $device,
            model: $model,
            serial: $serial,
            size_bytes: $size_bytes,
            image: $image,
            raw_image_present: $raw_image_present,
            raw_sha256_file: $raw_sha256_file,
            compressed_sha256_file: (
                if $compressed_sha256_file == "" then null else $compressed_sha256_file end
            ),
            ddrescue_mapfile: $ddrescue_mapfile,
            ddrescue_logs: [
                ("logs/ddrescue-pass1" + $log_suffix + ".log"),
                ("logs/ddrescue-pass2" + $log_suffix + ".log")
            ]
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

    image_base=$(image_base_for_disk "$disk")
    log_suffix=$(log_suffix_for_disk "$image_base")
    raw_image="$ARCHIVE_DIR/$image_base.img"
    compressed_image="$raw_image.zst"
    map_file="$ARCHIVE_DIR/$image_base.ddrescue.map"
    raw_hash_file="$ARCHIVE_DIR/$image_base.img.raw.sha256"
    compressed_hash_file="$ARCHIVE_DIR/$image_base.img.zst.sha256"

    if [[ -e $raw_image && ! -e $map_file ]] || [[ ! -e $raw_image && -e $map_file ]]; then
        die "A raw image and ddrescue map must either both exist for resume or both be absent: $image_base"
    fi
    if [[ $COMPRESSION == zstd && -e $compressed_image ]]; then
        die "Refusing to overwrite existing compressed image: $compressed_image"
    fi

    check_source_mounts "$disk"
    check_free_space "$disk"
    log_info "Starting ddrescue first pass for $disk."
    run_recorded_command "ddrescue_pass1_$image_base" \
        "$LOGS_DIR/ddrescue-pass1$log_suffix.log" \
        "$LOGS_DIR/ddrescue-pass1$log_suffix.stderr.log" \
        ddrescue --no-scrape "$disk" "$raw_image" "$map_file" || \
        die "ddrescue first pass failed for $disk."

    log_info "Starting ddrescue retry pass for $disk."
    run_recorded_command "ddrescue_pass2_$image_base" \
        "$LOGS_DIR/ddrescue-pass2$log_suffix.log" \
        "$LOGS_DIR/ddrescue-pass2$log_suffix.stderr.log" \
        ddrescue --direct --retry-passes="$RETRY_COUNT" "$disk" "$raw_image" "$map_file" || \
        die "ddrescue retry pass failed for $disk."

    run_recorded_command "sha256_raw_$image_base" \
        "$raw_hash_file" "$LOGS_DIR/sha256-raw$log_suffix.stderr.log" \
        hash_file "$raw_image" || die "Could not hash $raw_image."

    final_image=$raw_image
    if [[ $COMPRESSION == zstd ]]; then
        log_info "Compressing $raw_image with zstd."
        PARTIAL_COMPRESSED_IMAGE=$compressed_image
        run_recorded_command "zstd_$image_base" \
            "$LOGS_DIR/zstd$log_suffix.log" "$LOGS_DIR/zstd$log_suffix.stderr.log" \
            zstd --threads=0 --verbose --keep --output="$compressed_image" "$raw_image" || \
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
        "$(basename -- "$compressed_hash_file")" "$map_file" "$raw_present" "$log_suffix"
}

write_archive_summary() {
    local completed_at=$1
    local completed_epoch=$2
    local warnings_json
    local summary_file="$ARCHIVE_DIR/$PC_ID.archive.json"

    warnings_json=$(jq --null-input '$ARGS.positional' --args "${WARNINGS[@]}")
    jq --null-input \
        --arg schema_version "1.0" \
        --arg script_name "archive-disk.sh" \
        --arg script_version "$SCRIPT_VERSION" \
        --arg pc_id "$PC_ID" \
        --arg started_at "$STARTED_AT" \
        --arg completed_at "$completed_at" \
        --arg timezone "$RECORD_TIMEZONE" \
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

    cat > "$readme" <<EOF
# $PC_ID Archive

## Summary

This directory contains whole-disk images and records from the archive run. The source disks were read by GNU ddrescue and were not mounted by this script.

## Image Files

See [$PC_ID.archive.json]($PC_ID.archive.json) for the exact image, map, hash, and log paths for each source disk.

## Source Disk

| Device | Size (bytes) | Model | Serial |
|---|---:|---|---|
$disk_rows
## Archive Runtime

- Started ($RECORD_TIMEZONE): $STARTED_AT
- Completed ($RECORD_TIMEZONE): $completed_at
- Duration: $(duration_seconds "$STARTED_EPOCH" "$completed_epoch") seconds
- Script version: $SCRIPT_VERSION

## LiveCD OS Information

See [livecd/](livecd/) for the live environment and tool versions.

## Archive Machine Hardware Profile

See [hardware/](hardware/) for the machine profile collected during the run.

## Disk Inventory

See [disks/](disks/) for block-device, partition-table, and SMART information.

## ddrescue Summary

The ddrescue map files support resuming an interrupted read. Command output and errors are under [logs/](logs/).

## Hashes

SHA256 files are next to their corresponding images. Raw-image hashes remain available if a raw image is removed after verified compression.

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
- Archive details: [ARCHIVE/README.md](ARCHIVE/README.md)
EOF
    update_readme_block "$top_readme" "archive-disk.sh" "$managed_block"
    rm -- "$managed_block"
}

validate_runtime() {
    require_root
    require_tool jq jq
    require_tool lsblk util-linux
    require_tool findmnt util-linux
    require_tool blockdev util-linux
    require_tool ddrescue gddrescue
    require_tool sha256sum coreutils
    if [[ $COMPRESSION == zstd ]]; then
        require_tool zstd zstd
    fi
}

main() {
    local disk
    local completed_at
    local completed_epoch

    parse_arguments "$@"
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
    confirm_targets

    for disk in "${TARGET_DISKS[@]}"; do
        archive_one_disk "$disk"
    done

    completed_at=$(record_time_now)
    completed_epoch=$(date +%s)
    write_archive_summary "$completed_at" "$completed_epoch"
    write_archive_readmes "$completed_at" "$completed_epoch"
    log_info "Archive run completed. Details: $ARCHIVE_DIR/README.md"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
