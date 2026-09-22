#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
project_directory="${script_directory:h}"
staging_directory="$(mktemp -d /tmp/usagerail-release.XXXXXX)"
mv "$staging_directory" "$staging_directory.noindex"
staging_directory="$staging_directory.noindex"
build_directory="$staging_directory/build"
staged_application="$staging_directory/UsageRail.app"
# Retain evidence and artifacts on success or failure. Never remove an old app.
trap 'echo "Staging retained: $staging_directory" >&2' EXIT

cd "$project_directory"
# Record source paths relative to the project, so the app never embeds your home folder.
swift build -c release --scratch-path "$build_directory" \
    -Xswiftc -file-prefix-map -Xswiftc "$project_directory=UsageRail"
mkdir -p "$staged_application/Contents/MacOS" "$staged_application/Contents/Resources"
cp -X "$build_directory/release/UsageRail" "$build_directory/release/UsageBridge" "$staged_application/Contents/MacOS/"
cp -X Resources/Info.plist "$staged_application/Contents/"
cp -X Resources/higgsfield-icon.png "$staged_application/Contents/Resources/"
if xattr -lr "$staged_application" 2>/dev/null | /usr/bin/grep -q 'com.apple.quarantine'; then
    echo "Quarantined build input; no attributes changed" >&2
    exit 1
fi
codesign --force --deep --sign - --options runtime "$staged_application"
codesign --verify --deep --strict --verbose=2 "$staged_application"
echo "$staged_application"
echo "Build only: validate before a separate recoverable installation. No ZIP or installed app was changed."
