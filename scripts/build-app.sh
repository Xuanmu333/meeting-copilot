#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$project_dir/build/Meeting Copilot.app"

cd "$project_dir"
swift build -c release

mkdir -p "$app_dir/Contents/MacOS"
cp ".build/release/MeetingCopilot" "$app_dir/Contents/MacOS/MeetingCopilot"
cp "Info.plist" "$app_dir/Contents/Info.plist"

codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
