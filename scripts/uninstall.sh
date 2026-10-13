#!/usr/bin/env bash
set -euo pipefail

# scripts/uninstall.sh: Safely uninstalls ClipText, unregisters LaunchServices,
# resets system permissions (TCC), cleans caches, and optionally manages
# preferences and Keychain-backed encryption keys.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ClipText.app"
PRIMARY_BUNDLE_ID="com.cliptext.app"
DEV_BUNDLE_IDS=("com.cliptext.ClipText" "com.cliptext.ClipTextTests")

KEYCHAIN_SERVICE="com.kelsiito.clipboard.local-storage"
KEYCHAIN_ACCOUNT="aes-gcm-key-v1"

DRY_RUN=0
KEEP_DATA=0
FORCE=0
CLEAN_BUILD=0
CUSTOM_APP_PATH=""

print_usage() {
  cat <<EOF
Usage: $0 [options] [<path-to-ClipText.app>]

Safely uninstalls ClipText, unregisters it from macOS LaunchServices,
resets privacy permissions (Screen Recording, Accessibility), and
cleans application caches.

Options:
  --keep-data     PRESERVE clipboard history, preferences, and the Keychain
                  encryption key required to decrypt history. Recommended
                  when reinstalling or resetting permissions.
  --dry-run       Preview all actions and prospective deletions without
                  modifying anything on the system.
  -y, --yes,
  --force         Skip interactive confirmation prompt for permanent data
                  and Keychain destruction (non-interactive mode).
  --clean-build   Also delete local build/ directory and profiling artifacts
                  in the repository.
  -h, --help      Show this help message.

Targets:
  - If a specific <path-to-ClipText.app> is provided, only that valid bundle
    is verified and removed.
  - Otherwise, checks default installation locations:
      /Applications/ClipText.app
      ~/Applications/ClipText.app
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --keep-data)
      KEEP_DATA=1
      shift
      ;;
    -y|--yes|--force)
      FORCE=1
      shift
      ;;
    --clean-build)
      CLEAN_BUILD=1
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    -*)
      echo "Error: Unknown option '$1'" >&2
      print_usage
      exit 1
      ;;
    *)
      if [[ -n "${CUSTOM_APP_PATH}" ]]; then
        echo "Error: Multiple target application paths specified ('${CUSTOM_APP_PATH}' and '$1')" >&2
        print_usage
        exit 1
      fi
      CUSTOM_APP_PATH="$1"
      shift
      ;;
  esac
done

# Validate target application bundle strictly
validate_app_bundle() {
  local target="$1"

  if [[ -z "${target}" ]]; then
    echo "Error: Target application path cannot be empty." >&2
    return 1
  fi

  # Reject symlinks explicitly to prevent escaping target directories
  if [[ -L "${target}" ]]; then
    echo "Error: Target is a symlink, which is refused for security: ${target}" >&2
    return 1
  fi

  # Must exist and be an actual directory
  if [[ ! -e "${target}" ]]; then
    echo "Error: Target application bundle does not exist: ${target}" >&2
    return 1
  fi

  if [[ ! -d "${target}" ]]; then
    echo "Error: Target is not a directory: ${target}" >&2
    return 1
  fi

  # Must end with .app
  local trimmed="${target%/}"
  if [[ "${trimmed}" != *".app" ]]; then
    echo "Error: Target path does not end with '.app': ${target}" >&2
    return 1
  fi

  # Canonicalize path using realpath
  local canonical
  canonical="$(realpath -q "${trimmed}" 2>/dev/null || true)"
  if [[ -z "${canonical}" || ! -d "${canonical}" ]]; then
    echo "Error: Could not canonicalize target path: ${target}" >&2
    return 1
  fi

  # Refuse root, home, Applications, or repo root directories
  case "${canonical}" in
    "/"|"/Applications"|"/System"|"/Library"|"/Users"|"/Volumes"|"${HOME}"|"${HOME}/Applications"|"${REPO_ROOT}")
      echo "Error: Refusing to target protected root or parent directory: ${canonical}" >&2
      return 1
      ;;
  esac

  if [[ "${canonical}" != *".app" ]]; then
    echo "Error: Canonicalized path does not end with '.app': ${canonical}" >&2
    return 1
  fi

  # Verify bundle structure
  local info_plist="${canonical}/Contents/Info.plist"
  if [[ ! -f "${info_plist}" ]]; then
    echo "Error: Target is missing Contents/Info.plist: ${canonical}" >&2
    return 1
  fi

  if [[ ! -d "${canonical}/Contents/MacOS" ]]; then
    echo "Error: Target is missing Contents/MacOS executable directory: ${canonical}" >&2
    return 1
  fi

  # Strict CFBundleIdentifier verification
  local bundle_id
  bundle_id=$(plutil -extract CFBundleIdentifier raw "${info_plist}" 2>/dev/null || /usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "${info_plist}" 2>/dev/null || true)
  if [[ "${bundle_id}" != "${PRIMARY_BUNDLE_ID}" ]]; then
    echo "Error: CFBundleIdentifier '${bundle_id}' does not match expected '${PRIMARY_BUNDLE_ID}': ${canonical}" >&2
    return 1
  fi

  echo "${canonical}"
  return 0
}

# Verify process identity strictly to avoid terminating unrelated processes
is_cliptext_process() {
  local pid="$1"
  local proc_path
  proc_path=$(ps -p "${pid}" -o comm= 2>/dev/null || true)
  if [[ -z "${proc_path}" ]]; then
    return 1
  fi

  # 1. Executable basename must be "ClipText"
  if [[ "$(basename "${proc_path}")" != "ClipText" ]]; then
    return 1
  fi

  # 2. Check if the process executable path resides inside a ClipText.app bundle
  if [[ "${proc_path}" == *"/Contents/MacOS/ClipText" ]]; then
    local bundle_dir="${proc_path%/Contents/MacOS/ClipText}"
    local info_plist="${bundle_dir}/Contents/Info.plist"
    if [[ -f "${info_plist}" ]]; then
      local bid
      bid=$(plutil -extract CFBundleIdentifier raw "${info_plist}" 2>/dev/null || /usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "${info_plist}" 2>/dev/null || true)
      if [[ "${bid}" == "${PRIMARY_BUNDLE_ID}" || "${bid}" == "com.cliptext.ClipText" ]]; then
        return 0
      fi
    fi
  fi

  # 3. Check code signature designated requirement or bundle identifier of the binary
  local signing_info
  signing_info=$(codesign -dvvv "${proc_path}" 2>&1 || true)
  if echo "${signing_info}" | grep -q -E "Identifier=com\.cliptext\.(app|ClipText)"; then
    return 0
  fi

  return 1
}

# Phase 0: Validate arguments and determine bundles to remove
TARGETS_TO_REMOVE=()

if [[ -n "${CUSTOM_APP_PATH}" ]]; then
  echo "==> Validating custom target path: ${CUSTOM_APP_PATH}"
  VALIDATED_TARGET=$(validate_app_bundle "${CUSTOM_APP_PATH}")
  TARGETS_TO_REMOVE+=("${VALIDATED_TARGET}")
else
  DEFAULT_LOCATIONS=(
    "/Applications/${APP_NAME}"
    "${HOME}/Applications/${APP_NAME}"
  )
  for loc in "${DEFAULT_LOCATIONS[@]}"; do
    if [[ -e "${loc}" ]]; then
      if VALIDATED_LOC=$(validate_app_bundle "${loc}"); then
        TARGETS_TO_REMOVE+=("${VALIDATED_LOC}")
      else
        echo "Warning: Candidate location '${loc}' failed validation and will not be touched." >&2
      fi
    fi
  done
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "======================================================================"
  echo "==> [DRY RUN MODE ACTIVE] - No files, settings, or keys will be modified."
  echo "======================================================================"
fi

# Confirmation prompt for full destructive uninstall (if --keep-data is NOT set)
if [[ "${KEEP_DATA}" -eq 0 ]]; then
  echo ""
  echo "======================================================================"
  echo "⚠️  WARNING: PERMANENT DATA & KEYCHAIN KEY DELETION"
  echo "======================================================================"
  echo "Full uninstallation will PERMANENTLY DESTROY:"
  echo "  1. All stored clipboard history and snippets:"
  echo "     ${HOME}/Library/Application Support/clipboard"
  echo "  2. The Keychain AES-GCM encryption key required to decrypt history:"
  echo "     Service: ${KEYCHAIN_SERVICE}"
  echo "     Account: ${KEYCHAIN_ACCOUNT}"
  echo "  3. Application preferences and user settings:"
  echo "     ${HOME}/Library/Preferences/${PRIMARY_BUNDLE_ID}.plist"
  echo ""
  echo "Once the encryption key is deleted, previously encrypted clipboard"
  echo "history CAN NEVER be decrypted or recovered."
  echo ""
  echo "To uninstall the application and reset permissions while KEEPING your"
  echo "history and encryption keys safe, re-run with:"
  echo "  $0 --keep-data"
  echo "======================================================================"
  echo ""

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "[DRY RUN] In active execution mode, confirmation would be required before permanent data destruction."
  elif [[ "${FORCE}" -eq 1 ]]; then
    echo "==> Non-interactive confirmation acknowledged via --force / -y."
  elif [[ -t 0 ]]; then
    read -r -p "Type 'DELETE' to confirm permanent destruction of all clipboard history and keys: " CONFIRM_INPUT
    if [[ "${CONFIRM_INPUT}" != "DELETE" ]]; then
      echo "Aborted: Confirmation not received ('${CONFIRM_INPUT}' != 'DELETE'). No data or keys were touched." >&2
      exit 1
    fi
  else
    echo "Error: Permanent data destruction requires explicit confirmation." >&2
    echo "Run interactively in a terminal, or specify --force / -y to confirm non-interactively." >&2
    echo "Alternatively, run with --keep-data to preserve clipboard history and keys." >&2
    exit 1
  fi
fi

# 1. Terminate running ClipText processes safely
echo ""
echo "==> Step 1: Checking for active ClipText processes..."
ACTIVE_PIDS=$(pgrep -x "ClipText" 2>/dev/null || true)
FOUND_VALID_PROCS=0
if [[ -n "${ACTIVE_PIDS}" ]]; then
  for pid in ${ACTIVE_PIDS}; do
    PROC_COMM=$(ps -p "${pid}" -o comm= 2>/dev/null || true)
    if ! is_cliptext_process "${pid}"; then
      echo "    Skipping PID ${pid} (${PROC_COMM}) - not a verified ClipText binary."
      continue
    fi
    FOUND_VALID_PROCS=1
    echo "    Found verified ClipText process (PID: ${pid}, binary: ${PROC_COMM})"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "    [DRY RUN] Would terminate process PID ${pid}"
    else
      echo "    Sending SIGTERM to PID ${pid}..."
      kill -TERM "${pid}" 2>/dev/null || true
      for _ in 1 2 3; do
        if ! kill -0 "${pid}" 2>/dev/null; then break; fi
        sleep 1
      done
      if kill -0 "${pid}" 2>/dev/null; then
        echo "    Process ${pid} did not exit after SIGTERM; sending SIGKILL..."
        kill -KILL "${pid}" 2>/dev/null || true
      fi
      echo "    Process ${pid} terminated."
    fi
  done
fi
if [[ "${FOUND_VALID_PROCS}" -eq 0 ]]; then
  echo "    No active ClipText process found."
fi

# Locate lsregister tool
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ ! -x "${LSREGISTER}" ]]; then
  LSREGISTER="$(find /System/Library/Frameworks/CoreServices.framework -name lsregister 2>/dev/null | head -n 1 || true)"
fi

# 2. Unregister and delete application bundles with failure tracking
echo ""
echo "==> Step 2: Locating and removing application bundles..."
REMOVAL_FAILED=0

if [[ ${#TARGETS_TO_REMOVE[@]} -eq 0 ]]; then
  echo "    No installed ${APP_NAME} bundles found to remove."
else
  for app_path in "${TARGETS_TO_REMOVE[@]}"; do
    echo "    Target bundle: ${app_path}"

    # Re-validate immediately before unregistering or deleting
    if ! validate_app_bundle "${app_path}" >/dev/null 2>&1; then
      echo "    Error: Bundle failed secondary pre-deletion validation: ${app_path}" >&2
      REMOVAL_FAILED=1
      break
    fi

    # Unregister from LaunchServices
    if [[ -x "${LSREGISTER}" ]]; then
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo "    [DRY RUN] Would unregister from LaunchServices: ${app_path}"
      else
        if "${LSREGISTER}" -u "${app_path}" 2>/dev/null; then
          echo "    Unregistered bundle from LaunchServices database."
        else
          echo "    Warning: LaunchServices unregister returned non-zero for ${app_path}" >&2
        fi
      fi
    fi

    # Delete application bundle
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "    [DRY RUN] Would delete application bundle: ${app_path}"
    else
      rm -rf "${app_path}" 2>/dev/null || true
      if [[ -d "${app_path}" ]]; then
        # If files were locked or had immutable flags, clear flags and retry
        chflags -R nouchg,nouunlnk "${app_path}" 2>/dev/null || true
        rm -rf "${app_path}" 2>/dev/null || true
      fi

      if [[ ! -d "${app_path}" ]]; then
        echo "    Deleted application bundle: ${app_path}"
      else
        echo "    Error: Failed to remove application bundle: ${app_path}" >&2
        REMOVAL_FAILED=1
        break
      fi
    fi
  done
fi

# Abort before touching preferences, storage, or keys if any bundle failed removal
if [[ "${REMOVAL_FAILED}" -eq 1 ]]; then
  echo "" >&2
  echo "Error: Application bundle removal failed or secondary validation was unsuccessful." >&2
  echo "Aborting uninstallation before deleting preferences, clipboard history, or Keychain keys." >&2
  echo "Your data, settings, and encryption keys remain completely intact." >&2
  exit 1
fi

# 3. Reset macOS TCC Permissions (Documented policy: ScreenCapture and Accessibility)
echo ""
echo "==> Step 3: Resetting macOS TCC privacy permissions..."

reset_permission() {
  local service="$1"
  local bundle="$2"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "    [DRY RUN] Would reset TCC permission '${service}' for ${bundle}"
    return 0
  fi

  local output
  if output=$(tccutil reset "${service}" "${bundle}" 2>&1); then
    echo "    Successfully reset '${service}' for ${bundle}"
  else
    echo "    Warning: tccutil reset '${service}' for ${bundle} returned: ${output}" >&2
  fi
}

# Reset documented permissions used by ClipText
reset_permission "ScreenCapture" "${PRIMARY_BUNDLE_ID}"
reset_permission "Accessibility" "${PRIMARY_BUNDLE_ID}"

for dev_id in "${DEV_BUNDLE_IDS[@]}"; do
  reset_permission "ScreenCapture" "${dev_id}"
  reset_permission "Accessibility" "${dev_id}"
done

# 4. Remove Temporary Caches and Saved Application State
echo ""
echo "==> Step 4: Cleaning temporary caches and saved application state..."
CACHE_PATHS=(
  "${HOME}/Library/Caches/${PRIMARY_BUNDLE_ID}"
  "${HOME}/Library/Caches/${PRIMARY_BUNDLE_ID}.*"
  "${HOME}/Library/Caches/ClipText"
  "${HOME}/Library/Saved Application State/${PRIMARY_BUNDLE_ID}.savedState"
  "${HOME}/Library/HTTPStorages/${PRIMARY_BUNDLE_ID}"
  "${HOME}/Library/WebKit/${PRIMARY_BUNDLE_ID}"
)

for cpattern in "${CACHE_PATHS[@]}"; do
  for cpath in ${cpattern}; do
    if [[ -e "${cpath}" ]]; then
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo "    [DRY RUN] Would remove cache/state: ${cpath}"
      else
        if rm -rf "${cpath}" 2>/dev/null; then
          echo "    Removed cache/state: ${cpath}"
        else
          echo "    Warning: Failed to remove cache path: ${cpath}" >&2
        fi
      fi
    fi
  done
done

# 5. Preferences & Settings
echo ""
echo "==> Step 5: Managing application preferences..."
if [[ "${KEEP_DATA}" -eq 1 ]]; then
  echo "    [--keep-data active] Preserving application preferences (${PRIMARY_BUNDLE_ID})."
else
  # Delete defaults domain
  for bid in "${PRIMARY_BUNDLE_ID}" "${DEV_BUNDLE_IDS[@]}"; do
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "    [DRY RUN] Would delete defaults domain: ${bid}"
    else
      defaults delete "${bid}" 2>/dev/null || true
    fi
  done

  PREF_PLIST="${HOME}/Library/Preferences/${PRIMARY_BUNDLE_ID}.plist"
  if [[ -f "${PREF_PLIST}" ]]; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "    [DRY RUN] Would remove preference file: ${PREF_PLIST}"
    else
      if rm -f "${PREF_PLIST}"; then
        echo "    Removed preference file: ${PREF_PLIST}"
      else
        echo "    Warning: Failed to delete ${PREF_PLIST}" >&2
      fi
    fi
  fi

  # Clean test-generated preference plists
  TEST_PREFS=$(find "${HOME}/Library/Preferences" -name "ClipTextPanel*.plist" 2>/dev/null || true)
  if [[ -n "${TEST_PREFS}" ]]; then
    while IFS= read -r tpfile; do
      if [[ -f "${tpfile}" ]]; then
        if [[ "${DRY_RUN}" -eq 1 ]]; then
          echo "    [DRY RUN] Would remove test preference file: ${tpfile}"
        else
          rm -f "${tpfile}" 2>/dev/null || true
        fi
      fi
    done <<< "${TEST_PREFS}"
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      echo "    Removed test placement preference files."
    fi
  fi

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    killall cfprefsd 2>/dev/null || true
    echo "    Flushed cfprefsd preferences cache."
  fi
fi

# 6. Storage & Clipboard History
echo ""
echo "==> Step 6: Managing application storage & clipboard history..."
if [[ "${KEEP_DATA}" -eq 1 ]]; then
  echo "    [--keep-data active] Preserving encrypted clipboard history in:"
  echo "      ${HOME}/Library/Application Support/clipboard"
else
  APP_SUPPORT_PATHS=(
    "${HOME}/Library/Application Support/clipboard"
    "${HOME}/Library/Application Support/ClipText"
    "${HOME}/Library/Application Support/${PRIMARY_BUNDLE_ID}"
  )
  for aspath in "${APP_SUPPORT_PATHS[@]}"; do
    if [[ -d "${aspath}" ]]; then
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo "    [DRY RUN] Would permanently delete application storage: ${aspath}"
      else
        if rm -rf "${aspath}" 2>/dev/null; then
          echo "    Permanently deleted application storage: ${aspath}"
        else
          echo "    Warning: Failed to remove storage directory: ${aspath}" >&2
        fi
      fi
    fi
  done
fi

# 7. Keychain Encryption Key
echo ""
echo "==> Step 7: Managing Keychain encryption keys..."
if [[ "${KEEP_DATA}" -eq 1 ]]; then
  echo "    [--keep-data active] Preserving Keychain encryption key:"
  echo "      Service: ${KEYCHAIN_SERVICE}"
  echo "      Account: ${KEYCHAIN_ACCOUNT}"
else
  # Check if the specific key exists before attempting deletion
  if security find-generic-password -s "${KEYCHAIN_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" >/dev/null 2>&1; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "    [DRY RUN] Would delete Keychain generic password (service: ${KEYCHAIN_SERVICE}, account: ${KEYCHAIN_ACCOUNT})"
    else
      if security delete-generic-password -s "${KEYCHAIN_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" >/dev/null 2>&1; then
        echo "    Permanently deleted Keychain encryption key (service: ${KEYCHAIN_SERVICE}, account: ${KEYCHAIN_ACCOUNT})."
      else
        echo "    Warning: Failed to delete Keychain key (service: ${KEYCHAIN_SERVICE}, account: ${KEYCHAIN_ACCOUNT})." >&2
      fi
    fi
  else
    echo "    No ClipText encryption key found in Keychain (service: ${KEYCHAIN_SERVICE}, account: ${KEYCHAIN_ACCOUNT})."
  fi
fi

# 8. Login Items
echo ""
echo "==> Step 8: Checking login items..."
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "    [DRY RUN] Would check and remove 'ClipText' login item via AppleScript."
else
  if osascript -e 'tell application "System Events" to delete (every login item whose name is "ClipText")' 2>/dev/null; then
    echo "    Cleaned up login items for ClipText."
  fi
fi

# 9. Clean repository build artifacts (if --clean-build specified)
if [[ "${CLEAN_BUILD}" -eq 1 ]]; then
  echo ""
  echo "==> Step 9: Cleaning repository build artifacts..."
  BUILD_DIR="${REPO_ROOT}/build"
  if [[ -d "${BUILD_DIR}" ]]; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "    [DRY RUN] Would delete repository build directory: ${BUILD_DIR}"
    else
      rm -rf "${BUILD_DIR}" 2>/dev/null || true
      echo "    Removed repository build directory: ${BUILD_DIR}"
    fi
  fi
  PROFRAW_FILE="${REPO_ROOT}/default.profraw"
  if [[ -f "${PROFRAW_FILE}" ]]; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "    [DRY RUN] Would delete: ${PROFRAW_FILE}"
    else
      rm -f "${PROFRAW_FILE}" 2>/dev/null || true
      echo "    Removed ${PROFRAW_FILE}"
    fi
  fi
fi

echo ""
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "==> [DRY RUN COMPLETE] Simulation finished. No files, settings, or keys were modified."
elif [[ "${KEEP_DATA}" -eq 1 ]]; then
  echo "==> ClipText uninstallation and permission reset complete."
  echo "    Note: Encrypted clipboard history, preferences, and Keychain keys were preserved."
else
  echo "==> ClipText complete uninstallation finished."
  echo "    System state restored: Application, permissions, preferences, and data were removed."
fi
