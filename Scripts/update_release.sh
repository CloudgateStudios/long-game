#!/bin/sh
# Ships what is on main: checks it is safe to release, then moves the release branch to
# main, which starts the Xcode Cloud build for TestFlight. The Update Release Branch
# workflow in GitHub Actions runs this.
#
#   sh Scripts/update_release.sh
#
# Run from the project root on an up-to-date main. Needs what Scripts/cloudkit_schema.sh
# needs.
set -eu

git fetch --quiet origin main release
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || {
    echo "error: check out main and pull first, so the checks run on what will ship." >&2
    exit 1
}
if [ "$(git rev-parse origin/release)" = "$(git rev-parse origin/main)" ]; then
    echo "release already points at main. Nothing to do."
    exit 0
fi
git merge-base --is-ancestor origin/release origin/main || {
    echo "error: release has commits that are not on main. Sort that out first." >&2
    exit 1
}

# A release that is ahead of the schema in CloudKit Production cannot sync.
sh Scripts/cloudkit_schema.sh check

git push --quiet origin origin/main:refs/heads/release
echo "release now points at $(git rev-parse --short origin/main). Xcode Cloud takes it from here."
