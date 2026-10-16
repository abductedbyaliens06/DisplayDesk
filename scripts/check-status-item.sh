#!/bin/zsh
set -eu
cd "${0:A:h:h}"
swift build
binary_dir="$(swift build --show-bin-path)"
check_dir="$(mktemp -d /tmp/displaydesk-status-check.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
sources=(Sources/DisplayDesk/*.swift)
sources=(${sources:#*/DisplayDeskApp.swift})
swiftc -swift-version 6 -target "$(uname -m)-apple-macosx26.0" \
  -module-cache-path /tmp/displaydesk-module-cache \
  -I "$binary_dir" -I "$binary_dir/Modules" \
  "${sources[@]}" Tests/DisplayDeskAppChecks/StatusItemChecks.swift \
  "$binary_dir/DisplayDeskCore.o" "$binary_dir/MacBrightnessKit.o" \
  -o "$check_dir/status-item-checks"
python3 - "$check_dir/status-item-checks" <<'PYTIMEOUT'
import subprocess
import sys
try:
    result = subprocess.run([sys.argv[1]], timeout=15)
    sys.exit(result.returncode if result.returncode >= 0 else 1)
except subprocess.TimeoutExpired:
    print("FAIL: native status-item checks timed out and were stopped.", file=sys.stderr)
    sys.exit(1)
PYTIMEOUT
