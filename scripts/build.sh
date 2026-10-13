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
#    - CLIPTEXT_SIGNING_IDENTITY: explicit environment override (e.g. "Apple Development: ...", or "-" for ad-hoc).
#    - Auto-discovery: search Keychain for a valid Apple Development or Apple Developer identity.
#    - Fallback: "-" (ad-hoc signing) for CI runners or machines without signing certificates.
SIGNING_IDENTITY=""
SIGNING_TYPE=""

if [[ -n "${CLIPTEXT_SIGNING_IDENTITY:-}" ]]; then
  SIGNING_IDENTITY="${CLIPTEXT_SIGNING_IDENTITY}"
  if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
    SIGNING_TYPE="ad-hoc (override)"
  else
    SIGNING_TYPE="explicit override"
  fi
  echo "==> Using signing identity from CLIPTEXT_SIGNING_IDENTITY: ${SIGNING_IDENTITY} (${SIGNING_TYPE})"
else
  DETECTED_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -E 'Apple Development:|Apple Developer:' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
  if [[ -n "${DETECTED_IDENTITY}" ]]; then
    SIGNING_IDENTITY="${DETECTED_IDENTITY}"
    SIGNING_TYPE="auto-detected Apple Development"
    echo "==> Discovered local signing identity: ${SIGNING_IDENTITY}"
  else
    SIGNING_IDENTITY="-"
    SIGNING_TYPE="ad-hoc fallback (no cert found)"
    echo "==> No Apple Development identity found in keychain; falling back to ad-hoc signing (-)"
  fi
fi

if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
  XCODE_CODE_SIGN_IDENTITY="-"
else
  # Xcode automatic signing requires the generic type "Apple Development"
  XCODE_CODE_SIGN_IDENTITY="Apple Development"
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
  CODE_SIGN_IDENTITY="${XCODE_CODE_SIGN_IDENTITY}" \
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

if [[ "${SIGNING_IDENTITY}" != "-" ]]; then
  echo "==> Applying stable Apple Development code signature with entitlements..."
  codesign --force --deep --sign "${SIGNING_IDENTITY}" --entitlements "${ENTITLEMENTS}" --timestamp=none "${RELEASE_DIR}/${APP_NAME}"
else
  echo "==> Applying ad-hoc code signature with entitlements..."
  codesign --force --deep --sign - --entitlements "${ENTITLEMENTS}" "${RELEASE_DIR}/${APP_NAME}"
fi

echo "==> Verifying local signature..."
codesign -v --deep --strict "${RELEASE_DIR}/${APP_NAME}"

SIGNING_INFO=$(codesign -dvvv "${RELEASE_DIR}/${APP_NAME}" 2>&1)
AUTHORITY=$(echo "${SIGNING_INFO}" | grep "Authority=" | head -n 1 | cut -d= -f2 || true)
TEAM_ID=$(echo "${SIGNING_INFO}" | grep "TeamIdentifier=" | head -n 1 | cut -d= -f2 || true)
DESIGNATED_REQ=$(codesign -dr - "${RELEASE_DIR}/${APP_NAME}" 2>&1 | tail -n 1)

echo "==> Successfully built and packaged local bundle at: ${RELEASE_DIR}/${APP_NAME}"
if [[ -n "${AUTHORITY}" ]]; then
  echo "    Signing Authority: ${AUTHORITY}"
  echo "    Team Identifier:   ${TEAM_ID}"
  echo "    Designated Req:    ${DESIGNATED_REQ}"
  echo "    Note: App is signed with a stable Apple Development identity. TCC permissions will persist across rebuilds."
else
  echo "    Note: App is signed locally (ad-hoc). It is NOT Developer ID signed or notarized."
fi
