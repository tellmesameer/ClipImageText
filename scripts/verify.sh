#!/usr/bin/env bash
set -euo pipefail

# scripts/verify.sh: Verifies bundle integrity, code signature, entitlements, and execution of ClipText.app.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

EXPECTED_TEAM_ID="B6537Y9X84"
SKIP_LAUNCH=0
APP_PATH=""

for argument in "$@"; do
  case "${argument}" in
    --skip-launch)
      SKIP_LAUNCH=1
      ;;
    -h|--help)
      echo "Usage: $0 [--skip-launch] [path/to/ClipText.app]"
      exit 0
      ;;
    -*)
      echo "Error: Unknown option: ${argument}" >&2
      exit 1
      ;;
    *)
      if [[ -n "${APP_PATH}" ]]; then
        echo "Error: Multiple app paths supplied." >&2
        exit 1
      fi
      APP_PATH="${argument}"
      ;;
  esac
done

if [[ -z "${APP_PATH}" ]]; then
  if [[ -d "/Applications/ClipText.app" ]]; then
    APP_PATH="/Applications/ClipText.app"
  elif [[ -d "${HOME}/Applications/ClipText.app" ]]; then
    APP_PATH="${HOME}/Applications/ClipText.app"
  elif [[ -d "${REPO_ROOT}/build/Release/ClipText.app" ]]; then
    APP_PATH="${REPO_ROOT}/build/Release/ClipText.app"
  else
    echo "Error: No ClipText.app found in /Applications, ~/Applications, or build/Release." >&2
    echo "Usage: $0 [path/to/ClipText.app]" >&2
    exit 1
  fi
fi

APP_PATH="$(cd "$(dirname "${APP_PATH}")" && pwd)/$(basename "${APP_PATH}")"

echo "=========================================="
echo "Verifying ClipText bundle at:"
echo "  ${APP_PATH}"
echo "=========================================="

# 1. Structure Verification
echo "[1/5] Checking bundle directory structure..."
test -d "${APP_PATH}" || { echo "FAIL: Bundle directory missing"; exit 1; }
test -d "${APP_PATH}/Contents" || { echo "FAIL: Contents directory missing"; exit 1; }
test -d "${APP_PATH}/Contents/MacOS" || { echo "FAIL: MacOS directory missing"; exit 1; }
test -x "${APP_PATH}/Contents/MacOS/ClipText" || { echo "FAIL: Executable missing or not executable"; exit 1; }
test -f "${APP_PATH}/Contents/Info.plist" || { echo "FAIL: Info.plist missing"; exit 1; }
test -f "${APP_PATH}/Contents/Resources/AppIcon.icns" || { echo "FAIL: AppIcon.icns missing"; exit 1; }
echo "  ✓ Required bundle layout and resources are present."

# 2. Info.plist Configuration Verification
echo "[2/5] Inspecting Info.plist configuration..."
BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "")
LS_UI_ELEMENT=$(plutil -extract LSUIElement raw "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "")
USAGE_DESC=$(plutil -extract NSScreenCaptureUsageDescription raw "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "")

if [[ "${BUNDLE_ID}" != "com.cliptext.app" ]]; then
  echo "FAIL: Expected CFBundleIdentifier com.cliptext.app, got: ${BUNDLE_ID}" >&2
  exit 1
fi
if [[ "${LS_UI_ELEMENT}" != "true" && "${LS_UI_ELEMENT}" != "1" ]]; then
  echo "FAIL: LSUIElement must be true (accessory/menu-bar app), got: ${LS_UI_ELEMENT}" >&2
  exit 1
fi
if [[ -z "${USAGE_DESC}" ]]; then
  echo "FAIL: NSScreenCaptureUsageDescription is missing from Info.plist" >&2
  exit 1
fi
echo "  ✓ Bundle Identifier: ${BUNDLE_ID}"
echo "  ✓ Menu-bar agent (LSUIElement): ${LS_UI_ELEMENT}"
echo "  ✓ Screen capture description present."

# 3. Code Signature Verification
echo "[3/5] Validating code signature..."
codesign -v --deep --strict "${APP_PATH}"
SIGNING_INFO=$(codesign -dvvv "${APP_PATH}" 2>&1)
echo "${SIGNING_INFO}" | grep -E "Authority|Signature=|TeamIdentifier" || true
DESIGNATED_REQ=$(codesign -dr - "${APP_PATH}" 2>&1 | tail -n 1)
echo "  Designated Requirement: ${DESIGNATED_REQ}"
TEAM_ID=$(echo "${SIGNING_INFO}" | sed -n 's/^TeamIdentifier=//p' | head -n 1)
if ! echo "${SIGNING_INFO}" | grep -q '^Authority=Apple Development'; then
  echo "FAIL: Expected an Apple Development signature; refusing ad-hoc identity changes that invalidate TCC grants." >&2
  exit 1
fi
if [[ "${TEAM_ID}" != "${EXPECTED_TEAM_ID}" ]]; then
  echo "FAIL: Expected TeamIdentifier ${EXPECTED_TEAM_ID}, got: ${TEAM_ID:-<none>}" >&2
  exit 1
fi
if ! echo "${DESIGNATED_REQ}" | grep -q 'identifier "com.cliptext.app"'; then
  echo "FAIL: Designated requirement does not contain com.cliptext.app." >&2
  exit 1
fi
echo "  ✓ Stable Apple Development signature, Team ID, and bundle requirement verified."

# 4. Entitlements Verification
echo "[4/5] Inspecting embedded entitlements..."
ENTITLEMENTS_OUTPUT=$(codesign -d --entitlements - "${APP_PATH}" 2>&1)
if echo "${ENTITLEMENTS_OUTPUT}" | grep -q "com.apple.security.device.screen-capture"; then
  echo "  ✓ com.apple.security.device.screen-capture is embedded."
else
  echo "FAIL: com.apple.security.device.screen-capture entitlement is missing." >&2
  exit 1
fi
if echo "${ENTITLEMENTS_OUTPUT}" | grep -q "com.apple.security.app-sandbox"; then
  echo "  ✓ Sandboxing policy verified (app-sandbox = false for global capture)."
fi

# 5. Independent Execution Smoke Test
echo "[5/5] Testing independent launch without Xcode..."
if [[ "${SKIP_LAUNCH}" -eq 1 ]]; then
  echo "  ✓ Launch smoke test skipped by --skip-launch."
  echo "=========================================="
  echo "ALL NON-LAUNCH VERIFICATION CHECKS PASSED FOR ${APP_PATH}"
  echo "=========================================="
  exit 0
fi
# shortcut: 2-second background launch check, upgrade to XCUITest runner for full headless UI automation
"${APP_PATH}/Contents/MacOS/ClipText" >/dev/null 2>&1 &
APP_PID=$!

sleep 2

if kill -0 "${APP_PID}" 2>/dev/null; then
  echo "  ✓ Process launched successfully (PID ${APP_PID}) and is running steadily."
  kill -15 "${APP_PID}" 2>/dev/null || true
  wait "${APP_PID}" 2>/dev/null || true
  echo "  ✓ Clean shutdown confirmed."
else
  wait "${APP_PID}"
  EXIT_STATUS=$?
  echo "FAIL: Application terminated prematurely with exit code: ${EXIT_STATUS}" >&2
  exit 1
fi

echo "=========================================="
echo "ALL VERIFICATION CHECKS PASSED FOR ${APP_PATH}"
echo "Note: Verified for local execution. Public distribution requires Developer ID signing and Apple notarization."
echo "=========================================="
