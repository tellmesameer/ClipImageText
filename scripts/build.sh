#!/usr/bin/env bash
set -euo pipefail

# scripts/build.sh: Builds, packages, and verifies ClipText.app.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
DERIVED_DATA_DIR="${BUILD_DIR}/DerivedData"
RELEASE_DIR="${BUILD_DIR}/Release"
APP_NAME="ClipText.app"
EXPECTED_TEAM_ID="9325V822RQ"
EXPECTED_BUNDLE_ID="com.cliptext.app"

# Code signing identity requirements:
# - Identity label: "Apple Development: sameer355u@gmail.com (9325V822RQ)" where 9325V822RQ is the Developer Key/Account ID.
# - Certificate Team ID (OU): In Apple Developer certificates, the Subject OU is the Apple Team ID (B6537Y9X84).
# - Xcode automatic signing requires CODE_SIGN_STYLE=Automatic, CODE_SIGN_IDENTITY="Apple Development", and
#   DEVELOPMENT_TEAM matching the certificate's Subject OU (B6537Y9X84).
# - Post-build verification validates bundle ID, codesign strict status, designated requirement, and certificate authority.

echo "==> Checking available Apple Development identities..."

VALID_IDENTITIES="$(
  security find-identity -v -p codesigning 2>/dev/null |
    sed -nE 's/^[[:space:]]*[0-9]+\)[[:space:]]+[[:xdigit:]]+[[:space:]]+"([^"]+)".*/\1/p' ||
    true
)"

SIGNING_IDENTITY=""

if [[ -n "${CLIPTEXT_SIGNING_IDENTITY:-}" ]]; then
  SIGNING_IDENTITY="${CLIPTEXT_SIGNING_IDENTITY}"

  if [[ "${SIGNING_IDENTITY}" != Apple\ Development:* ||
        "${SIGNING_IDENTITY}" != *"(${EXPECTED_TEAM_ID})" ]]; then
    echo "Error: CLIPTEXT_SIGNING_IDENTITY must be an Apple Development identity for team ${EXPECTED_TEAM_ID}." >&2
    exit 1
  fi

  if ! printf '%s\n' "${VALID_IDENTITIES}" |
       grep -Fqx -- "${SIGNING_IDENTITY}"; then
    echo "Error: The requested signing identity is not installed as a valid code-signing identity." >&2
    exit 1
  fi
else
  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] || continue

    if [[ "${candidate}" == Apple\ Development:* &&
          "${candidate}" == *"(${EXPECTED_TEAM_ID})" ]]; then
      SIGNING_IDENTITY="${candidate}"
      break
    fi
  done <<< "${VALID_IDENTITIES}"
fi

if [[ -z "${SIGNING_IDENTITY}" ]]; then
  echo "Error: No valid Apple Development identity for team ${EXPECTED_TEAM_ID} is installed." >&2
  echo "Install the intended certificate and private key, then rerun this script." >&2
  exit 1
fi

echo "==> Validated signing identity: ${SIGNING_IDENTITY}"

# Resolve the certificate's Team ID (OU field in certificate Subject) for Xcode automatic signing
CERT_TEAM_ID="$(security find-certificate -c "${SIGNING_IDENTITY}" -p 2>/dev/null | openssl x509 -noout -subject | sed -n 's/.*OU=\([^,]*\).*/\1/p' || true)"
if [[ -n "${CERT_TEAM_ID}" ]]; then
  ACTUAL_TEAM_ID="${CERT_TEAM_ID}"
else
  ACTUAL_TEAM_ID="${EXPECTED_TEAM_ID}"
fi

echo "==> Building ClipText (Release) with Team ID ${ACTUAL_TEAM_ID}..."

mkdir -p "${BUILD_DIR}"

xcodebuild \
  -project "${REPO_ROOT}/ClipText.xcodeproj" \
  -scheme ClipText \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "${DERIVED_DATA_DIR}" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" \
  DEVELOPMENT_TEAM="${ACTUAL_TEAM_ID}" \
  build

BUILT_APP="${DERIVED_DATA_DIR}/Build/Products/Release/${APP_NAME}"

if [[ ! -d "${BUILT_APP}" ]]; then
  echo "Error: Expected built application bundle was not found: ${BUILT_APP}" >&2
  exit 1
fi

# Guard the release destination before cleaning it.
EXPECTED_RELEASE_DIR="${REPO_ROOT}/build/Release"

if [[ "${RELEASE_DIR}" != "${EXPECTED_RELEASE_DIR}" ]]; then
  echo "Error: Refusing to clean unexpected release path: ${RELEASE_DIR}" >&2
  exit 1
fi

echo "==> Packaging application into ${RELEASE_DIR}/${APP_NAME}..."

rm -rf "${RELEASE_DIR}"
mkdir -p "${RELEASE_DIR}"
ditto "${BUILT_APP}" "${RELEASE_DIR}/${APP_NAME}"

PACKAGED_APP="${RELEASE_DIR}/${APP_NAME}"

# Do not re-sign the copied application. Preserve Xcode's signature.
echo "==> Verifying packaged code signature..."

codesign --verify --deep --strict --verbose=2 "${PACKAGED_APP}"

SIGNING_INFO="$(codesign -dvvv "${PACKAGED_APP}" 2>&1)"
AUTHORITY="$(
  printf '%s\n' "${SIGNING_INFO}" |
    awk '/^Authority=/ {
      print substr($0, index($0, "=") + 1)
      exit
    }'
)"
TEAM_ID="$(
  printf '%s\n' "${SIGNING_INFO}" |
    awk -F= '/^TeamIdentifier=/ { print $2; exit }'
)"
BUNDLE_ID="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleIdentifier' \
    "${PACKAGED_APP}/Contents/Info.plist" 2>/dev/null || true
)"
DESIGNATED_REQ="$(
  codesign -dr - "${PACKAGED_APP}" 2>&1 |
    awk '/^designated => / {
      sub(/^designated => /, "")
      print
      exit
    }' || true
)"

if [[ "${BUNDLE_ID}" != "${EXPECTED_BUNDLE_ID}" ]]; then
  echo "Error: Expected bundle ID ${EXPECTED_BUNDLE_ID}, got ${BUNDLE_ID:-<none>}." >&2
  exit 1
fi

if [[ "${TEAM_ID}" != "${ACTUAL_TEAM_ID}" && "${TEAM_ID}" != "${EXPECTED_TEAM_ID}" ]]; then
  echo "Error: Expected Team ID ${ACTUAL_TEAM_ID}, got ${TEAM_ID:-<none>}." >&2
  exit 1
fi

if [[ "${AUTHORITY}" != "${SIGNING_IDENTITY}" ]]; then
  echo "Error: Actual signing authority does not match the selected identity." >&2
  echo "Expected: ${SIGNING_IDENTITY}" >&2
  echo "Actual:   ${AUTHORITY:-<none>}" >&2
  exit 1
fi

if [[ "${DESIGNATED_REQ}" != *"identifier \"${EXPECTED_BUNDLE_ID}\""* ]]; then
  echo "Error: Designated requirement does not identify ${EXPECTED_BUNDLE_ID}." >&2
  echo "Actual requirement: ${DESIGNATED_REQ:-<unavailable>}" >&2
  exit 1
fi

echo
echo "==> BUILD AND SIGNATURE VERIFICATION SUCCEEDED"
echo "    Application:        ${PACKAGED_APP}"
echo "    Bundle ID:          ${BUNDLE_ID}"
echo "    Signing Authority:  ${AUTHORITY}"
echo "    Team Identifier:    ${TEAM_ID}"
echo "    Designated Req:     ${DESIGNATED_REQ}"
echo
echo "Note: When migrating from an ad-hoc signature, macOS may require"
echo "Screen Recording permission to be granted again. Subsequent builds"
echo "should use the same stable signing identity."
