#!/usr/bin/env bash
set -euo pipefail

# scripts/build.sh: Builds the Release configuration of ClipText and packages the app bundle.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
DERIVED_DATA_DIR="${BUILD_DIR}/DerivedData"
RELEASE_DIR="${BUILD_DIR}/Release"
APP_NAME="ClipText.app"
ENTITLEMENTS="${REPO_ROOT}/ClipText/ClipText.entitlements"

# 1. Determine code signing identity:
#    - CLIPTEXT_SIGNING_IDENTITY: explicit Apple Development identity for Team B6537Y9X84.
#    - Auto-discovery: search Keychain for that team's Apple Development identity.
#    - No ad-hoc fallback: changing to an ad-hoc designated requirement loses TCC grants.
SIGNING_IDENTITY=""
EXPECTED_TEAM_ID="B6537Y9X84"

if [[ -n "${CLIPTEXT_SIGNING_IDENTITY:-}" ]]; then
  SIGNING_IDENTITY="${CLIPTEXT_SIGNING_IDENTITY}"
  if [[ "${SIGNING_IDENTITY}" == "-" || "${SIGNING_IDENTITY}" != Apple\ Development:* || "${SIGNING_IDENTITY}" != *"(${EXPECTED_TEAM_ID})"* ]]; then
    echo "Error: CLIPTEXT_SIGNING_IDENTITY must be an Apple Development identity for team ${EXPECTED_TEAM_ID}." >&2
    exit 1
  fi
  echo "==> Using signing identity from CLIPTEXT_SIGNING_IDENTITY: ${SIGNING_IDENTITY}"
else
  DETECTED_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development:.*(${EXPECTED_TEAM_ID})" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
  if [[ -n "${DETECTED_IDENTITY}" ]]; then
    SIGNING_IDENTITY="${DETECTED_IDENTITY}"
    echo "==> Discovered local signing identity: ${SIGNING_IDENTITY}"
  else
    echo "Error: No Apple Development identity for team ${EXPECTED_TEAM_ID} is installed." >&2
    echo "Install the intended development certificate, then rerun this script." >&2
    exit 1
  fi
fi

echo "==> Building ClipText (Release)..."
mkdir -p "${BUILD_DIR}"

xcodebuild \
  -project "${REPO_ROOT}/ClipText.xcodeproj" \
  -scheme ClipText \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "${DERIVED_DATA_DIR}" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY="${SIGNING_IDENTITY}" \
  build

BUILT_APP="${DERIVED_DATA_DIR}/Build/Products/Release/${APP_NAME}"
if [[ ! -d "${BUILT_APP}" ]]; then
  echo "Error: Expected built application bundle at ${BUILT_APP} was not found." >&2
  exit 1
fi

echo "==> Packaging application bundle into ${RELEASE_DIR}/${APP_NAME}..."
if [[ "${RELEASE_DIR}" != "${REPO_ROOT}/build/Release" ]]; then
  echo "Error: Refusing to clean unexpected release path: ${RELEASE_DIR}" >&2
  exit 1
fi
rm -rf "${RELEASE_DIR}"
mkdir -p "${RELEASE_DIR}"
cp -R "${BUILT_APP}" "${RELEASE_DIR}/${APP_NAME}"

# Preserve Xcode's certificate-based signature. Re-signing the copied bundle risks
# changing the designated requirement and invalidating existing TCC authorization.

echo "==> Verifying local signature..."
codesign -v --deep --strict "${RELEASE_DIR}/${APP_NAME}"

SIGNING_INFO=$(codesign -dvvv "${RELEASE_DIR}/${APP_NAME}" 2>&1)
AUTHORITY=$(echo "${SIGNING_INFO}" | grep "Authority=" | head -n 1 | cut -d= -f2 || true)
TEAM_ID=$(echo "${SIGNING_INFO}" | grep "TeamIdentifier=" | head -n 1 | cut -d= -f2 || true)
DESIGNATED_REQ=$(codesign -dr - "${RELEASE_DIR}/${APP_NAME}" 2>&1 | tail -n 1)

echo "==> Successfully built and packaged local bundle at: ${RELEASE_DIR}/${APP_NAME}"
if [[ "${TEAM_ID}" == "${EXPECTED_TEAM_ID}" ]] && echo "${AUTHORITY}" | grep -q '^Apple Development'; then
  echo "    Signing Authority: ${AUTHORITY}"
  echo "    Team Identifier:   ${TEAM_ID}"
  echo "    Designated Req:    ${DESIGNATED_REQ}"
  echo "    Note: App is signed with a stable Apple Development identity. TCC permissions will persist across rebuilds."
else
  echo "Error: Built app does not have the expected Apple Development signature for team ${EXPECTED_TEAM_ID}." >&2
  exit 1
fi
