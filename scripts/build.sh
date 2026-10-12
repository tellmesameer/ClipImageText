#!/usr/bin/env bash
set -euo pipefail

# scripts/build.sh: Builds the Release configuration of ClipText and packages the app bundle.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
DERIVED_DATA_DIR="${BUILD_DIR}/DerivedData"
RELEASE_DIR="${BUILD_DIR}/Release"
APP_NAME="ClipText.app"
ENTITLEMENTS="${REPO_ROOT}/ClipText/ClipText.entitlements"

echo "==> Building ClipText (Release)..."
mkdir -p "${BUILD_DIR}"

xcodebuild \
  -project "${REPO_ROOT}/ClipText.xcodeproj" \
  -scheme ClipText \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "${DERIVED_DATA_DIR}" \
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

echo "==> Applying local development code signature (ad-hoc) with entitlements..."
# shortcut: ad-hoc signature with embedded entitlements for local dev, upgrade to Developer ID Application for public distribution
codesign --force --deep --sign - --entitlements "${ENTITLEMENTS}" "${RELEASE_DIR}/${APP_NAME}"

echo "==> Verifying local signature..."
codesign -v --deep --strict "${RELEASE_DIR}/${APP_NAME}"

echo "==> Successfully built and packaged local development bundle at: ${RELEASE_DIR}/${APP_NAME}"
echo "    Note: App is signed locally (ad-hoc). It is NOT Developer ID signed or notarized."
