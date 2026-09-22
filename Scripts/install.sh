#!/bin/zsh
# Builds UsageRail from source and installs it for the current user.
#   ./Scripts/install.sh
# Re-run it to update: the previous copy is moved to the Trash, never deleted.
set -euo pipefail

script_directory="${0:A:h}"

if [[ "$(uname -s)" != Darwin ]]; then
    echo "UsageRail is a macOS app." >&2; exit 1
fi
macos_version="$(sw_vers -productVersion)"
if (( ${macos_version%%.*} < 26 )); then
    echo "UsageRail needs macOS 26 or later; this Mac runs $macos_version." >&2; exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
    echo "Swift wasn't found. Install Xcode 26, or run: xcode-select --install" >&2; exit 1
fi

echo "Building UsageRail (the first build takes a minute or two)…"
if ! built="$("$script_directory/build-release.sh" 2>/dev/null | grep -E '/UsageRail\.app$' | tail -n 1)" \
    || [[ -z "$built" || ! -d "$built" ]]; then
    echo "The build failed. Run ./Scripts/build-release.sh to see the error." >&2; exit 1
fi

if [[ -w /Applications ]]; then destination=/Applications; else destination="$HOME/Applications"; fi
mkdir -p "$destination"
target="$destination/UsageRail.app"

# Quit a running copy so the new one can take its place.
if pgrep -x UsageRail >/dev/null 2>&1; then
    osascript -e 'tell application id "com.usagerail.app" to quit' >/dev/null 2>&1 || true
    for _ in {1..20}; do
        pgrep -x UsageRail >/dev/null 2>&1 || break
        sleep 0.25
    done
fi

if [[ -d "$target" ]]; then
    mv "$target" "$HOME/.Trash/UsageRail $(date '+%Y-%m-%d %H.%M.%S').app"
    echo "Moved the previous UsageRail to the Trash."
fi
ditto "$built" "$target"
# The staging folder belongs to this build only.
[[ "${built:h}" == /tmp/usagerail-release.*.noindex ]] && rm -rf "${built:h}"

open "$target"
echo "Installed $target. Settings opens so you can connect your providers."
