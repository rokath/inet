#!/usr/bin/env bash

set -u

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_NAME"

# Print a plain status line to stdout.
say() {
  printf '%s\n' "$*"
}

# Print an error line to stderr and stop immediately.
die() {
  say "$SCRIPT_NAME: $*" >&2
  exit 1
}

# Test whether a command is available in the current shell.
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Detect the current operating system so the script can dispatch
# to the correct platform-specific adapter management logic.
detect_os() {
  case "$(uname -s)" in
    Linux) printf 'linux\n' ;;
    Darwin) printf 'macos\n' ;;
    MINGW*|MSYS*|CYGWIN*) printf 'windows\n' ;;
    *) die "unsupported operating system: $(uname -s)" ;;
  esac
}

# Normalize user input so command handling stays case-insensitive.
normalize_action() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Check whether the current Windows shell is already elevated.
ensure_windows_admin() {
  local is_admin
  is_admin="$(
    powershell.exe -NoProfile -Command "[bool](([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))" \
      | tr -d '\r'
  )"
  [ "$is_admin" = "True" ]
}

# Create a temporary file path that both Git Bash and PowerShell can use.
make_temp_file() {
  if command_exists mktemp; then
    mktemp
  else
    powershell.exe -NoProfile -Command "[System.IO.Path]::GetTempFileName()" | tr -d '\r'
  fi
}

# Remove a temporary file quietly.
cleanup_file() {
  local file_path="$1"
  [ -n "$file_path" ] || return 0
  [ -f "$file_path" ] || return 0
  rm -f "$file_path"
}

# Re-launch the script with elevation on Windows, wait for it to finish,
# then read the final status back into the original Git Bash session.
windows_request_elevation() {
  local action="$1"
  local bash_exe bash_exe_win script_path_win result_file result_file_win

  bash_exe="$(command -v bash)" || die "bash was not found."
  command_exists cygpath || die "cygpath was not found."

  result_file="$(make_temp_file)" || die "failed to allocate a temporary file."
  bash_exe_win="$(cygpath -w "$bash_exe")"
  script_path_win="$(cygpath -w "$SCRIPT_PATH")"
  result_file_win="$(cygpath -w "$result_file")"

  powershell.exe -NoProfile -Command "
    \$ErrorActionPreference = 'Stop'
    \$process = Start-Process -FilePath '$bash_exe_win' -Verb RunAs -Wait -PassThru -ArgumentList @(
      '$script_path_win',
      '$action',
      '--elevated',
      '--result-file',
      '$result_file_win'
    )
    exit \$process.ExitCode
  " >/dev/null 2>&1 || {
    cleanup_file "$result_file"
    die "elevation failed or was cancelled."
  }

  if [ ! -f "$result_file" ]; then
    die "the elevated process did not return a status file."
  fi

  cat "$result_file"
  cleanup_file "$result_file"
  exit 0
}

# On Unix-like systems, adapter changes require root privileges.
ensure_unix_privileges() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    return 0
  fi

  command_exists sudo || die "please run as root or install sudo."
  sudo -v || die "failed to acquire sudo privileges."
}

# Execute a command with elevated privileges on Unix-like systems.
run_unix_privileged() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    "$@"
  else
    sudo -n "$@" || die "sudo session expired while applying network changes."
  fi
}

# Enable or disable physical Wi-Fi and Ethernet adapters on Windows.
windows_apply() {
  local action="$1"
  local verb status_word

  case "$action" in
    off)
      verb="Disable"
      status_word="Disabled"
      ;;
    on)
      verb="Enable"
      status_word="Up"
      ;;
    *)
      die "invalid action: $action"
      ;;
  esac

  powershell.exe -NoProfile -Command "
    \$ErrorActionPreference = 'Stop'
    \$adapters = Get-NetAdapter -Physical | Where-Object {
      \$_.HardwareInterface -eq \$true -and (
        \$_.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11|Ethernet|LAN' -or
        \$_.Name -match 'Wi-?Fi|WLAN|Wireless|Ethernet|LAN'
      )
    }
    if (-not \$adapters) {
      throw 'No matching Wi-Fi or Ethernet adapters were found.'
    }
    \$adapters | ${verb}-NetAdapter -Confirm:\$false | Out-Null
    \$summary = \$adapters | ForEach-Object { '{0} ({1})' -f \$_.Name, \$_.InterfaceDescription }
    Write-Output ('STATUS=${status_word}')
    Write-Output ('AFFECTED=' + (\$summary -join '; '))
  " | tr -d '\r'
}

# Enumerate network interface names that look like physical Wi-Fi or Ethernet
# devices while skipping loopback, virtual bridge, VPN, and tunnel adapters.
linux_interfaces() {
  ip -o link show | awk -F': ' '
    {
      name=$2
      gsub(/@.*/, "", name)
      lname=tolower(name)
      if (lname ~ /^(lo|docker|veth|br-|virbr|zt|tailscale|tun|tap|wg)/) {
        next
      }
      if (lname ~ /^(wl|wlp|wlan|en|eth)/) {
        print name
      }
    }
  '
}

# Prefer NetworkManager when it is available, because it handles the overall
# networking stack rather than toggling individual interfaces one by one.
linux_apply_nmcli() {
  local action="$1"

  if [ "$action" = "off" ]; then
    run_unix_privileged nmcli networking off >/dev/null
    printf 'STATUS=Disabled\n'
  else
    run_unix_privileged nmcli networking on >/dev/null
    printf 'STATUS=Up\n'
  fi
}

# Fallback Linux implementation for systems without NetworkManager.
linux_apply_ip() {
  local action="$1"
  local iface
  local found=0
  local affected=""

  while IFS= read -r iface; do
    [ -n "$iface" ] || continue
    found=1
    if [ "$action" = "off" ]; then
      run_unix_privileged ip link set dev "$iface" down
    else
      run_unix_privileged ip link set dev "$iface" up
    fi

    if [ -n "$affected" ]; then
      affected="$affected; $iface"
    else
      affected="$iface"
    fi
  done <<EOF
$(linux_interfaces)
EOF

  [ "$found" -eq 1 ] || die "no matching Wi-Fi or Ethernet interfaces were found."

  if [ "$action" = "off" ]; then
    printf 'STATUS=Disabled\n'
  else
    printf 'STATUS=Up\n'
  fi
  printf 'AFFECTED=%s\n' "$affected"
}

# Apply the Linux networking change using the best available backend.
linux_apply() {
  local action="$1"
  ensure_unix_privileges

  if command_exists nmcli; then
    linux_apply_nmcli "$action"
  elif command_exists ip; then
    linux_apply_ip "$action"
  else
    die "neither nmcli nor ip is available."
  fi
}

# Extract macOS device names for Wi-Fi/AirPort and Ethernet hardware ports.
macos_devices() {
  networksetup -listallhardwareports | awk '
    /^Hardware Port: / {
      port = substr($0, 16)
      wanted = (port ~ /Wi-Fi|AirPort|Ethernet/)
      next
    }
    wanted && /^Device: / {
      print substr($0, 9)
      wanted = 0
    }
  '
}

# Toggle matching network devices on macOS.
macos_apply() {
  local action="$1"
  local device
  local found=0
  local affected=""

  ensure_unix_privileges
  command_exists ifconfig || die "ifconfig is required on macOS."

  while IFS= read -r device; do
    [ -n "$device" ] || continue
    found=1
    if [ "$action" = "off" ]; then
      run_unix_privileged ifconfig "$device" down
    else
      run_unix_privileged ifconfig "$device" up
    fi

    if [ -n "$affected" ]; then
      affected="$affected; $device"
    else
      affected="$device"
    fi
  done <<EOF
$(macos_devices)
EOF

  [ "$found" -eq 1 ] || die "no matching Wi-Fi or Ethernet interfaces were found."

  if [ "$action" = "off" ]; then
    printf 'STATUS=Disabled\n'
  else
    printf 'STATUS=Up\n'
  fi
  printf 'AFFECTED=%s\n' "$affected"
}

# Use direct IP pings so the connectivity check still works even when DNS is
# unavailable. Two targets reduce false negatives from a single blocked host.
ping_once() {
  local os="$1"
  local target="$2"

  case "$os" in
    windows)
      ping -n 1 -w 1500 "$target" >/dev/null 2>&1
      ;;
    linux)
      ping -n -c 1 -W 2 "$target" >/dev/null 2>&1
      ;;
    macos)
      ping -n -q -c 1 -t 2 -W 1500 "$target" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

# Return success when any well-known public IP responds to ping.
has_internet() {
  local os="$1"
  local target

  for target in 1.1.1.1 8.8.8.8; do
    if ping_once "$os" "$target"; then
      return 0
    fi
  done

  return 1
}

# Small delay helper used while the network stack settles after adapter changes.
sleep_short() {
  if command_exists sleep; then
    sleep 1
  else
    powershell.exe -NoProfile -Command "Start-Sleep -Seconds 1" >/dev/null 2>&1
  fi
}

# After toggling adapters, verify that the observable internet state matches
# the requested target state and return a compact machine-readable summary.
verify_connectivity() {
  local os="$1"
  local action="$2"
  local attempt

  for attempt in 1 2 3 4 5; do
    if has_internet "$os"; then
      if [ "$action" = "on" ]; then
        printf 'CHECK=ok\n'
        printf 'CHECK_MESSAGE=Internet is reachable by ping.\n'
        return 0
      fi
    else
      if [ "$action" = "off" ]; then
        printf 'CHECK=ok\n'
        printf 'CHECK_MESSAGE=Internet is not reachable by ping.\n'
        return 0
      fi
    fi
    sleep_short
  done

  printf 'CHECK=fail\n'
  if [ "$action" = "on" ]; then
    printf 'CHECK_MESSAGE=Internet is still not reachable after enabling adapters.\n'
  else
    printf 'CHECK_MESSAGE=Internet is still reachable after disabling adapters.\n'
  fi
  return 1
}

# Print the current reachability state without command usage text.
print_current_status() {
  local os="$1"

  if has_internet "$os"; then
    say "Status: Internet is reachable by ping."
  else
    say "Status: Internet is not reachable by ping."
  fi
}

# Show the lightweight status view used when the script is called without
# arguments.
print_usage_status() {
  local os="$1"

  say "Usage: $SCRIPT_NAME off|on"
  print_current_status "$os"
}

# Render the final human-readable status report from the machine-readable
# lines produced by the platform backend and connectivity verifier.
print_status_message() {
  local action="$1"
  local result="$2"
  local status_line affected_line check_line message_line status affected check_state check_message

  status_line="$(printf '%s\n' "$result" | awk -F= '/^STATUS=/{print $2; exit}')"
  affected_line="$(printf '%s\n' "$result" | awk -F= '/^AFFECTED=/{print $2; exit}')"
  check_line="$(printf '%s\n' "$result" | awk -F= '/^CHECK=/{print $2; exit}')"
  message_line="$(printf '%s\n' "$result" | sed -n 's/^CHECK_MESSAGE=//p' | head -n 1)"
  status="${status_line:-Unknown}"
  affected="${affected_line:-not detected}"
  check_state="${check_line:-unknown}"
  check_message="${message_line:-Connectivity check unavailable.}"

  if [ "$action" = "off" ]; then
    say "Action: Network adapters disabled."
  else
    say "Action: Network adapters enabled."
  fi
  say "Adapters: $affected"
  say "Adapter state: $status"
  if [ "$check_state" = "ok" ]; then
    say "Internet check: $check_message"
  else
    say "Internet check: WARNING - $check_message"
  fi
}

# Persist output for the unelevated parent process when the Windows path
# had to re-launch itself via UAC.
write_result_file() {
  local file_path="$1"
  local content="$2"

  [ -n "$file_path" ] || return 0
  printf '%s\n' "$content" >"$file_path"
}

main() {
  local os action result final_output result_file=""
  local elevated=0

  os="$(detect_os)"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      off|on|OFF|ON)
        action="$(normalize_action "$1")"
        shift
        ;;
      --elevated)
        elevated=1
        shift
        ;;
      --result-file)
        [ "$#" -ge 2 ] || die "missing value for --result-file."
        result_file="$2"
        shift 2
        ;;
      *)
        die "please use 'off' or 'on'."
        ;;
    esac
  done

  if [ -z "${action:-}" ]; then
    print_usage_status "$os"
    exit 0
  fi

  case "$os" in
    windows)
      if [ "$elevated" -ne 1 ] && ! ensure_windows_admin; then
        windows_request_elevation "$action"
      fi
      result="$(windows_apply "$action")" || exit 1
      ;;
    linux)
      result="$(linux_apply "$action")" || exit 1
      ;;
    macos)
      result="$(macos_apply "$action")" || exit 1
      ;;
  esac

  result="$(printf '%s\n%s\n' "$result" "$(verify_connectivity "$os" "$action")")"
  final_output="$(
    {
      print_status_message "$action" "$result"
      print_current_status "$os"
    }
  )"
  printf '%s\n' "$final_output"

  if [ -n "$result_file" ]; then
    write_result_file "$result_file" "$final_output"
  fi
}

main "$@"
