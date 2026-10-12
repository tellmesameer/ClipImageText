#!/usr/bin/env bash
set -euo pipefail

# scripts/package.sh: Packages ClipText into a standalone Release app bundle and distribution archive.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DIR="${REPO_ROOT}/build/Release"
APP_PATH="${RELEASE_DIR}/ClipText.app"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "==> App bundle not found, invoking build.sh..."
  "${REPO_ROOT}/scripts/build.sh"
fi

VERSION=$(plutil -extract CFBundleShortVersionString raw "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "1.0")
ARCHIVE_PATH="${REPO_ROOT}/build/ClipText-${VERSION}.zip"

echo "==> Creating release archive ${ARCHIVE_PATH}..."
rm -f "${ARCHIVE_PATH}"
(cd "${RELEASE_DIR}" && zip -q -r -y "${ARCHIVE_PATH}" "ClipText.app")

echo "==> Packaging complete:"
echo "    App bundle: ${APP_PATH}"
echo "    Zip archive: ${ARCHIVE_PATH}"
echo "    Note: Archive contains a locally signed development build. For public distribution, Developer ID signing and Apple notarization are required."
