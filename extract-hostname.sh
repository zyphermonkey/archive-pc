#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DISK=""
HOSTNAME_GUESTFISH_PID=""
HOSTNAME_APPLIANCE_RUNNING=false
SELECTED_HOSTNAME=""
declare -a MISSING_HOSTNAME_PACKAGES=()

usage() {
    cat <<'EOF'
Usage:
  extract-hostname.sh [--target DEVICE] [--debug]

Read a Windows or Linux hostname directly from a disk before archiving.
Requires root. The source disk is opened read-only through libguestfs.

Options:
  --target DEVICE    Whole source disk; omit for a numbered disk list
  --debug            Enable diagnostic logging
  --help             Show this help

Only the selected hostname is written to stdout. Prompts, dependency
installation, and diagnostics go to stderr. Lookup failures return nonzero.

Example (run from a root shell):
  pc_id=$(./extract-hostname.sh --target /dev/sda) &&
    ./archive-disk.sh --target /dev/sda --pc-id "$pc_id"
EOF
}

parse_hostname_arguments() {
    while (($# > 0)); do
        case $1 in
            --target)
                (($# >= 2)) || die "--target requires a device path."
                TARGET_DISK=$2
                shift 2
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

hostname_tool_is_available() {
    command -v "$1" >/dev/null 2>&1
}

check_hostname_tool() {
    local tool=$1
    local package=$2
    local existing_package

    hostname_tool_is_available "$tool" && return 0
    for existing_package in "${MISSING_HOSTNAME_PACKAGES[@]}"; do
        [[ $existing_package == "$package" ]] && return 0
    done
    MISSING_HOSTNAME_PACKAGES+=("$package")
}

collect_hostname_dependencies() {
    MISSING_HOSTNAME_PACKAGES=()
    check_hostname_tool guestfish libguestfs-tools
    check_hostname_tool lsblk util-linux
    check_hostname_tool realpath coreutils
    check_hostname_tool date coreutils
}

install_hostname_packages() {
    hostname_tool_is_available apt-get || die "Missing packages were found, but apt-get is unavailable."
    apt-get update >&2 || die "apt-get update failed."
    DEBIAN_FRONTEND=noninteractive \
        apt-get install --yes --no-install-recommends "$@" >&2 || \
        die "apt-get could not install the required packages."
    hash -r
}

check_hostname_dependencies() {
    local answer
    local package

    collect_hostname_dependencies
    ((${#MISSING_HOSTNAME_PACKAGES[@]} > 0)) || return 0
    printf 'Missing packages required for hostname lookup:\n' >&2
    for package in "${MISSING_HOSTNAME_PACKAGES[@]}"; do
        printf '  - %s\n' "$package" >&2
    done

    while true; do
        printf 'Install the missing packages with apt? [Y/n] ' >&2
        read -r answer || die "Required packages were not approved; hostname lookup cannot continue."
        case ${answer,,} in
            y|yes|'')
                install_hostname_packages "${MISSING_HOSTNAME_PACKAGES[@]}"
                break
                ;;
            n|no)
                die "Required packages were declined; hostname lookup cannot continue."
                ;;
            *)
                printf 'Enter yes or no.\n' >&2
                ;;
        esac
    done

    collect_hostname_dependencies
    ((${#MISSING_HOSTNAME_PACKAGES[@]} == 0)) || \
        die "Required tools remain unavailable after installation: ${MISSING_HOSTNAME_PACKAGES[*]}"
}

select_hostname_target() {
    local disk
    local device_type
    local disk_listing
    local index
    local selection
    local -a disks=()

    disk_listing=$(lsblk --noheadings --nodeps --paths --output NAME,TYPE) || \
        die "Could not list source disks."
    while IFS=' ' read -r disk device_type; do
        if [[ $device_type == disk ]]; then
            disks+=("$disk")
        fi
    done <<< "$disk_listing"
    ((${#disks[@]} > 0)) || die "No whole source disks were found."

    printf 'Available disks for read-only hostname lookup:\n' >&2
    for index in "${!disks[@]}"; do
        printf '  [%d] ' "$((index + 1))" >&2
        lsblk --noheadings --nodeps --paths --output PATH,SIZE,MODEL,SERIAL,TRAN \
            "${disks[index]}" >&2 || die "Could not describe ${disks[index]}."
    done
    printf '  [0] Cancel\n' >&2
    while true; do
        printf 'Select the source disk by number: ' >&2
        read -r selection || die "No disk selection was received."
        [[ $selection != 0 ]] || die "Disk selection was cancelled."
        if [[ $selection =~ ^[1-9][0-9]{0,8}$ ]] && \
            ((selection <= ${#disks[@]})); then
            TARGET_DISK=${disks[selection - 1]}
            return 0
        fi
        printf 'Enter an integer from 0 to %d.\n' "${#disks[@]}" >&2
    done
}

validate_hostname_target() {
    local device_type

    [[ -b $TARGET_DISK ]] || die "Source is not a block device: $TARGET_DISK"
    TARGET_DISK=$(realpath --canonicalize-existing -- "$TARGET_DISK") || \
        die "Could not resolve the source disk path."
    device_type=$(lsblk --noheadings --nodeps --output TYPE "$TARGET_DISK") || \
        die "Could not inspect source disk: $TARGET_DISK"
    [[ $device_type == disk ]] || die "Source must be a whole disk: $TARGET_DISK"
}

hostname_guestfish() {
    log_debug "guestfish session $HOSTNAME_GUESTFISH_PID: $(printf '%q ' "$@")"
    guestfish --remote="$HOSTNAME_GUESTFISH_PID" "$@"
}

close_hostname_session() {
    local cleanup_status=0

    [[ -n $HOSTNAME_GUESTFISH_PID ]] || return 0
    # guestfish exit closes its handle but can hide appliance shutdown errors.
    if [[ $HOSTNAME_APPLIANCE_RUNNING == true ]]; then
        if ! hostname_guestfish shutdown >&2; then
            log_error "Could not shut down the libguestfs appliance."
            cleanup_status=1
        fi
        HOSTNAME_APPLIANCE_RUNNING=false
    fi
    if ! hostname_guestfish exit >&2; then
        log_error "Could not close guestfish session $HOSTNAME_GUESTFISH_PID."
        cleanup_status=1
    else
        HOSTNAME_GUESTFISH_PID=""
    fi
    return "$cleanup_status"
}

start_hostname_session() {
    local session_info

    log_info "Inspecting $TARGET_DISK read-only; starting libguestfs."
    session_info=$(guestfish --listen --ro --format=raw --add "$TARGET_DISK") || \
        die "Could not start a read-only guestfish session."
    # Parse the documented listener output without evaluating shell code.
    if [[ $session_info =~ GUESTFISH_PID=([1-9][0-9]*) ]]; then
        HOSTNAME_GUESTFISH_PID=${BASH_REMATCH[1]}
    else
        die "guestfish did not return a listener PID."
    fi
    hostname_guestfish run >&2 || die "Could not launch the libguestfs appliance."
    HOSTNAME_APPLIANCE_RUNNING=true
}

lookup_disk_hostname() {
    local roots
    local root
    local os_type
    local hostname
    local existing_hostname
    local duplicate
    local index
    local selection
    local -a hostnames=()
    local -a descriptions=()

    roots=$(hostname_guestfish inspect-os) || die "Could not inspect operating systems on $TARGET_DISK."
    [[ -n $roots ]] || \
        die "No supported operating system was found; encrypted or unsupported disks may require separate access."
    while IFS= read -r root; do
        [[ -n $root ]] || continue
        os_type=$(hostname_guestfish inspect-get-type "$root") || \
            die "Could not identify the operating system at $root."
        case $os_type in
            windows|linux) ;;
            *) continue ;;
        esac
        hostname=$(hostname_guestfish inspect-get-hostname "$root") || \
            die "Could not read the hostname at image filesystem $root."
        hostname=${hostname%$'\r'}
        if [[ -z $hostname || $hostname == unknown ]]; then
            log_warn "No stored hostname was found for $os_type at image filesystem $root."
            continue
        fi
        # Match archive-disk.sh's PC ID rules; never silently change a name.
        if [[ ! $hostname =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
            log_warn "The hostname at $root cannot be used as an archive PC ID."
            continue
        fi
        duplicate=false
        for existing_hostname in "${hostnames[@]}"; do
            [[ $existing_hostname != "$hostname" ]] || duplicate=true
        done
        [[ $duplicate == false ]] || continue
        hostnames+=("$hostname")
        descriptions+=("$os_type at image filesystem $root")
    done <<< "$roots"

    ((${#hostnames[@]} > 0)) || die "No usable Windows or Linux hostname was found on $TARGET_DISK."
    if ((${#hostnames[@]} == 1)); then
        SELECTED_HOSTNAME=${hostnames[0]}
        return 0
    fi

    printf 'Different hostnames were found on this disk:\n' >&2
    for index in "${!hostnames[@]}"; do
        printf '  [%d] %s (%s)\n' "$((index + 1))" \
            "${hostnames[index]}" "${descriptions[index]}" >&2
    done
    printf '  [0] Cancel\n' >&2
    while true; do
        printf 'Select the hostname to use by number: ' >&2
        read -r selection || die "A hostname selection is required; no hostname was emitted."
        [[ $selection != 0 ]] || die "Hostname selection was cancelled."
        if [[ $selection =~ ^[1-9][0-9]{0,8}$ ]] && \
            ((selection <= ${#hostnames[@]})); then
            SELECTED_HOSTNAME=${hostnames[selection - 1]}
            return 0
        fi
        printf 'Enter an integer from 0 to %d.\n' "${#hostnames[@]}" >&2
    done
}

main() {
    parse_hostname_arguments "$@"
    require_root
    check_hostname_dependencies
    if [[ -z $TARGET_DISK ]]; then
        select_hostname_target
    fi
    validate_hostname_target
    register_cleanup_handler close_hostname_session
    install_cleanup_trap
    start_hostname_session
    lookup_disk_hostname
    # Finish cleanup before emitting a result that could trigger archiving.
    close_hostname_session || die "Hostname lookup did not finish cleanup."
    printf '%s\n' "$SELECTED_HOSTNAME"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
