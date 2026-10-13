#!/usr/bin/env bash
set -euo pipefail

# scripts/test_uninstall.sh: Automated safety and validation tests for scripts/uninstall.sh.
# Does NOT run against user application, user preferences, or real clipboard data.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNINSTALL_SCRIPT="${REPO_ROOT}/scripts/uninstall.sh"

TEST_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/cliptext_uninstall_test.XXXXXX")
trap 'rm -rf "${TEST_SANDBOX}"' EXIT

echo "============================================================"
echo "Running uninstall.sh Hardening and Safety Test Suite"
echo "Sandbox: ${TEST_SANDBOX}"
echo "============================================================"

PASSED_COUNT=0
FAILED_COUNT=0

assert_fails() {
  local desc="$1"
  shift
  set +e
  local output
  output=$("$@" 2>&1)
  local status=$?
  set -e
  if [[ ${status} -ne 0 ]]; then
    echo "  ✓ PASS: ${desc} (exited with ${status})"
    PASSED_COUNT=$((PASSED_COUNT + 1))
  else
    echo "  ✗ FAIL: ${desc} (expected failure but got exit 0)"
    echo "    Output was: ${output}"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
}

assert_succeeds() {
  local desc="$1"
  shift
  set +e
  local output
  output=$("$@" 2>&1)
  local status=$?
  set -e
  if [[ ${status} -eq 0 ]]; then
    echo "  ✓ PASS: ${desc}"
    PASSED_COUNT=$((PASSED_COUNT + 1))
  else
    echo "  ✗ FAIL: ${desc} (expected exit 0, got ${status})"
    echo "    Output was: ${output}"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
}

assert_output_contains() {
  local desc="$1"
  local needle="$2"
  shift 2
  local output
  output=$("$@" 2>&1 || true)
  if echo "${output}" | grep -F -q "${needle}"; then
    echo "  ✓ PASS: ${desc}"
    PASSED_COUNT=$((PASSED_COUNT + 1))
  else
    echo "  ✗ FAIL: ${desc} (expected output to contain '${needle}')"
    echo "    Actual output: ${output}"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
}

assert_output_not_contains() {
  local desc="$1"
  local needle="$2"
  shift 2
  local output
  output=$("$@" 2>&1 || true)
  if ! echo "${output}" | grep -F -q "${needle}"; then
    echo "  ✓ PASS: ${desc}"
    PASSED_COUNT=$((PASSED_COUNT + 1))
  else
    echo "  ✗ FAIL: ${desc} (output unexpectedly contained '${needle}')"
    echo "    Actual output: ${output}"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
}

echo ""
echo "--- Group 1: Argument Validation & Rejection of Invalid Targets ---"

# 1. Nonexistent path
assert_fails "Rejects nonexistent .app path" \
  "${UNINSTALL_SCRIPT}" "${TEST_SANDBOX}/NonExistent.app"

# 2. Arbitrary directory (does not end in .app)
ARBITRARY_DIR="${TEST_SANDBOX}/arbitrary_dir"
mkdir -p "${ARBITRARY_DIR}"
assert_fails "Rejects arbitrary directory not ending in .app" \
  "${UNINSTALL_SCRIPT}" "${ARBITRARY_DIR}"

# 3. Directory ending in .app but missing Contents/Info.plist
EMPTY_APP="${TEST_SANDBOX}/Empty.app"
mkdir -p "${EMPTY_APP}"
assert_fails "Rejects empty directory ending in .app (missing Info.plist)" \
  "${UNINSTALL_SCRIPT}" "${EMPTY_APP}"

# 4. Directory with Info.plist but missing Contents/MacOS
NO_MACOS_APP="${TEST_SANDBOX}/NoMacOS.app"
mkdir -p "${NO_MACOS_APP}/Contents"
cat > "${NO_MACOS_APP}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.cliptext.app</string>
</dict></plist>
EOF
assert_fails "Rejects bundle missing Contents/MacOS" \
  "${UNINSTALL_SCRIPT}" "${NO_MACOS_APP}"

# 5. Symlink to a directory
SYMLINK_APP="${TEST_SANDBOX}/Symlink.app"
ln -s "${NO_MACOS_APP}" "${SYMLINK_APP}"
assert_fails "Rejects symlink argument" \
  "${UNINSTALL_SCRIPT}" "${SYMLINK_APP}"

# 6. Wrong CFBundleIdentifier
WRONG_ID_APP="${TEST_SANDBOX}/WrongID.app"
mkdir -p "${WRONG_ID_APP}/Contents/MacOS"
cat > "${WRONG_ID_APP}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.othercompany.otherapp</string>
</dict></plist>
EOF
assert_fails "Rejects bundle with wrong CFBundleIdentifier" \
  "${UNINSTALL_SCRIPT}" "${WRONG_ID_APP}"

# 7. Refuses protected system / root directories
assert_fails "Rejects root directory (/)" \
  "${UNINSTALL_SCRIPT}" "/"
assert_fails "Rejects /Applications directly" \
  "${UNINSTALL_SCRIPT}" "/Applications"
assert_fails "Rejects home directory directly" \
  "${UNINSTALL_SCRIPT}" "${HOME}"

echo ""
echo "--- Group 2: Valid ClipText Mock Bundle & Dry-Run Guarantees ---"

# Create a valid mock ClipText bundle
VALID_MOCK_APP="${TEST_SANDBOX}/MockClipText.app"
mkdir -p "${VALID_MOCK_APP}/Contents/MacOS"
cat > "${VALID_MOCK_APP}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.cliptext.app</string>
  <key>CFBundleExecutable</key><string>ClipText</string>
</dict></plist>
EOF
touch "${VALID_MOCK_APP}/Contents/MacOS/ClipText"
chmod +x "${VALID_MOCK_APP}/Contents/MacOS/ClipText"

# Verify valid mock bundle passes validation in dry-run mode
assert_succeeds "Accepts valid mock ClipText bundle in dry-run mode" \
  "${UNINSTALL_SCRIPT}" --dry-run "${VALID_MOCK_APP}"

# Verify dry-run did not delete the bundle
if [[ -d "${VALID_MOCK_APP}" && -f "${VALID_MOCK_APP}/Contents/Info.plist" ]]; then
  echo "  ✓ PASS: Dry-run preserved mock application bundle on disk"
  PASSED_COUNT=$((PASSED_COUNT + 1))
else
  echo "  ✗ FAIL: Dry-run deleted mock application bundle!"
  FAILED_COUNT=$((FAILED_COUNT + 1))
fi

echo ""
echo "--- Group 3: --keep-data Contract & Safety Guarantees ---"

# In --keep-data mode, verify preservation notices and ensure no Keychain key deletion is prospective
assert_output_contains "--keep-data prints history preservation notice" \
  "Preserving encrypted clipboard history in:" \
  "${UNINSTALL_SCRIPT}" --dry-run --keep-data "${VALID_MOCK_APP}"

assert_output_contains "--keep-data prints Keychain key preservation notice" \
  "Preserving Keychain encryption key:" \
  "${UNINSTALL_SCRIPT}" --dry-run --keep-data "${VALID_MOCK_APP}"

assert_output_contains "--keep-data preserves exact Keychain service and account" \
  "aes-gcm-key-v1" \
  "${UNINSTALL_SCRIPT}" --dry-run --keep-data "${VALID_MOCK_APP}"

assert_output_not_contains "--keep-data never schedules deletion of Keychain key" \
  "Would delete Keychain generic password" \
  "${UNINSTALL_SCRIPT}" --dry-run --keep-data "${VALID_MOCK_APP}"

assert_output_not_contains "--keep-data never schedules deletion of application storage" \
  "Would permanently delete application storage" \
  "${UNINSTALL_SCRIPT}" --dry-run --keep-data "${VALID_MOCK_APP}"

echo ""
echo "--- Group 4: Confirmation Protection for Destructive Full-Uninstall ---"

# Non-interactive execution without --keep-data and without --force must fail safely
assert_fails "Rejects non-interactive full uninstall without --force / -y confirmation" \
  bash -c "${UNINSTALL_SCRIPT} ${VALID_MOCK_APP} < /dev/null"

# With --dry-run, explicit warning must be displayed
assert_output_contains "Displays permanent deletion warning banner" \
  "WARNING: PERMANENT DATA & KEYCHAIN KEY DELETION" \
  "${UNINSTALL_SCRIPT}" --dry-run "${VALID_MOCK_APP}"

# Ensure warning specifies exact service and account
assert_output_contains "Warning specifies exact Keychain service" \
  "com.kelsiito.clipboard.local-storage" \
  "${UNINSTALL_SCRIPT}" --dry-run "${VALID_MOCK_APP}"

assert_output_contains "Warning specifies exact Keychain account" \
  "aes-gcm-key-v1" \
  "${UNINSTALL_SCRIPT}" --dry-run "${VALID_MOCK_APP}"

echo ""
echo "--- Group 5: Removal Failure Tracking & Abort Before Data Deletion ---"

# Test that if a bundle cannot be unlinked (read-only parent directory), the script aborts
# and does NOT proceed into deleting preferences, storage, or keys.
RO_PARENT="${TEST_SANDBOX}/ro_parent"
mkdir -p "${RO_PARENT}"
FAIL_MOCK_APP="${RO_PARENT}/FailClipText.app"
mkdir -p "${FAIL_MOCK_APP}/Contents/MacOS"
cat > "${FAIL_MOCK_APP}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.cliptext.app</string>
  <key>CFBundleExecutable</key><string>ClipText</string>
</dict></plist>
EOF
touch "${FAIL_MOCK_APP}/Contents/MacOS/ClipText"
chmod +x "${FAIL_MOCK_APP}/Contents/MacOS/ClipText"

# Make both parent and bundle read-only so rm -rf cannot delete or unlink the bundle
chmod -R 555 "${RO_PARENT}"

set +e
RO_OUTPUT=$("${UNINSTALL_SCRIPT}" --force --keep-data "${FAIL_MOCK_APP}" 2>&1)
RO_STATUS=$?
set -e

if [[ ${RO_STATUS} -ne 0 ]]; then
  echo "  ✓ PASS: Aborts with non-zero exit status (${RO_STATUS}) when bundle cannot be removed"
  PASSED_COUNT=$((PASSED_COUNT + 1))
else
  echo "  ✗ FAIL: Expected failure when bundle cannot be removed, but got 0"
  FAILED_COUNT=$((FAILED_COUNT + 1))
fi

if echo "${RO_OUTPUT}" | grep -F -q "Aborting uninstallation before deleting preferences, clipboard history, or Keychain keys."; then
  echo "  ✓ PASS: Explicitly warns that removal failed and aborts before data deletion"
  PASSED_COUNT=$((PASSED_COUNT + 1))
else
  echo "  ✗ FAIL: Output did not contain expected abort warning"
  echo "    Output was: ${RO_OUTPUT}"
  FAILED_COUNT=$((FAILED_COUNT + 1))
fi

# Restore permissions for clean sandbox cleanup
chmod -R 755 "${RO_PARENT}"

echo ""
echo "--- Group 6: Documented TCC Policy & Process Identity Verification ---"

# Verify TCC reset commands in --dry-run match documented policy (ScreenCapture and Accessibility only, NO redundant 'All')
assert_output_contains "TCC policy resets ScreenCapture" \
  "Would reset TCC permission 'ScreenCapture' for com.cliptext.app" \
  "${UNINSTALL_SCRIPT}" --dry-run "${VALID_MOCK_APP}"

assert_output_contains "TCC policy resets Accessibility" \
  "Would reset TCC permission 'Accessibility' for com.cliptext.app" \
  "${UNINSTALL_SCRIPT}" --dry-run "${VALID_MOCK_APP}"

assert_output_not_contains "TCC policy does not make redundant 'All' resets" \
  "Would reset TCC permission 'All'" \
  "${UNINSTALL_SCRIPT}" --dry-run "${VALID_MOCK_APP}"

# Process verification test: start an unrelated background process named ClipText
# that is NOT in a ClipText.app bundle
( exec -a "ClipText" sleep 15 ) &
DUMMY_PID=$!
sleep 0.5

assert_output_contains "Skips terminating unrelated process merely named ClipText" \
  "not a verified ClipText binary" \
  "${UNINSTALL_SCRIPT}" --dry-run "${VALID_MOCK_APP}"

# Verify dummy process is still alive after dry-run
if kill -0 "${DUMMY_PID}" 2>/dev/null; then
  echo "  ✓ PASS: Unrelated process was NOT terminated"
  PASSED_COUNT=$((PASSED_COUNT + 1))
  kill -9 "${DUMMY_PID}" 2>/dev/null || true
  wait "${DUMMY_PID}" 2>/dev/null || true
else
  echo "  ✗ FAIL: Unrelated process was terminated!"
  FAILED_COUNT=$((FAILED_COUNT + 1))
fi

echo ""
echo "============================================================"
echo "Test Results: ${PASSED_COUNT} passed, ${FAILED_COUNT} failed"
echo "============================================================"

if [[ ${FAILED_COUNT} -ne 0 ]]; then
  exit 1
fi
