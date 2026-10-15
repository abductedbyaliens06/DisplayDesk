#!/bin/zsh
set -eu
cd "${0:A:h:h}"
check_dir="$(mktemp -d /tmp/displaydesk-window-check.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
swiftc -swift-version 6 -module-cache-path /tmp/displaydesk-module-cache \
  Sources/DisplayDesk/WindowPresentation.swift Tests/DisplayDeskAppChecks/WindowLifecycleChecks.swift \
  -o "$check_dir/window-check"
"$check_dir/window-check"
