#!/bin/sh
# Ships a new version: raises the version number on main, then moves the release branch to
# it, which starts the Xcode Cloud build for TestFlight. Xcode Cloud sets the build number.
#
#   sh Scripts/release.sh patch|minor|major
#
# Run from the project root with nothing uncommitted. main only takes pull requests, so the
# version change goes through one that merges itself once the checks pass. Needs the GitHub
# CLI (gh), signed in, and what Scripts/cloudkit_schema.sh needs.
set -eu
PROJECT_YML="project.yml"
PBXPROJ="LongGame.xcodeproj/project.pbxproj"
# How long to wait for the pull request's checks, in seconds.
TIMEOUT=1800

case "${1:-}" in
major | minor | patch) PART="$1" ;;
*)
    echo "usage: sh Scripts/release.sh patch|minor|major" >&2
    exit 2
    ;;
esac

[ -f "$PROJECT_YML" ] && [ -f "$PBXPROJ" ] || { echo "error: run from the project root." >&2; exit 1; }
git diff --quiet HEAD || { echo "error: commit or stash your changes first." >&2; exit 1; }

# A release that is ahead of the schema in CloudKit Production cannot sync.
sh Scripts/cloudkit_schema.sh check

git fetch --quiet origin main release
git merge-base --is-ancestor origin/release origin/main || {
    echo "error: release has commits that are not on main. Sort that out first." >&2
    exit 1
}

START="$(git symbolic-ref --quiet --short HEAD || git rev-parse HEAD)"
OLD="$(git show "origin/main:$PROJECT_YML" | sed -n 's/^ *MARKETING_VERSION: *"\([0-9]*\.[0-9]*\.[0-9]*\)" *$/\1/p')"
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
BRANCH="chore/release-$NEW"
echo "Releasing $NEW (was $OLD)"

git switch --quiet -c "$BRANCH" origin/main
# The Xcode project is generated from project.yml and committed, so both carry the version.
sed -i '' "s/^\( *MARKETING_VERSION: *\)\"$OLD\"/\1\"$NEW\"/" "$PROJECT_YML"
sed -i '' "s/MARKETING_VERSION = $OLD;/MARKETING_VERSION = $NEW;/" "$PBXPROJ"
grep -q "MARKETING_VERSION: \"$NEW\"" "$PROJECT_YML" && grep -q "MARKETING_VERSION = $NEW;" "$PBXPROJ" \
    && ! grep -q "MARKETING_VERSION = $OLD;" "$PBXPROJ" || {
    echo "error: could not set the version in both files. Left on branch $BRANCH." >&2
    exit 1
}
git commit --quiet -m "chore: release $NEW" "$PROJECT_YML" "$PBXPROJ"
git push --quiet -u origin "$BRANCH"
git switch --quiet "$START"
git branch --quiet -D "$BRANCH"

URL="$(gh pr create --base main --head "$BRANCH" --title "chore: release $NEW" \
    --body "Raises the version from $OLD to $NEW. Opened by Scripts/release.sh, which moves the release branch once this merges.")"
gh pr merge "$URL" --squash --auto
echo "Waiting for $URL to pass its checks and merge"

waited=0
while :; do
    state="$(gh pr view "$URL" --json state --jq .state)"
    [ "$state" = MERGED ] && break
    if [ "$state" = CLOSED ] || [ "$waited" -ge "$TIMEOUT" ]; then
        echo "error: $URL has not merged ($state). Nothing was released." >&2
        echo "Once it is merged, finish with: git fetch origin && git push origin origin/main:release" >&2
        exit 1
    fi
    sleep 20
    waited=$((waited + 20))
done

git fetch --quiet origin main
git push --quiet origin origin/main:refs/heads/release
git branch --quiet -dr "origin/$BRANCH" 2>/dev/null || true
echo "Released $NEW: release now points at $(git rev-parse --short origin/main). Xcode Cloud takes it from here."
