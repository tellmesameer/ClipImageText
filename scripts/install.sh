#!/usr/bin/env bash
set -euo pipefail

# scripts/install.sh: Installs or updates ClipText in /Applications or ~/Applications safely.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_APP="${REPO_ROOT}/build/Release/ClipText.app"
APP_NAME="ClipText.app"

# Parse optional arguments
TARGET_DIR=""
AUTO_RESTART=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      TARGET_DIR="${HOME}/Applications"
      shift
      ;;
    --system)
      TARGET_DIR="/Applications"
      shift
      ;;
    --launch)
      AUTO_RESTART=1
      shift
      ;;
    *)
      if [[ -z "${TARGET_DIR}" && -d "$1" ]]; then
        TARGET_DIR="$1"
        shift
      else
        echo "Usage: $0 [--user | --system | <target-directory>] [--launch]" >&2
        exit 1
      fi
      ;;
  esac
done

# If target directory wasn't explicitly chosen, default to /Applications if writable, else ~/Applications
if [[ -z "${TARGET_DIR}" ]]; then
  if [[ -w "/Applications" ]]; then
    TARGET_DIR="/Applications"
  else
    TARGET_DIR="${HOME}/Applications"
  fi
fi

# Ensure built app exists; if not, build it first
if [[ ! -d "${SOURCE_APP}" ]]; then
  echo "==> Application bundle not found at ${SOURCE_APP}. Running build.sh first..."
  "${REPO_ROOT}/scripts/build.sh"
fi

# Strict path validation
TARGET_DIR="$(cd "${TARGET_DIR%/*}" 2>/dev/null && pwd)/$(basename "${TARGET_DIR}")" || TARGET_DIR="${TARGET_DIR}"
if [[ "${TARGET_DIR}" != "/Applications" && "${TARGET_DIR}" != "${HOME}/Applications" ]]; then
  # If custom directory passed, ensure it is absolute and not root or dangerous
  if [[ "${TARGET_DIR}" == "/" || "${TARGET_DIR}" == "${HOME}" || "${TARGET_DIR}" == *"/Library"* ]]; then
    echo "Error: Refusing to install into dangerous path: ${TARGET_DIR}" >&2
    exit 1
  fi
fi

DEST_APP="${TARGET_DIR}/${APP_NAME}"

echo "==> Target installation directory: ${TARGET_DIR}"
mkdir -p "${TARGET_DIR}"

# If an older instance of ClipText is running, terminate it cleanly before replacing the binary
if pgrep -x "ClipText" >/dev/null 2>&1; then
  echo "==> Stopping running ClipText instance before updating..."
  pkill -x "ClipText" || true
  sleep 1
fi

# Safe replacement: only remove the previous .app bundle if it is an exact ClipText.app
if [[ -d "${DEST_APP}" ]]; then
  if [[ "$(basename "${DEST_APP}")" != "${APP_NAME}" ]]; then
    echo "Error: Refusing to remove destination not named ${APP_NAME}: ${DEST_APP}" >&2
    exit 1
  fi
  echo "==> Updating existing installation at ${DEST_APP} (preserving all user history & settings)..."
  rm -rf "${DEST_APP}"
else
  echo "==> Installing fresh copy to ${DEST_APP}..."
fi

cp -R "${SOURCE_APP}" "${DEST_APP}"

# Note: Automatic quarantine removal (xattr -cr) is intentionally NOT performed.
# Gatekeeper security controls are preserved. For unnotarized local builds, macOS
# may require approving first launch via right-click -> Open or System Settings.

# Re-verify code signature on destination
echo "==> Verifying signature of installed bundle..."
codesign -v --deep --strict "${DEST_APP}"

echo "==> Successfully installed ClipText at: ${DEST_APP}"
echo "    Note: User history in ~/Library/Application Support and Keychain data were preserved."

if [[ "${AUTO_RESTART}" -eq 1 ]]; then
  echo "==> Launching installed ClipText..."
  open "${DEST_APP}"
fi
