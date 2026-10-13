#!/bin/sh
# Raises the app's version number in project.yml and the Xcode project, and prints the new
# version. It only edits the two files; committing is up to the caller. The Version Bump
# workflow in GitHub Actions runs this and opens a pull request with the result.
#
#   sh Scripts/bump_version.sh patch|minor|major
#
# Run from the project root. Xcode Cloud sets the build number, so only the version changes.
set -eu
PROJECT_YML="project.yml"
PBXPROJ="LongGame.xcodeproj/project.pbxproj"

case "${1:-}" in
major | minor | patch) PART="$1" ;;
*)
    echo "usage: sh Scripts/bump_version.sh patch|minor|major" >&2
    exit 2
    ;;
esac
[ -f "$PROJECT_YML" ] && [ -f "$PBXPROJ" ] || { echo "error: run from the project root." >&2; exit 1; }

OLD="$(sed -n 's/^ *MARKETING_VERSION: *"\([0-9]*\.[0-9]*\.[0-9]*\)" *$/\1/p' "$PROJECT_YML")"
[ -n "$OLD" ] || { echo "error: no MARKETING_VERSION like \"1.2.3\" in $PROJECT_YML." >&2; exit 1; }
MAJOR="${OLD%%.*}"
REST="${OLD#*.}"
MINOR="${REST%%.*}"
PATCH="${REST#*.}"
case "$PART" in
major) NEW="$((MAJOR + 1)).0.0" ;;
minor) NEW="$MAJOR.$((MINOR + 1)).0" ;;
patch) NEW="$MAJOR.$MINOR.$((PATCH + 1))" ;;
esac

# The Xcode project is generated from project.yml and committed, so both carry the version.
# Written through a temporary file because sed -i differs between macOS and Linux.
replace() {
    sed "$1" "$2" > "$2.tmp" && mv "$2.tmp" "$2"
}
replace "s/^\( *MARKETING_VERSION: *\)\"$OLD\"/\1\"$NEW\"/" "$PROJECT_YML"
replace "s/MARKETING_VERSION = $OLD;/MARKETING_VERSION = $NEW;/" "$PBXPROJ"
grep -q "MARKETING_VERSION: \"$NEW\"" "$PROJECT_YML" && grep -q "MARKETING_VERSION = $NEW;" "$PBXPROJ" \
    && ! grep -q "MARKETING_VERSION = $OLD;" "$PBXPROJ" || {
    echo "error: could not set the version in both files." >&2
    exit 1
}
echo "$NEW"
