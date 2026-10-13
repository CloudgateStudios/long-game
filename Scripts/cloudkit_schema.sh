#!/bin/sh
# Keeps the CloudKit schema in the repository and checks that Production has it.
#
#   sh Scripts/cloudkit_schema.sh export   Save the Development schema to Config/CloudKitSchema.ckdb.
#   sh Scripts/cloudkit_schema.sh check    Fail unless Development and Production both match that file.
#
# Run from the project root. The team and container come from Config/Local.xcconfig. Needs a
# CloudKit management token: create one in the CloudKit Console, then run
# `xcrun cktool save-token --type management`.
set -eu
SCHEMA="Config/CloudKitSchema.ckdb"
LOCAL="Config/Local.xcconfig"

setting() {
    sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" "$LOCAL" | sed 's/[[:space:]]*$//' | tail -n 1
}

[ -f "$LOCAL" ] || { echo "error: $LOCAL not found. Run from the project root." >&2; exit 1; }
TEAM="$(setting DEVELOPMENT_TEAM)"
CONTAINER="$(setting LG_ICLOUD_CONTAINER)"
[ -n "$TEAM" ] && [ -n "$CONTAINER" ] || { echo "error: $LOCAL needs DEVELOPMENT_TEAM and LG_ICLOUD_CONTAINER." >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# fetch <environment> <file>
fetch() {
    xcrun cktool export-schema --team-id "$TEAM" --container-id "$CONTAINER" --environment "$1" --output-file "$2"
}

case "${1:-}" in
export)
    fetch development "$TMP/development.ckdb"
    # The repository is public and keeps identifiers out, so refuse a schema that names them.
    if grep -q -F -e "$TEAM" -e "$CONTAINER" "$TMP/development.ckdb"; then
        echo "error: the exported schema contains your team or container identifier; not saved." >&2
        exit 1
    fi
    cp "$TMP/development.ckdb" "$SCHEMA"
    echo "Development schema written to $SCHEMA"
    ;;
check)
    [ -f "$SCHEMA" ] || { echo "error: $SCHEMA not found. Run 'export' first." >&2; exit 1; }
    status=0
    fetch development "$TMP/development.ckdb"
    if ! diff -u "$SCHEMA" "$TMP/development.ckdb"; then
        echo "Development differs from $SCHEMA. If the models changed, write the schema with" >&2
        echo "-initializeCloudKitSchema (see README), then run 'export' and commit the file." >&2
        status=1
    fi
    fetch production "$TMP/production.ckdb"
    if ! diff -u "$TMP/production.ckdb" "$SCHEMA"; then
        echo "Production is missing the changes above. Deploy Schema Changes in the CloudKit Console" >&2
        echo "before releasing." >&2
        status=1
    fi
    [ "$status" -eq 0 ] && echo "Development and Production both match $SCHEMA"
    exit "$status"
    ;;
*)
    echo "usage: sh Scripts/cloudkit_schema.sh export|check" >&2
    exit 2
    ;;
esac
