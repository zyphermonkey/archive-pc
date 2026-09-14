#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

PC_ID=""
ARCHIVE_ROOT=""
IMAGE_PATH=""
WORK_DIR=""
SESSION_DIR=""
KEEP_WORK_IMAGE=false
REDACT_SECRETS=true
EXTRACT_WINDOWS=true
EXTRACT_LINUX=true

METADATA_DIR=""
LOGS_DIR=""
MOUNT_DATA_DIR=""
ACTIVE_IMAGE=""
ACTIVE_MOUNT=""
ACTIVE_MOUNT_PID=""
ACTIVE_MOUNT_PID_FILE=""
GUESTMOUNT_EXIT_TIMEOUT_SECONDS=60
GUESTMOUNT_WAIT_TIMED_OUT=false
TEMPORARY_IMAGE=""
STARTED_AT=""
STARTED_EPOCH=0
DETECTED_JSON='[]'
WINDOWS_EXTRACTED=false
LINUX_EXTRACTED=false
WINDOWS_USER_COUNT=0
WINDOWS_APPLICATION_COUNT=0
LINUX_USER_COUNT=0
LINUX_PACKAGE_COUNT=0
declare -a WARNINGS=()

usage() {
    cat <<'EOF'
Usage:
  extract-metadata.sh --pc-id ID --root PATH --image IMAGE [options]

Required:
  --pc-id ID                  Short identifier, for example PC-001
  --root PATH                 Root directory for this PC archive
  --image PATH                Existing .img or .img.zst disk image

Options:
  --work-dir PATH             Temporary work directory (default: METADATA/work)
  --keep-work-image           Keep a decompressed temporary image
  --windows                   Extract Windows metadata only
  --linux                     Extract Linux metadata only
  --all                       Extract both Windows and Linux metadata (default)
  --redact-secrets            Redact network secrets (default)
  --no-redact-secrets         Preserve network configuration values
  --dry-run                   Describe actions without writing or mounting
  --debug                     Enable debug logging
  --help                      Show this help
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
            --root)
                (($# >= 2)) || die "--root requires a value."
                ARCHIVE_ROOT=$2
                shift 2
                ;;
            --image)
                (($# >= 2)) || die "--image requires a value."
                IMAGE_PATH=$2
                shift 2
                ;;
            --work-dir)
                (($# >= 2)) || die "--work-dir requires a value."
                WORK_DIR=$2
                shift 2
                ;;
            --keep-work-image)
                KEEP_WORK_IMAGE=true
                shift
                ;;
            --windows)
                EXTRACT_WINDOWS=true
                EXTRACT_LINUX=false
                shift
                ;;
            --linux)
                EXTRACT_WINDOWS=false
                EXTRACT_LINUX=true
                shift
                ;;
            --all)
                EXTRACT_WINDOWS=true
                EXTRACT_LINUX=true
                shift
                ;;
            --redact-secrets)
                REDACT_SECRETS=true
                shift
                ;;
            --no-redact-secrets)
                REDACT_SECRETS=false
                shift
                ;;
            --dry-run)
                DRY_RUN=true
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
    [[ -n $ARCHIVE_ROOT ]] || die "--root is required."
    [[ $ARCHIVE_ROOT != / ]] || die "The filesystem root cannot be used as --root."
    [[ -n $IMAGE_PATH ]] || die "--image is required."
    [[ $IMAGE_PATH == *.img || $IMAGE_PATH == *.img.zst ]] || \
        die "--image must end in .img or .img.zst."
    [[ -f $IMAGE_PATH ]] || die "Image does not exist or is not a regular file: $IMAGE_PATH"

    ARCHIVE_ROOT=$(realpath --canonicalize-missing -- "$ARCHIVE_ROOT")
    IMAGE_PATH=$(realpath --canonicalize-existing -- "$IMAGE_PATH")
    if [[ -z $WORK_DIR ]]; then
        WORK_DIR="$ARCHIVE_ROOT/METADATA/work"
    else
        WORK_DIR=$(realpath --canonicalize-missing -- "$WORK_DIR")
    fi
}

show_dry_run() {
    printf 'Dry-run metadata extraction plan\n'
    printf '  PC ID: %s\n' "$PC_ID"
    printf '  Archive root: %s\n' "$ARCHIVE_ROOT"
    printf '  Input image: %s\n' "$IMAGE_PATH"
    printf '  Work directory: %s\n' "$WORK_DIR"
    printf '  Extract Windows metadata: %s\n' "$EXTRACT_WINDOWS"
    printf '  Extract Linux metadata: %s\n' "$EXTRACT_LINUX"
    printf '  Redact network secrets: %s\n' "$REDACT_SECRETS"
    printf '  Directories that would be created:\n'
    printf '    %s\n' \
        "$ARCHIVE_ROOT/METADATA/logs" \
        "$ARCHIVE_ROOT/METADATA/mount" \
        "$ARCHIVE_ROOT/METADATA/windows/raw/registry-exports" \
        "$ARCHIVE_ROOT/METADATA/windows/raw/eventlog-summaries" \
        "$ARCHIVE_ROOT/METADATA/linux/raw" \
        "$WORK_DIR"
    if [[ $IMAGE_PATH == *.img.zst && ! -f ${IMAGE_PATH%.zst} ]]; then
        printf '  Would check free space and decompress to: %s/%s\n' \
            "$WORK_DIR" "$(basename -- "${IMAGE_PATH%.zst}")"
    elif [[ $IMAGE_PATH == *.img.zst ]]; then
        printf '  Would prefer existing raw image: %s\n' "${IMAGE_PATH%.zst}"
    fi
    printf '  Commands would include: guestfish filesystem inspection and read-only guestmount mounts.\n'
    printf '  No image, filesystem, or output file would be modified in this dry run.\n'
}

validate_runtime() {
    require_root
    require_tool jq jq
    require_tool guestfish libguestfs-tools
    require_tool guestmount libguestfs-tools
    require_tool guestunmount libguestfs-tools
    require_tool mountpoint util-linux
    if [[ $IMAGE_PATH == *.img.zst && ! -f ${IMAGE_PATH%.zst} ]]; then
        require_tool zstd zstd
    fi
}

prepare_output_tree() {
    METADATA_DIR="$ARCHIVE_ROOT/METADATA"
    LOGS_DIR="$METADATA_DIR/logs"
    MOUNT_DATA_DIR="$METADATA_DIR/mount"

    safe_mkdir "$LOGS_DIR"
    safe_mkdir "$MOUNT_DATA_DIR"
    safe_mkdir "$METADATA_DIR/windows/raw/registry-exports"
    safe_mkdir "$METADATA_DIR/windows/raw/eventlog-summaries"
    safe_mkdir "$METADATA_DIR/linux/raw"
    safe_mkdir "$WORK_DIR"
    SESSION_DIR=$(mktemp --directory "$WORK_DIR/session.XXXXXX")

    LOG_FILE="$LOGS_DIR/extract-metadata.log"
    COMMANDS_JSONL="$METADATA_DIR/commands.jsonl"
    RECORD_ROOT="$METADATA_DIR"
    touch -- "$LOG_FILE" "$COMMANDS_JSONL" "$MOUNT_DATA_DIR/mount-report.txt"

    cat > "$METADATA_DIR/windows/raw/README.md" <<'EOF'
# Windows raw working data

Registry exports used during extraction are kept in the temporary work directory and removed during cleanup. Credential material and password hashes are never exported.
EOF
    cat > "$METADATA_DIR/linux/raw/README.md" <<'EOF'
# Linux raw working data

The structured files in the parent directory are derived from read-only access to the archived filesystem. `/etc/shadow` is never read or copied.
EOF
}

read_guestmount_pid() {
    local pid_file=$1
    local guestmount_pid

    guestmount_pid=$(cat -- "$pid_file" 2>/dev/null || true)
    [[ $guestmount_pid =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$guestmount_pid"
}

wait_for_guestmount_exit() {
    local guestmount_pid=$1
    local remaining=$GUESTMOUNT_EXIT_TIMEOUT_SECONDS

    [[ $guestmount_pid =~ ^[0-9]+$ ]] || return 1

    if kill -0 "$guestmount_pid" 2>/dev/null; then
        log_info \
            "Waiting for guestmount process $guestmount_pid to finish cleanup" \
            "(up to $GUESTMOUNT_EXIT_TIMEOUT_SECONDS seconds)."
    fi

    while kill -0 "$guestmount_pid" 2>/dev/null && ((remaining > 0)); do
        sleep 1
        ((remaining--))
    done

    if kill -0 "$guestmount_pid" 2>/dev/null; then
        log_warn \
            "guestmount process $guestmount_pid did not exit within" \
            "$GUESTMOUNT_EXIT_TIMEOUT_SECONDS seconds."
        GUESTMOUNT_WAIT_TIMED_OUT=true
        return 1
    fi
}

cleanup_metadata() {
    local cleanup_status=0
    local mount_was_active=false

    if [[ -z $ACTIVE_MOUNT_PID && -n $ACTIVE_MOUNT_PID_FILE ]]; then
        ACTIVE_MOUNT_PID=$(read_guestmount_pid "$ACTIVE_MOUNT_PID_FILE" || true)
    fi

    if [[ $GUESTMOUNT_WAIT_TIMED_OUT == true ]]; then
        log_error "Leaving work files in place because guestmount may still be using the image."
        return 1
    fi

    if [[ -n $ACTIVE_MOUNT && -d $ACTIVE_MOUNT ]] && mountpoint --quiet "$ACTIVE_MOUNT"; then
        mount_was_active=true
        if command -v guestunmount >/dev/null 2>&1; then
            guestunmount "$ACTIVE_MOUNT" >/dev/null 2>&1 || cleanup_status=1
        else
            cleanup_status=1
        fi
    fi

    if [[ -n $ACTIVE_MOUNT_PID ]]; then
        if ! wait_for_guestmount_exit "$ACTIVE_MOUNT_PID"; then
            log_error "Leaving work files in place because guestmount may still be using the image."
            return 1
        fi
    elif [[ $mount_was_active == true ]]; then
        log_error \
            "Leaving work files in place because the guestmount worker PID was unavailable."
        return 1
    fi

    if [[ -n $ACTIVE_MOUNT_PID_FILE ]]; then
        rm -f -- "$ACTIVE_MOUNT_PID_FILE"
    fi

    if [[ -n $ACTIVE_MOUNT && -d $ACTIVE_MOUNT ]] && mountpoint --quiet "$ACTIVE_MOUNT"; then
        log_error "Leaving work files in place because the read-only guest mount is still active: $ACTIVE_MOUNT"
        return 1
    fi

    if [[ -n $ACTIVE_MOUNT && -d $ACTIVE_MOUNT ]]; then
        rmdir -- "$ACTIVE_MOUNT" 2>/dev/null || true
    fi

    if [[ -n $SESSION_DIR && -d $SESSION_DIR && $SESSION_DIR == "$WORK_DIR"/session.* ]]; then
        rm -rf -- "$SESSION_DIR" || cleanup_status=1
    fi

    if [[ -n $TEMPORARY_IMAGE && $KEEP_WORK_IMAGE == false && -f $TEMPORARY_IMAGE ]]; then
        rm -- "$TEMPORARY_IMAGE" || cleanup_status=1
        if ((cleanup_status == 0)); then
            log_info "Removed temporary decompressed image: $TEMPORARY_IMAGE"
        fi
    fi

    return "$cleanup_status"
}

zstd_content_size() {
    local image=$1
    local listing
    local size

    listing=$(zstd --list --verbose -- "$image" 2>/dev/null) || return 1
    size=$(sed -nE 's/.*Decompressed Size:[[:space:]]*([0-9]+).*/\1/p' <<< "$listing" |
        tail -n 1)
    if [[ -z $size ]]; then
        size=$(sed -nE 's/.*\(([0-9]+) B\).*/\1/p' <<< "$listing" | tail -n 1)
    fi

    [[ $size =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$size"
}

prepare_active_image() {
    local existing_raw
    local required_bytes
    local available_bytes
    local image_name

    ACTIVE_IMAGE=$IMAGE_PATH
    if [[ $IMAGE_PATH != *.img.zst ]]; then
        return 0
    fi

    existing_raw=${IMAGE_PATH%.zst}
    if [[ -f $existing_raw ]]; then
        ACTIVE_IMAGE=$existing_raw
        log_info "Using existing raw image instead of decompressing: $ACTIVE_IMAGE"
        return 0
    fi

    required_bytes=$(zstd_content_size "$IMAGE_PATH") || \
        die "Could not determine the decompressed image size; refusing to decompress without a free-space check."
    available_bytes=$(df --output=avail --block-size=1 "$WORK_DIR" | awk 'NR == 2 {print $1}')
    if ((available_bytes < required_bytes)); then
        die "Not enough work-directory space (need $required_bytes bytes; have $available_bytes)."
    fi

    image_name=$(basename -- "${IMAGE_PATH%.zst}")
    TEMPORARY_IMAGE="$WORK_DIR/$image_name"
    [[ ! -e $TEMPORARY_IMAGE ]] || \
        die "Refusing to overwrite an existing work image: $TEMPORARY_IMAGE"

    log_info "Decompressing image to temporary work space."
    run_recorded_command decompress_image \
        "$LOGS_DIR/zstd-decompress.log" "$LOGS_DIR/zstd-decompress.stderr.log" \
        zstd --decompress --keep --no-progress --output="$TEMPORARY_IMAGE" "$IMAGE_PATH" || \
        die "Could not decompress $IMAGE_PATH."
    ACTIVE_IMAGE=$TEMPORARY_IMAGE
}

collect_image_information() {
    run_optional_command collect_qemu_image_info \
        "$MOUNT_DATA_DIR/image-info.txt" "$LOGS_DIR/qemu-img.stderr.log" \
        qemu-img info --force-share -f raw "$ACTIVE_IMAGE"
    run_optional_command collect_virt_filesystems \
        "$MOUNT_DATA_DIR/virt-filesystems.txt" "$LOGS_DIR/virt-filesystems.stderr.log" \
        virt-filesystems --format=raw --all --long --human-readable --add "$ACTIVE_IMAGE"
    run_recorded_command list_filesystems \
        "$MOUNT_DATA_DIR/filesystems.txt" "$LOGS_DIR/guestfish-list-filesystems.stderr.log" \
        guestfish --ro --format=raw --add "$ACTIVE_IMAGE" run : list-filesystems || \
        die "libguestfs could not inspect filesystems in $ACTIVE_IMAGE."
}

trim_whitespace() {
    local value=$1

    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    printf '%s\n' "$value"
}

safe_existing_guest_path() {
    local root=$1
    local relative_path=${2#/}
    local resolved_root
    local resolved_path

    resolved_root=$(realpath --canonicalize-existing -- "$root") || return 1
    resolved_path=$(realpath --canonicalize-existing -- "$root/$relative_path" 2>/dev/null) || return 1

    if [[ $resolved_path != "$resolved_root" && $resolved_path != "$resolved_root"/* ]]; then
        log_warn "Skipped guest path that resolves outside its mounted filesystem: /$relative_path"
        return 1
    fi

    printf '%s\n' "$resolved_path"
}

write_partitions_json() {
    local device
    local filesystem
    local partitions='[]'
    local partition

    while IFS=: read -r device filesystem; do
        device=$(trim_whitespace "$device")
        filesystem=$(trim_whitespace "$filesystem")
        [[ -n $device ]] || continue
        partition=$(jq --null-input --arg device "$device" --arg filesystem "$filesystem" \
            '{device: $device, filesystem: $filesystem}')
        partitions=$(jq --compact-output --argjson partition "$partition" '. + [$partition]' \
            <<< "$partitions")
    done < "$MOUNT_DATA_DIR/filesystems.txt"

    jq --null-input --arg image "$(realpath --relative-to "$ARCHIVE_ROOT" "$IMAGE_PATH")" \
        --arg active_image "$ACTIVE_IMAGE" --argjson filesystems "$partitions" \
        '{image: $image, active_image: $active_image, filesystems: $filesystems}' \
        > "$MOUNT_DATA_DIR/partitions.json"
}

resolve_case_insensitive_path() {
    local root=$1
    local relative_path=$2
    local current=$root
    local component
    local match
    local -a components=()

    IFS='/' read -r -a components <<< "$relative_path"
    for component in "${components[@]}"; do
        [[ -n $component ]] || continue
        match=$(find "$current" -mindepth 1 -maxdepth 1 -iname "$component" -print -quit 2>/dev/null || true)
        [[ -n $match ]] || return 1
        current=$(safe_existing_guest_path "$root" "${match#"$root"/}") || return 1
    done

    printf '%s\n' "$current"
}

windows_evidence() {
    local root=$1
    local evidence_file=$2
    local path

    : > "$evidence_file"
    for path in \
        'Windows/System32/config/SOFTWARE' \
        'Windows/System32/config/SYSTEM' \
        'Windows/System32/config/SAM' \
        'Users' \
        'Program Files' \
        'Program Files (x86)'; do
        if resolve_case_insensitive_path "$root" "$path" >/dev/null; then
            printf '%s\n' "$path" >> "$evidence_file"
        fi
    done
}

linux_evidence() {
    local root=$1
    local evidence_file=$2
    local path

    : > "$evidence_file"
    for path in \
        etc/os-release \
        usr/lib/os-release \
        etc/passwd \
        etc/group \
        etc/fstab \
        var/lib/dpkg/status \
        var/lib/rpm \
        var/lib/pacman/local \
        lib/apk/db/installed; do
        if safe_existing_guest_path "$root" "$path" >/dev/null; then
            printf '%s\n' "$path" >> "$evidence_file"
        fi
    done
}

append_detection() {
    local os_type=$1
    local confidence=$2
    local device=$3
    local evidence_file=$4
    local evidence_json
    local detection

    evidence_json=$(jq --raw-input --slurp 'split("\n") | map(select(length > 0))' "$evidence_file")
    detection=$(jq --null-input \
        --arg type "$os_type" \
        --arg confidence "$confidence" \
        --arg root_partition "$device" \
        --argjson evidence "$evidence_json" \
        '{type: $type, confidence: $confidence, root_partition: $root_partition, evidence: $evidence}')
    DETECTED_JSON=$(jq --compact-output --argjson detection "$detection" '. + [$detection]' \
        <<< "$DETECTED_JSON")
}

os_release_json() {
    local os_release_file=$1

    if [[ ! -f $os_release_file ]]; then
        printf '{}\n'
        return 0
    fi

    jq --rawfile data "$os_release_file" --null-input '
        reduce (
            $data
            | split("\n")[]
            | select(test("^[A-Za-z_][A-Za-z0-9_]*="))
            | capture("^(?<key>[^=]+)=(?<value>.*)$")
        ) as $item (
            {};
            .[$item.key] = ($item.value | sub("^\\\""; "") | sub("\\\"$"; ""))
        )
    '
}

linux_install_date() {
    local root=$1
    local candidate

    for candidate in var/log/installer etc/machine-id var/lib/dpkg/status; do
        if candidate=$(safe_existing_guest_path "$root" "$candidate"); then
            stat --format='%w' "$candidate" 2>/dev/null | sed '/^-$/{d;}'
            return 0
        fi
    done
    printf '\n'
}

extract_linux_os() {
    local root=$1
    local device=$2
    local os_release_file=""
    local os_release
    local hostname=""
    local install_date

    os_release_file=$(safe_existing_guest_path "$root" etc/os-release 2>/dev/null || true)
    if [[ -z $os_release_file || ! -f $os_release_file ]]; then
        os_release_file=$(safe_existing_guest_path "$root" usr/lib/os-release 2>/dev/null || true)
    fi
    os_release=$(os_release_json "$os_release_file")
    local hostname_file
    hostname_file=$(safe_existing_guest_path "$root" etc/hostname 2>/dev/null || true)
    [[ -z $hostname_file || ! -f $hostname_file ]] || hostname=$(head -n 1 "$hostname_file")
    install_date=$(linux_install_date "$root")

    jq --null-input \
        --argjson detected true \
        --arg root_partition "$device" \
        --arg hostname "$hostname" \
        --argjson machine_id_present "$(
            safe_existing_guest_path "$root" etc/machine-id >/dev/null 2>&1 && echo true || echo false
        )" \
        --arg install_date "$install_date" \
        --argjson os_release "$os_release" \
        '{
            detected: $detected,
            root_partition: $root_partition,
            os_release: $os_release,
            hostname: $hostname,
            machine_id_present: $machine_id_present,
            install_date_best_effort: (if $install_date == "" then null else $install_date end)
        }' > "$METADATA_DIR/linux/os.json"
}

extract_linux_users_and_groups() {
    local root=$1
    local sudoers_paths='[]'
    local file
    local passwd_file
    local group_file
    local sudoers_file
    local sudoers_dir

    passwd_file=$(safe_existing_guest_path "$root" etc/passwd 2>/dev/null || true)
    group_file=$(safe_existing_guest_path "$root" etc/group 2>/dev/null || true)
    sudoers_file=$(safe_existing_guest_path "$root" etc/sudoers 2>/dev/null || true)
    sudoers_dir=$(safe_existing_guest_path "$root" etc/sudoers.d 2>/dev/null || true)

    if [[ -n $passwd_file && -f $passwd_file ]]; then
        jq --raw-input --slurp '
            split("\n")
            | map(select(length > 0) | split(":"))
            | map(select(length >= 7) | {
                username: .[0],
                uid: (.[2] | tonumber? // .[2]),
                gid: (.[3] | tonumber? // .[3]),
                gecos: .[4],
                home: .[5],
                shell: .[6]
            })
        ' "$passwd_file" > "$METADATA_DIR/linux/users.json"
    else
        printf '[]\n' > "$METADATA_DIR/linux/users.json"
    fi

    if [[ -n $group_file && -f $group_file ]]; then
        jq --raw-input --slurp '
            split("\n")
            | map(select(length > 0) | split(":"))
            | map(select(length >= 4) | {
                name: .[0],
                gid: (.[2] | tonumber? // .[2]),
                members: (.[3] | split(",") | map(select(length > 0)))
            })
        ' "$group_file" > "$METADATA_DIR/linux/groups.json"
    else
        printf '[]\n' > "$METADATA_DIR/linux/groups.json"
    fi

    if [[ -n $sudoers_file && -f $sudoers_file ]]; then
        sudoers_paths=$(jq --compact-output '. + ["/etc/sudoers"]' <<< "$sudoers_paths")
    fi
    if [[ -n $sudoers_dir && -d $sudoers_dir ]]; then
        while IFS= read -r file; do
            sudoers_paths=$(jq --compact-output --arg path "/etc/sudoers.d/$(basename -- "$file")" \
                '. + [$path]' <<< "$sudoers_paths")
        done < <(find "$sudoers_dir" -maxdepth 1 -type f -print)
    fi

    jq --argjson sudoers_files "$sudoers_paths" \
        '{users: ., sudoers_summary: {files_present: $sudoers_files, contents_collected: false}}' \
        "$METADATA_DIR/linux/users.json" > "$SESSION_DIR/linux-users-with-sudoers.json"
    mv -- "$SESSION_DIR/linux-users-with-sudoers.json" "$METADATA_DIR/linux/users.json"
    LINUX_USER_COUNT=$(jq '.users | length' "$METADATA_DIR/linux/users.json")
}

parse_dpkg_packages() {
    local status_file=$1

    jq --rawfile data "$status_file" --null-input '
        def field($name):
            try capture("(?m)^" + $name + ": (?<value>.*)$").value catch null;
        {
            package_manager: "dpkg",
            packages: (
                $data
                | split("\n\n")
                | map(select((field("Status") // "") == "install ok installed"))
                | map({
                    name: field("Package"),
                    version: field("Version"),
                    architecture: field("Architecture"),
                    status: field("Status")
                })
            )
        }
    '
}

extract_linux_packages() {
    local root=$1
    local package_output="$METADATA_DIR/linux/packages.json"
    local package_lines="$SESSION_DIR/linux-packages.tsv"
    local package_dir
    local dpkg_status
    local pacman_dir
    local apk_installed
    local rpm_dir

    dpkg_status=$(safe_existing_guest_path "$root" var/lib/dpkg/status 2>/dev/null || true)
    pacman_dir=$(safe_existing_guest_path "$root" var/lib/pacman/local 2>/dev/null || true)
    apk_installed=$(safe_existing_guest_path "$root" lib/apk/db/installed 2>/dev/null || true)
    rpm_dir=$(safe_existing_guest_path "$root" var/lib/rpm 2>/dev/null || true)

    if [[ -n $dpkg_status && -f $dpkg_status ]]; then
        parse_dpkg_packages "$dpkg_status" > "$package_output"
    elif [[ -n $pacman_dir && -d $pacman_dir ]]; then
        : > "$package_lines"
        while IFS= read -r package_dir; do
            basename -- "$package_dir" >> "$package_lines"
        done < <(find "$pacman_dir" -mindepth 1 -maxdepth 1 -type d -print)
        jq --raw-input --slurp '{
            package_manager: "pacman",
            packages: (split("\n") | map(select(length > 0) | {name_and_version: .}))
        }' "$package_lines" > "$package_output"
    elif [[ -n $apk_installed && -f $apk_installed ]]; then
        awk -F: '$1 == "P" {name=$2} $1 == "V" {print name "\t" $2}' \
            "$apk_installed" > "$package_lines"
        jq --raw-input --slurp '{
            package_manager: "apk",
            packages: (split("\n") | map(select(length > 0) | split("\t") | {name: .[0], version: .[1]}))
        }' "$package_lines" > "$package_output"
    elif [[ -n $rpm_dir && -d $rpm_dir ]]; then
        if command -v rpm >/dev/null 2>&1; then
            if run_recorded_command query_rpm_packages \
                "$package_lines" "$LOGS_DIR/query-rpm-packages.stderr.log" \
                rpm --root "$root" --query --all --queryformat $'%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\n'; then
                jq --raw-input --slurp '{
                    package_manager: "rpm",
                    packages: (split("\n") | map(select(length > 0) | split("\t") | {
                        name: .[0], version: .[1], architecture: .[2]
                    }))
                }' "$package_lines" > "$package_output"
            else
                jq --null-input '{package_manager: "rpm", packages: [], warning: "Host rpm could not read the archived database."}' \
                    > "$package_output"
                add_warning "Could not query the archived RPM database."
            fi
        else
            jq --null-input '{package_manager: "rpm", packages: [], warning: "The rpm command is not installed."}' \
                > "$package_output"
            add_warning "The rpm command is not installed; package inventory was skipped."
        fi
    else
        jq --null-input '{package_manager: null, packages: [], warning: "No supported package database was found."}' \
            > "$package_output"
    fi

    LINUX_PACKAGE_COUNT=$(jq '.packages | length' "$package_output")
}

redact_network_content() {
    sed -E \
        -e 's/^([[:space:]]*(password|passwd|psk|secret|private[-_]?key|private[-_]?key-password)[[:space:]]*[:=]).*/\1 <redacted>/I' \
        -e 's/(password|passwd|psk|secret|private[-_]?key)=([^,[:space:]]+)/\1=<redacted>/Ig'
}

add_linux_network_file() {
    local root=$1
    local file=$2
    local records_file=$3
    local relative_path=${file#"$root"}
    local content

    file=$(safe_existing_guest_path "$root" "$relative_path") || return 0

    if [[ $REDACT_SECRETS == true && $relative_path =~ ^/etc/(NetworkManager/system-connections|openvpn|wireguard)/ ]]; then
        content="<redacted: sensitive connection file omitted>"
    elif [[ $REDACT_SECRETS == true ]]; then
        content=$(redact_network_content < "$file")
    else
        content=$(cat -- "$file")
    fi

    jq --null-input --compact-output \
        --arg path "$relative_path" \
        --arg content "$content" \
        --argjson secrets_redacted "$REDACT_SECRETS" \
        '{path: $path, content: $content, secrets_redacted: $secrets_redacted}' \
        >> "$records_file"
}

extract_linux_network() {
    local root=$1
    local records_file="$SESSION_DIR/linux-network.jsonl"
    local file
    local directory
    local candidate
    local hostname=""
    local -a fixed_files=(
        etc/hosts
        etc/resolv.conf
        etc/network/interfaces
    )

    : > "$records_file"
    candidate=$(safe_existing_guest_path "$root" etc/hostname 2>/dev/null || true)
    [[ -z $candidate || ! -f $candidate ]] || hostname=$(head -n 1 "$candidate")

    for file in "${fixed_files[@]}"; do
        candidate=$(safe_existing_guest_path "$root" "$file" 2>/dev/null || true)
        [[ -z $candidate || ! -f $candidate ]] || add_linux_network_file "$root" "$candidate" "$records_file"
    done
    for file in \
        etc/netplan \
        etc/systemd/network \
        etc/NetworkManager/system-connections \
        etc/openvpn \
        etc/wireguard; do
        directory=$(safe_existing_guest_path "$root" "$file" 2>/dev/null || true)
        [[ -n $directory && -d $directory ]] || continue
        while IFS= read -r candidate; do
            add_linux_network_file "$root" "$candidate" "$records_file"
        done < <(find "$directory" -maxdepth 2 -type f -print)
    done

    jq --null-input \
        --arg hostname "$hostname" \
        --argjson secrets_redacted "$REDACT_SECRETS" \
        --slurpfile configurations "$records_file" \
        '{hostname: $hostname, secrets_redacted: $secrets_redacted, configurations: $configurations}' \
        > "$METADATA_DIR/linux/network.json"
}

extract_linux_filesystems() {
    local root=$1
    local fstab

    fstab=$(safe_existing_guest_path "$root" etc/fstab 2>/dev/null || true)

    if [[ -z $fstab || ! -f $fstab ]]; then
        jq --null-input '{fstab_present: false, entries: []}' > "$METADATA_DIR/linux/filesystems.json"
        return 0
    fi

    awk '!/^[[:space:]]*(#|$)/ {print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6}' \
        "$fstab" | if [[ $REDACT_SECRETS == true ]]; then redact_network_content; else cat; fi \
        > "$SESSION_DIR/fstab.tsv"
    jq --raw-input --slurp '{
        fstab_present: true,
        entries: (split("\n") | map(select(length > 0) | split("\t") | {
            source: .[0], mountpoint: .[1], filesystem: .[2], options: .[3], dump: .[4], pass: .[5]
        }))
    }' "$SESSION_DIR/fstab.tsv" > "$METADATA_DIR/linux/filesystems.json"
}

extract_linux_boot_history() {
    local root=$1
    local entries_file="$SESSION_DIR/linux-boot-history.txt"
    local method="unavailable"
    local -a log_paths=()
    local path
    local logs_json
    local candidate
    local wtmp_file
    local journal_dir

    : > "$entries_file"
    for path in var/log/journal var/log/wtmp var/log/syslog var/log/messages var/log/kern.log; do
        if candidate=$(safe_existing_guest_path "$root" "$path" 2>/dev/null); then
            log_paths+=("/$path")
        fi
    done

    wtmp_file=$(safe_existing_guest_path "$root" var/log/wtmp 2>/dev/null || true)
    if [[ -n $wtmp_file && -f $wtmp_file ]] && command -v last >/dev/null 2>&1; then
        if run_recorded_command read_linux_wtmp \
            "$entries_file" "$LOGS_DIR/read-linux-wtmp.stderr.log" \
            last --time-format iso -x -f "$wtmp_file" reboot; then
            method="wtmp"
        fi
    fi
    journal_dir=$(safe_existing_guest_path "$root" var/log/journal 2>/dev/null || true)
    if [[ $method == unavailable && -n $journal_dir && -d $journal_dir ]] && command -v journalctl >/dev/null 2>&1; then
        if run_recorded_command read_linux_journal_boots \
            "$entries_file" "$LOGS_DIR/read-linux-journal.stderr.log" \
            journalctl --directory "$journal_dir" --list-boots --no-pager \
                --output=short-iso; then
            method="systemd-journal"
        fi
    fi

    logs_json=$(jq --null-input '$ARGS.positional' --args "${log_paths[@]}")
    jq --rawfile entries "$entries_file" \
        --arg method "$method" \
        --argjson source_logs "$logs_json" \
        --null-input '{
            best_effort: true,
            method: $method,
            source_logs_present: $source_logs,
            entries: ($entries | split("\n") | map(select(length > 0)))
        }' > "$METADATA_DIR/linux/boot-history.json"
}

extract_linux_metadata() {
    local root=$1
    local device=$2

    log_info "Extracting Linux metadata from image filesystem $device."
    extract_linux_os "$root" "$device"
    extract_linux_users_and_groups "$root"
    extract_linux_packages "$root"
    extract_linux_network "$root"
    extract_linux_filesystems "$root"
    extract_linux_boot_history "$root"
    LINUX_EXTRACTED=true
}

registry_value() {
    local export_file=$1
    local value_name=$2

    [[ -f $export_file ]] || return 0
    sed -nE "s/^\"${value_name}\"=\"(.*)\"$/\\1/p" "$export_file" | head -n 1
}

registry_dword() {
    local export_file=$1
    local value_name=$2
    local hexadecimal

    [[ -f $export_file ]] || return 0
    hexadecimal=$(sed -nE "s/^\"${value_name}\"=dword:([0-9a-fA-F]+)$/\\1/p" "$export_file" |
        head -n 1)
    [[ -n $hexadecimal ]] || return 0
    printf '%d\n' "$((16#$hexadecimal))"
}

export_registry_key() {
    local name=$1
    local hive=$2
    local key=$3
    local output_file=$4
    local max_depth=${5:--1}

    if ! command -v hivexregedit >/dev/null 2>&1; then
        record_skipped_command "$name" "$output_file" "$LOGS_DIR/$name.stderr.log" \
            "Optional tool 'hivexregedit' is not installed; registry extraction was skipped."
        return 1
    fi

    run_recorded_command "$name" "$output_file" "$LOGS_DIR/$name.stderr.log" \
        hivexregedit --export --unsafe-printable-strings --max-depth "$max_depth" \
        "$hive" "$key"
}

find_windows_path() {
    resolve_case_insensitive_path "$1" "$2"
}

parse_windows_applications() {
    local export_file=$1
    local output_file=$2
    local tsv_file=$3

    if [[ -s $export_file ]]; then
        awk '
        function hexadecimal_to_decimal(value, result, index_position, digit, character) {
            result = 0
            for (index_position = 1; index_position <= length(value); index_position++) {
                character = tolower(substr(value, index_position, 1))
                digit = index("0123456789abcdef", character) - 1
                if (digit < 0) {
                    return ""
                }
                result = (result * 16) + digit
            }
            return result
        }
        function clean_value(line) {
            sub(/^[^=]*=/, "", line)
            if (line ~ /^".*"$/) {
                sub(/^"/, "", line)
                sub(/"$/, "", line)
                gsub(/\\\\/, "\\", line)
                gsub(/\\"/, "\"", line)
                return line
            }
            return ""
        }
        function clean_number(line) {
            sub(/^[^=]*=/, "", line)
            if (line ~ /^dword:[0-9a-fA-F]+$/) {
                sub(/^dword:/, "", line)
                return hexadecimal_to_decimal(line)
            }
            return clean_value(line)
        }
        function emit() {
            if (display_name != "") {
                print display_name "\t" display_version "\t" publisher "\t" install_date "\t" install_location "\t" estimated_size
            }
        }
        /^\[/ {
            emit()
            display_name = display_version = publisher = install_date = install_location = estimated_size = ""
            next
        }
        /^"DisplayName"=/ {display_name = clean_value($0); next}
        /^"DisplayVersion"=/ {display_version = clean_value($0); next}
        /^"Publisher"=/ {publisher = clean_value($0); next}
        /^"InstallDate"=/ {install_date = clean_value($0); next}
        /^"InstallLocation"=/ {install_location = clean_value($0); next}
        /^"EstimatedSize"=/ {estimated_size = clean_number($0); next}
        END {emit()}
        ' "$export_file" >> "$tsv_file"
    fi

    jq --raw-input --slurp '
        split("\n")
        | map(select(length > 0) | split("\t") | {
            display_name: .[0],
            display_version: .[1],
            publisher: .[2],
            install_date: .[3],
            install_location: .[4],
            estimated_size: (.[5] | tonumber? // null)
        })
        | unique_by([.display_name, .display_version, .publisher])
        | sort_by(.display_name)
    ' "$tsv_file" > "$output_file"
}

parse_registry_profiles() {
    local export_file=$1
    local tsv_file=$2

    [[ -s $export_file ]] || return 0
    awk '
        function clean_value(line) {
            sub(/^[^=]*=/, "", line)
            if (line ~ /^".*"$/) {
                sub(/^"/, "", line)
                sub(/"$/, "", line)
                gsub(/\\\\/, "\\", line)
                return line
            }
            return ""
        }
        function emit() {
            if (sid ~ /^S-[0-9-]+$/ && profile_path != "") {
                print sid "\t" profile_path
            }
        }
        /^\[/ {
            emit()
            section = $0
            sub(/^.*\\/, "", section)
            sub(/\]$/, "", section)
            sid = section
            profile_path = ""
            next
        }
        /^"ProfileImagePath"=/ {profile_path = clean_value($0); next}
        END {emit()}
    ' "$export_file" >> "$tsv_file"
}

extract_windows_profiles() {
    local root=$1
    local profile_export=$2
    local users_dir
    local profile_dir
    local records="$SESSION_DIR/windows-profiles.jsonl"
    local registry_profiles="$SESSION_DIR/windows-registry-profiles.tsv"
    local sid
    local profile_path
    local username
    local resolved_profile
    local modified_time

    : > "$records"
    : > "$registry_profiles"
    parse_registry_profiles "$profile_export" "$registry_profiles"
    while IFS=$'\t' read -r sid profile_path; do
        [[ -n $sid && -n $profile_path ]] || continue
        username=${profile_path##*\\}
        resolved_profile=$(find_windows_path "$root" "Users/$username" 2>/dev/null || true)
        modified_time=""
        [[ -z $resolved_profile ]] || modified_time=$(stat --format='%y' "$resolved_profile" 2>/dev/null || true)
        jq --null-input --compact-output \
            --arg sid "$sid" \
            --arg profile_path "$profile_path" \
            --arg username_guess "$username" \
            --argjson directory_exists "$([[ -n $resolved_profile ]] && echo true || echo false)" \
            --arg last_modified_time "$modified_time" \
            '{
                sid: $sid,
                profile_path: $profile_path,
                username_guess: $username_guess,
                profile_directory_exists: $directory_exists,
                last_modified_time: $last_modified_time
            }' >> "$records"
    done < "$registry_profiles"

    users_dir=$(find_windows_path "$root" Users 2>/dev/null || true)
    if [[ -n $users_dir && -d $users_dir ]]; then
        while IFS= read -r profile_dir; do
            jq --null-input --compact-output \
                --arg username_guess "$(basename -- "$profile_dir")" \
                --arg profile_path "C:\\Users\\$(basename -- "$profile_dir")" \
                --arg last_modified_time "$(stat --format='%y' "$profile_dir" 2>/dev/null || true)" \
                '{
                    sid: null,
                    profile_path: $profile_path,
                    username_guess: $username_guess,
                    profile_directory_exists: true,
                    last_modified_time: $last_modified_time
                }' >> "$records"
        done < <(find "$users_dir" -mindepth 1 -maxdepth 1 -type d -print)
    fi

    jq --slurp 'unique_by(.profile_path) | sort_by(.username_guess)' "$records" \
        > "$METADATA_DIR/windows/profiles.json"
    jq '{
        users: map({username_guess, profile_path, sid}),
        credential_material_collected: false,
        note: "Users are inferred from profile directories; SAM password hashes are not read."
    }' "$METADATA_DIR/windows/profiles.json" > "$METADATA_DIR/windows/users.json"
    WINDOWS_USER_COUNT=$(jq '.users | length' "$METADATA_DIR/windows/users.json")
}

extract_windows_network() {
    local tcpip_export=$1
    local hostname=$2
    local records="$SESSION_DIR/windows-network-values.jsonl"
    local value_name
    local value

    : > "$records"
    for value_name in \
        Hostname Domain DhcpIPAddress DhcpSubnetMask DhcpDefaultGateway \
        NameServer DhcpNameServer; do
        while IFS= read -r value; do
            [[ -n $value ]] || continue
            jq --null-input --compact-output \
                --arg name "$value_name" \
                --arg value "$value" \
                '{name: $name, value: $value}' >> "$records"
        done < <(sed -nE "s/^\"${value_name}\"=\"(.*)\"$/\\1/p" "$tcpip_export" 2>/dev/null || true)
    done

    jq --null-input \
        --arg hostname "$hostname" \
        --argjson secrets_redacted "$REDACT_SECRETS" \
        --slurpfile values "$records" \
        '{
            hostname: (if $hostname == "" then null else $hostname end),
            secrets_redacted: $secrets_redacted,
            tcpip_values: $values,
            note: "Only whitelisted TCP/IP fields were extracted from the SYSTEM hive."
        }' > "$METADATA_DIR/windows/network.json"
}

extract_windows_boot_history() {
    local root=$1
    local event_log
    local export_file="$SESSION_DIR/windows-system-evtx.txt"
    local summary_file="$METADATA_DIR/windows/boot-history.json"

    event_log=$(find_windows_path "$root" 'Windows/System32/winevt/Logs/System.evtx' 2>/dev/null || true)
    if [[ -z $event_log ]]; then
        jq --null-input '{best_effort: true, event_log_present: false, events: []}' > "$summary_file"
        return 0
    fi

    if command -v evtxexport >/dev/null 2>&1; then
        if run_recorded_command export_windows_system_events \
            "$export_file" "$LOGS_DIR/evtxexport.stderr.log" \
            evtxexport "$event_log"; then
            grep -E -B 8 -A 12 'Event identifier[^0-9]*(6005|6009|12|41)([^0-9]|$)' \
                "$export_file" > "$SESSION_DIR/windows-boot-events.txt" || true
            jq --rawfile events "$SESSION_DIR/windows-boot-events.txt" --null-input '{
                best_effort: true,
                event_log_present: true,
                parser: "evtxexport",
                event_ids_requested: [6005, 6009, 12, 41],
                summary: ($events | split("\n") | map(select(length > 0)))
            }' > "$summary_file"
            return 0
        fi
    fi

    jq --null-input '{
        best_effort: true,
        event_log_present: true,
        parser: null,
        events: [],
        warning: "System.evtx is present but libevtx-utils could not parse it."
    }' > "$summary_file"
    add_warning "System.evtx is present but could not be parsed with evtxexport."
}

extract_windows_metadata() {
    local root=$1
    local device=$2
    local software_hive
    local system_hive
    local current_version="$SESSION_DIR/windows-current-version.reg"
    local profile_list="$SESSION_DIR/windows-profile-list.reg"
    local uninstall_64="$SESSION_DIR/windows-uninstall-64.reg"
    local uninstall_32="$SESSION_DIR/windows-uninstall-32.reg"
    local tcpip="$SESSION_DIR/windows-tcpip.reg"
    local timezone="$SESSION_DIR/windows-timezone.reg"
    local select_key="$SESSION_DIR/windows-select.reg"
    local applications_tsv="$SESSION_DIR/windows-applications.tsv"
    local hostname=""
    local product_name=""
    local display_version=""
    local current_build=""
    local edition_id=""
    local install_date=""
    local install_date_epoch=""
    local timezone_name=""
    local control_set_number=1
    local control_set="ControlSet001"

    log_info "Extracting Windows metadata from image filesystem $device."
    software_hive=$(find_windows_path "$root" 'Windows/System32/config/SOFTWARE' 2>/dev/null || true)
    system_hive=$(find_windows_path "$root" 'Windows/System32/config/SYSTEM' 2>/dev/null || true)
    : > "$applications_tsv"

    if ! command -v hivexregedit >/dev/null 2>&1; then
        add_warning "hivexregedit is not installed; Windows registry metadata is unavailable."
    fi

    if [[ -n $software_hive ]]; then
        export_registry_key windows_current_version "$software_hive" \
            '\Microsoft\Windows NT\CurrentVersion' "$current_version" 1 || true
        export_registry_key windows_profile_list "$software_hive" \
            '\Microsoft\Windows NT\CurrentVersion\ProfileList' "$profile_list" 2 || true
        export_registry_key windows_uninstall_64 "$software_hive" \
            '\Microsoft\Windows\CurrentVersion\Uninstall' "$uninstall_64" 2 || true
        export_registry_key windows_uninstall_32 "$software_hive" \
            '\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' "$uninstall_32" 2 || true
    fi
    if [[ -n $system_hive ]]; then
        export_registry_key windows_select "$system_hive" \
            '\Select' "$select_key" 1 || true
        control_set_number=$(registry_dword "$select_key" Current)
        [[ -n $control_set_number ]] || control_set_number=1
        printf -v control_set 'ControlSet%03d' "$control_set_number"
        export_registry_key windows_tcpip "$system_hive" \
            "\\$control_set\\Services\\Tcpip\\Parameters" "$tcpip" 4 || true
        export_registry_key windows_timezone "$system_hive" \
            "\\$control_set\\Control\\TimeZoneInformation" "$timezone" 1 || true
    fi

    product_name=$(registry_value "$current_version" ProductName)
    display_version=$(registry_value "$current_version" DisplayVersion)
    current_build=$(registry_value "$current_version" CurrentBuild)
    edition_id=$(registry_value "$current_version" EditionID)
    install_date=$(registry_value "$current_version" InstallDate)
    if [[ -z $install_date ]]; then
        install_date_epoch=$(registry_dword "$current_version" InstallDate)
        if [[ -n $install_date_epoch ]]; then
            install_date=$(date --date="@$install_date_epoch" +"%Y-%m-%dT%H:%M:%S%:z" 2>/dev/null || true)
        fi
    fi
    hostname=$(registry_value "$tcpip" Hostname)
    timezone_name=$(registry_value "$timezone" TimeZoneKeyName)

    jq --null-input \
        --argjson detected true \
        --arg root_partition "$device" \
        --arg product_name "$product_name" \
        --arg display_version "$display_version" \
        --arg current_build "$current_build" \
        --arg edition_id "$edition_id" \
        --arg install_date "$install_date" \
        --arg hostname "$hostname" \
        --arg timezone "$timezone_name" \
        '{
            detected: $detected,
            root_partition: $root_partition,
            product_name: (if $product_name == "" then null else $product_name end),
            display_version: (if $display_version == "" then null else $display_version end),
            current_build: (if $current_build == "" then null else $current_build end),
            edition_id: (if $edition_id == "" then null else $edition_id end),
            install_date_best_effort: (if $install_date == "" then null else $install_date end),
            hostname: (if $hostname == "" then null else $hostname end),
            timezone: (if $timezone == "" then null else $timezone end)
        }' > "$METADATA_DIR/windows/os.json"

    parse_windows_applications "$uninstall_64" "$METADATA_DIR/windows/applications.json" "$applications_tsv"
    parse_windows_applications "$uninstall_32" "$METADATA_DIR/windows/applications.json" "$applications_tsv"
    WINDOWS_APPLICATION_COUNT=$(jq 'length' "$METADATA_DIR/windows/applications.json")
    extract_windows_profiles "$root" "$profile_list"
    extract_windows_network "$tcpip" "$hostname"
    extract_windows_boot_history "$root"
    WINDOWS_EXTRACTED=true
}

inspect_mounted_filesystem() {
    local mount_dir=$1
    local device=$2
    local safe_device=$3
    local windows_evidence_file="$SESSION_DIR/windows-evidence-$safe_device.txt"
    local linux_evidence_file="$SESSION_DIR/linux-evidence-$safe_device.txt"
    local windows_count
    local linux_count
    local confidence

    windows_evidence "$mount_dir" "$windows_evidence_file"
    linux_evidence "$mount_dir" "$linux_evidence_file"
    windows_count=$(wc -l < "$windows_evidence_file")
    linux_count=$(wc -l < "$linux_evidence_file")

    if ((windows_count >= 2)); then
        confidence=medium
        ((windows_count >= 4)) && confidence=high
        append_detection windows "$confidence" "$device" "$windows_evidence_file"
        if [[ $EXTRACT_WINDOWS == true && $WINDOWS_EXTRACTED == false ]]; then
            extract_windows_metadata "$mount_dir" "$device"
        fi
    fi

    if ((linux_count >= 2)); then
        confidence=medium
        ((linux_count >= 4)) && confidence=high
        append_detection linux "$confidence" "$device" "$linux_evidence_file"
        if [[ $EXTRACT_LINUX == true && $LINUX_EXTRACTED == false ]]; then
            extract_linux_metadata "$mount_dir" "$device"
        fi
    fi
}

inspect_filesystems() {
    local device
    local filesystem
    local safe_device
    local mount_dir
    local mount_status

    while IFS=: read -r device filesystem; do
        device=$(trim_whitespace "$device")
        filesystem=$(trim_whitespace "$filesystem")
        [[ -n $device ]] || continue
        case $filesystem in
            swap|unknown|'')
                printf '%s skipped %s (%s)\n' "$(record_time_now)" "$device" "$filesystem" \
                    >> "$MOUNT_DATA_DIR/mount-report.txt"
                continue
                ;;
        esac

        safe_device=$(basename -- "$device" | tr -c 'A-Za-z0-9._-' '_')
        mount_dir="$SESSION_DIR/mount-$safe_device"
        ACTIVE_MOUNT_PID_FILE="$SESSION_DIR/guestmount-$safe_device.pid"
        ACTIVE_MOUNT_PID=""
        GUESTMOUNT_WAIT_TIMED_OUT=false
        mkdir -p -- "$mount_dir"
        ACTIVE_MOUNT=$mount_dir

        if run_recorded_command "guestmount_$safe_device" \
            "$LOGS_DIR/guestmount-$safe_device.log" "$LOGS_DIR/guestmount-$safe_device.stderr.log" \
            guestmount --format=raw --add "$ACTIVE_IMAGE" --mount "$device" --ro \
                --pid-file "$ACTIVE_MOUNT_PID_FILE" "$mount_dir"; then
            ACTIVE_MOUNT_PID=$(read_guestmount_pid "$ACTIVE_MOUNT_PID_FILE") || \
                die "guestmount did not record its worker PID for image filesystem $device."
            printf '%s mounted image filesystem %s (%s) read-only at %s\n' \
                "$(record_time_now)" "$device" "$filesystem" "$mount_dir" \
                >> "$MOUNT_DATA_DIR/mount-report.txt"
            inspect_mounted_filesystem "$mount_dir" "$device" "$safe_device"
        else
            mount_status=$?
            ACTIVE_MOUNT_PID=$(read_guestmount_pid "$ACTIVE_MOUNT_PID_FILE" || true)
            printf '%s failed to mount image filesystem %s (%s), exit %s\n' \
                "$(record_time_now)" "$device" "$filesystem" "$mount_status" \
                >> "$MOUNT_DATA_DIR/mount-report.txt"
            add_warning \
                "Could not mount image filesystem $device read-only;" \
                "metadata on it was not inspected."
        fi

        if mountpoint --quiet "$mount_dir"; then
            run_recorded_command "guestunmount_$safe_device" \
                "$LOGS_DIR/guestunmount-$safe_device.log" "$LOGS_DIR/guestunmount-$safe_device.stderr.log" \
                guestunmount "$mount_dir" || die "Could not unmount $mount_dir."
        fi
        if [[ -n $ACTIVE_MOUNT_PID ]]; then
            wait_for_guestmount_exit "$ACTIVE_MOUNT_PID" || \
                die \
                    "guestmount did not finish cleanup for image filesystem" \
                    "$device from $ACTIVE_IMAGE."
        fi
        rm -f -- "$ACTIVE_MOUNT_PID_FILE"
        ACTIVE_MOUNT=""
        ACTIVE_MOUNT_PID=""
        ACTIVE_MOUNT_PID_FILE=""
        rmdir -- "$mount_dir" 2>/dev/null || true
    done < "$MOUNT_DATA_DIR/filesystems.txt"
}

write_empty_os_outputs() {
    local windows_detected
    local linux_detected

    windows_detected=$(jq 'any(.type == "windows")' <<< "$DETECTED_JSON")
    linux_detected=$(jq 'any(.type == "linux")' <<< "$DETECTED_JSON")

    if [[ $WINDOWS_EXTRACTED == false ]]; then
        jq --null-input --argjson detected "$windows_detected" '{
            detected: $detected,
            users: [],
            credential_material_collected: false
        }' > "$METADATA_DIR/windows/users.json"
        printf '[]\n' > "$METADATA_DIR/windows/profiles.json"
        printf '[]\n' > "$METADATA_DIR/windows/applications.json"
        jq --null-input --argjson detected "$windows_detected" '{detected: $detected}' \
            > "$METADATA_DIR/windows/os.json"
        jq --null-input --argjson detected "$windows_detected" \
            '{detected: $detected, configurations: []}' > "$METADATA_DIR/windows/network.json"
        jq --null-input --argjson detected "$windows_detected" \
            '{detected: $detected, best_effort: true, events: []}' \
            > "$METADATA_DIR/windows/boot-history.json"
    fi
    if [[ $LINUX_EXTRACTED == false ]]; then
        jq --null-input --argjson detected "$linux_detected" '{detected: $detected}' \
            > "$METADATA_DIR/linux/os.json"
        jq --null-input --argjson detected "$linux_detected" '{
            detected: $detected,
            users: [],
            sudoers_summary: {files_present: [], contents_collected: false}
        }' \
            > "$METADATA_DIR/linux/users.json"
        printf '[]\n' > "$METADATA_DIR/linux/groups.json"
        jq --null-input '{package_manager: null, packages: []}' > "$METADATA_DIR/linux/packages.json"
        jq --null-input --argjson detected "$linux_detected" \
            '{detected: $detected, configurations: []}' > "$METADATA_DIR/linux/network.json"
        jq --null-input --argjson detected "$linux_detected" \
            '{detected: $detected, best_effort: true, entries: []}' \
            > "$METADATA_DIR/linux/boot-history.json"
        jq --null-input --argjson detected "$linux_detected" \
            '{detected: $detected, entries: []}' > "$METADATA_DIR/linux/filesystems.json"
    fi
}

write_detection_json() {
    local relative_image

    relative_image=$(realpath --relative-to "$METADATA_DIR" "$IMAGE_PATH")
    jq --null-input \
        --arg image "$relative_image" \
        --argjson detected "$DETECTED_JSON" \
        '{image: $image, detected_operating_systems: $detected}' \
        > "$METADATA_DIR/detected-os.json"
    jq empty "$METADATA_DIR/detected-os.json"
}

write_metadata_summary() {
    local completed_at=$1
    local completed_epoch=$2
    local warnings_json
    local summary_file="$METADATA_DIR/$PC_ID.metadata.json"

    warnings_json=$(jq --null-input '$ARGS.positional' --args "${WARNINGS[@]}")
    jq --null-input \
        --arg schema_version "1.0" \
        --arg script_name "extract-metadata.sh" \
        --arg script_version "$SCRIPT_VERSION" \
        --arg pc_id "$PC_ID" \
        --arg image "$(realpath --relative-to "$ARCHIVE_ROOT" "$IMAGE_PATH")" \
        --arg started_at "$STARTED_AT" \
        --arg completed_at "$completed_at" \
        --arg timezone "$RECORD_TIMEZONE" \
        --argjson duration "$(duration_seconds "$STARTED_EPOCH" "$completed_epoch")" \
        --argjson detected "$DETECTED_JSON" \
        --argjson windows_extracted "$WINDOWS_EXTRACTED" \
        --argjson linux_extracted "$LINUX_EXTRACTED" \
        --argjson windows_users "$WINDOWS_USER_COUNT" \
        --argjson windows_applications "$WINDOWS_APPLICATION_COUNT" \
        --argjson linux_users "$LINUX_USER_COUNT" \
        --argjson linux_packages "$LINUX_PACKAGE_COUNT" \
        --argjson secrets_redacted "$REDACT_SECRETS" \
        --argjson warnings "$warnings_json" \
        '{
            schema_version: $schema_version,
            script: {name: $script_name, version: $script_version},
            pc_id: $pc_id,
            image: $image,
            started_at: $started_at,
            completed_at: $completed_at,
            timezone: $timezone,
            duration_seconds: $duration,
            detected_operating_systems: $detected,
            extraction: {
                windows: {
                    extracted: $windows_extracted,
                    users: $windows_users,
                    applications: $windows_applications
                },
                linux: {
                    extracted: $linux_extracted,
                    users: $linux_users,
                    packages: $linux_packages
                }
            },
            secrets_redacted: $secrets_redacted,
            warnings: $warnings
        }' > "$summary_file"
    jq empty "$summary_file"
}

write_metadata_readmes() {
    local completed_at=$1
    local completed_epoch=$2
    local detected_types
    local warning_lines="None."
    local warning
    local top_readme="$ARCHIVE_ROOT/README.md"
    local managed_block

    detected_types=$(jq --raw-output \
        '[.[] | .type] | unique | if length == 0 then "None" else join(", ") end' \
        <<< "$DETECTED_JSON")
    if ((${#WARNINGS[@]} > 0)); then
        warning_lines=""
        for warning in "${WARNINGS[@]}"; do
            warning_lines+="- $warning"$'\n'
        done
    fi

    cat > "$METADATA_DIR/README.md" <<EOF
# $PC_ID Metadata

## Summary

Metadata was extracted through read-only access to the disk image. Detected operating systems: $detected_types.

## Source Image

- Image: $(realpath --relative-to "$ARCHIVE_ROOT" "$IMAGE_PATH")
- Active analysis image: $ACTIVE_IMAGE
- Secrets redacted: $REDACT_SECRETS

## Runtime

- Started ($RECORD_TIMEZONE): $STARTED_AT
- Completed ($RECORD_TIMEZONE): $completed_at
- Duration: $(duration_seconds "$STARTED_EPOCH" "$completed_epoch") seconds
- Script version: $SCRIPT_VERSION

## Detected Operating Systems

See [detected-os.json](detected-os.json) for partitions, confidence, and detection evidence.

## Windows Metadata

Windows data is under [windows/](windows/). User profiles are inventory only; SAM password hashes and credential material are not collected.

## Linux Metadata

Linux data is under [linux/](linux/). The script does not read or copy \`/etc/shadow\`.

## Mount and Image Records

See [mount/](mount/) for image information, filesystem inventory, and the read-only mount report.

## Command Records

[commands.jsonl](commands.jsonl) records command timing, exit status, and output paths. Per-command errors are under [logs/](logs/).

## Limitations

Registry, event-log, RPM, and boot-history extraction is best effort and depends on compatible tools and source data being available.

## Warnings

$warning_lines
EOF

    ensure_managed_readme "$top_readme" "$PC_ID"
    managed_block=$(mktemp "$ARCHIVE_ROOT/.metadata-readme-block.XXXXXX")
    cat > "$managed_block" <<EOF
## Metadata Summary

- Metadata extracted ($RECORD_TIMEZONE): $completed_at
- Detected OS: $detected_types
- Users found: $((WINDOWS_USER_COUNT + LINUX_USER_COUNT))
- Applications/packages found: $((WINDOWS_APPLICATION_COUNT + LINUX_PACKAGE_COUNT))
- Metadata details: [METADATA/README.md](METADATA/README.md)
EOF
    update_readme_block "$top_readme" "extract-metadata.sh" "$managed_block"
    rm -- "$managed_block"
}

validate_generated_json() {
    local json_file

    while IFS= read -r json_file; do
        jq empty "$json_file"
    done < <(find "$METADATA_DIR" -path "$WORK_DIR" -prune -o -type f -name '*.json' -print)
}

main() {
    local completed_at
    local completed_epoch

    parse_arguments "$@"
    validate_arguments

    if [[ $DRY_RUN == true ]]; then
        show_dry_run
        exit 0
    fi

    validate_runtime
    register_cleanup_handler cleanup_metadata
    install_cleanup_trap
    prepare_output_tree
    STARTED_AT=$(record_time_now)
    STARTED_EPOCH=$(date +%s)

    if [[ $REDACT_SECRETS == false ]]; then
        add_warning "Network secret redaction was explicitly disabled."
    fi
    log_info "Metadata extraction started for $PC_ID."
    prepare_active_image
    log_info "Inspecting selected image: $ACTIVE_IMAGE"
    collect_image_information
    write_partitions_json
    inspect_filesystems
    write_empty_os_outputs
    write_detection_json

    completed_at=$(record_time_now)
    completed_epoch=$(date +%s)
    write_metadata_summary "$completed_at" "$completed_epoch"
    validate_generated_json
    write_metadata_readmes "$completed_at" "$completed_epoch"
    log_info "Metadata extraction completed. Details: $METADATA_DIR/README.md"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
