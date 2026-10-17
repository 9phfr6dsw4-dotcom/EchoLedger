#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGED_APP="$ROOT_DIR/dist/verify-extracted/EchoLedger.app"
BUILD_DIR="$ROOT_DIR/.build"
BUILD_BACKUP="$ROOT_DIR/.build-smoke-test-backup.$$"
SMOKE_PARENT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"

if [[ ! -d "$PACKAGED_APP" ]]; then
    printf 'Extracted packaged app does not exist: %s\n' "$PACKAGED_APP" >&2
    exit 1
fi
test -x "$PACKAGED_APP/Contents/MacOS/EchoLedger"
test -s "$PACKAGED_APP/Contents/Resources/AppIcon.icns"
test -s "$PACKAGED_APP/Contents/Resources/EchoLedger_EchoLedgerCore.bundle/MerchantIcons/spotify.png"

mkdir -p "$SMOKE_PARENT"
SMOKE_DIR="$(mktemp -d "$SMOKE_PARENT/echoledger-smoke.XXXXXX")"
SMOKE_APP="$SMOKE_DIR/EchoLedger.app"
CHECK_OUTPUT="$ROOT_DIR/dist/packaged-app-check"
rm -rf "$CHECK_OUTPUT"
mkdir -p "$CHECK_OUTPUT"

echo 'Copying the extracted release app to a clean temporary location.'
ditto "$PACKAGED_APP" "$SMOKE_APP"

cleanup() {
    status=$?
    trap - EXIT
    pkill -x EchoLedger >/dev/null 2>&1 || true
    if [[ -d "$BUILD_BACKUP" ]]; then
        rm -rf "$BUILD_DIR"
        mv "$BUILD_BACKUP" "$BUILD_DIR"
    fi
    rm -rf "$SMOKE_DIR"
    exit "$status"
}
trap cleanup EXIT

if [[ -e "$BUILD_BACKUP" ]]; then
    printf 'Refusing to overwrite stale build backup: %s\n' "$BUILD_BACKUP" >&2
    exit 1
fi
if [[ -e "$BUILD_DIR" ]]; then
    mv "$BUILD_DIR" "$BUILD_BACKUP"
fi
if [[ -e "$BUILD_DIR" ]]; then
    printf 'Build directory is still present; refusing an unisolated launch test.\n' >&2
    exit 1
fi

printf 'Build directory is unavailable; launching extracted app from %s\n' "$SMOKE_APP"
open -n -g "$SMOKE_APP" --args --demo --check-package --check-output "$CHECK_OUTPUT"

for _ in {1..60}; do
    if [[ -s "$CHECK_OUTPUT/failed.txt" ]]; then
        cat "$CHECK_OUTPUT/failed.txt" >&2
        exit 1
    fi
    if [[ -s "$CHECK_OUTPUT/completed.json" ]]; then
        pgrep -x EchoLedger >/dev/null
        python3 - "$CHECK_OUTPUT" <<'PY'
import json, pathlib, sys
folder = pathlib.Path(sys.argv[1])
result = json.loads((folder / 'completed.json').read_text())
assert result['status'] == 'passed' and result['brands'] > 3000
assert result['section'] == 'transactions' and result['pdfStyles'] == 3
for name in ['transactions.png', 'signature.pdf', 'everyday.pdf', 'precision.pdf']:
    assert (folder / name).stat().st_size > 0, name
print('Installed app rendered Transactions, loaded merchant icons, and exported all three PDF styles without .build.')
PY
        exit 0
    fi
    sleep 1
done

printf 'EchoLedger did not complete its installed-app merchant and PDF checks without the build directory.\n' >&2
exit 1
