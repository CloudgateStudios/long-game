#!/bin/sh
# Xcode Cloud runs this after cloning the repository. Config/Local.xcconfig is not
# committed, so this writes it from environment variables set on the Xcode Cloud workflow.
set -eu

for name in DEVELOPMENT_TEAM LG_BUNDLE_ID LG_ICLOUD_CONTAINER; do
    if [ -z "$(printenv "$name" || true)" ]; then
        echo "error: set the $name environment variable on the Xcode Cloud workflow" >&2
        exit 1
    fi
done

# Xcode Cloud archives are distribution builds, which always use CloudKit Production.
cat > "$CI_PRIMARY_REPOSITORY_PATH/Config/Local.xcconfig" <<XCCONFIG
DEVELOPMENT_TEAM = $DEVELOPMENT_TEAM
LG_BUNDLE_ID = $LG_BUNDLE_ID
LG_ICLOUD_CONTAINER = $LG_ICLOUD_CONTAINER
LG_ICLOUD_ENVIRONMENT = Production
XCCONFIG

echo "Wrote Config/Local.xcconfig"
