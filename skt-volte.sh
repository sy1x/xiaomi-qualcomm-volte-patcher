#!/usr/bin/env bash
set -euo pipefail

qmi_device=${QMI_DEVICE:-/dev/cdc-wdm0}
firmware_mbn=/vendor/firmware_mnt/image/modem_pr/mcfg/configs/mcfg_sw/generic/korea/skt/commerci/mcfg_sw.mbn

usage() {
  cat <<'EOF'
Usage: bash skt-volte.sh COMMAND
  profiles             List the modem's software profiles
  extract [FILE]       Copy and verify the SKT MBN from a connected davinci
  load FILE            Load the verified MBN without activating it
  activate CONFIG_ID   Request activation of a listed ID (also used for rollback)

Use QMI_DEVICE to select a node other than /dev/cdc-wdm0.
See README.md for the tested model, USB setup and loader workaround.
EOF
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_davinci() {
  local device
  device=$(adb shell getprop ro.product.device | tr -d '\r')
  [[ $device == davinci ]] || fail "Expected davinci on ADB, found '${device:-none}'."
}

profiles() {
  command -v qmicli >/dev/null || fail 'Install libqmi-utils first.'
  [[ -c $qmi_device ]] || fail "No QMI device at $qmi_device."
  qmicli -d "$qmi_device" --pdc-list-configs=software
}

verify_mbn() {
  local file=$1 local_hash device_hash
  [[ -s $file ]] || fail "Missing or empty MBN file: $file"
  device_hash=$(adb shell sha256sum "$firmware_mbn" | awk 'NR == 1 { print $1 }')
  local_hash=$(sha256sum -- "$file" | awk 'NR == 1 { print $1 }')
  [[ $local_hash == "$device_hash" ]] || fail 'The file differs from the SKT MBN on the phone.'
  printf 'Verified SHA-256: %s\n' "$local_hash"
}

action=${1:-help}
case "$action" in
  help|-h|--help)
    usage
    ;;
  profiles)
    [[ $# -eq 1 ]] || fail 'Usage: skt-volte.sh profiles'
    profiles
    ;;
  extract)
    [[ $# -le 2 ]] || fail 'Usage: skt-volte.sh extract [FILE]'
    require_davinci
    file=${2:-./davinci-skt-mcfg.mbn}
    [[ ! -e $file && ! -L $file ]] || fail "Output already exists: $file"
    adb pull "$firmware_mbn" "$file"
    verify_mbn "$file"
    ;;
  load)
    [[ $# -eq 2 ]] || fail 'Usage: skt-volte.sh load FILE'
    require_davinci
    verify_mbn "$2"
    profiles >/dev/null
    qmicli -d "$qmi_device" --pdc-load-config="$2"
    ;;
  activate)
    [[ $# -eq 2 ]] || fail 'Usage: skt-volte.sh activate CONFIG_ID'
    require_davinci
    id=${2^^}
    [[ $id =~ ^([0-9A-F]{2}:){19}[0-9A-F]{2}$ ]] || fail 'Expected a 20-byte colon-separated ID.'
    profile_list=$(profiles)
    grep -Eq "^[[:space:]]*ID:[[:space:]]+$id[[:space:]]*$" <<< "$profile_list" ||
      fail 'That ID does not appear in the software profile list.'
    qmicli -d "$qmi_device" --pdc-activate-config="software,$id"
    ;;
  *)
    usage >&2
    fail "Unknown command: $action"
    ;;
esac
