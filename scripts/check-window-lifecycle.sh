#!/bin/zsh
set -eu
cd "${0:A:h:h}"
check_dir="$(mktemp -d /tmp/displaydesk-window-check.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
swiftc -swift-version 6 -module-cache-path /tmp/displaydesk-module-cache \
  Sources/DisplayDesk/WindowPresentation.swift Tests/DisplayDeskAppChecks/WindowLifecycleChecks.swift \
  -o "$check_dir/window-check"
python3 - "$check_dir/window-check" <<'PYTIMEOUT'
import subprocess
import sys
try:
    result = subprocess.run([sys.argv[1]], timeout=15)
    sys.exit(result.returncode if result.returncode >= 0 else 1)
except subprocess.TimeoutExpired:
    print("FAIL: window lifecycle check exceeded 15 seconds and was stopped.", file=sys.stderr)
    sys.exit(1)
PYTIMEOUT
