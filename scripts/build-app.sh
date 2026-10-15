#!/bin/zsh
set -eu
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app_dir="$project_dir/build/Display Desk.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/DisplayDesk" "$app_dir/Contents/MacOS/DisplayDesk"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
for license_file in "$project_dir"/Resources/*LICENSE.txt; do
  cp "$license_file" "$app_dir/Contents/Resources/"
done
swift -module-cache-path "$project_dir/.build/icon-module-cache" "$project_dir/scripts/make-icon.swift" "$app_dir/Contents/Resources"
iconutil -c icns "$app_dir/Contents/Resources/AppIcon.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
rm -rf "$app_dir/Contents/Resources/AppIcon.iconset"
codesign --force --sign - "$app_dir"
print -r -- "Built: $app_dir"
