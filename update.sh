#!/bin/bash
# update.sh - Automates changelog, metadata update, and release tagging for the FHEM-Webuntis Perl module.
#
# This script:
#   - Updates controls_webuntis.txt with current date and module size
#   - Extracts the module version and generates a changelog entry
#   - Prepends changelog info to CHANGED file
#   - Creates and pushes a git tag for the new version if needed
#   - Intended for use after each release or significant update

# This script updates the 'controls_webuntis.txt' file with information about the 'FHEM/69_Webuntis.pm' module.
# It records the current date and time, the size of the module file in bytes, and the module's path.
# The output format is: "UPD <date> <size> <module_path>"
# Variables:
#   FILE   - The output file to write update information.
#   DATE   - The current date and time in "YYYY-MM-DD_HH:MM:SS" format.
#   MODULE - The path to the module file being tracked.
#   SIZE   - The size of the module file in bytes.
#   CHANGED- A flag variable (currently unused in this snippet).
FILE="controls_webuntis.txt"
DATE=$(date +"%Y-%m-%d_%H:%M:%S")
MODULE="FHEM/69_Webuntis.pm"

SIZE=$(stat -c %s "$MODULE")
echo "UPD $DATE $SIZE $MODULE" > "$FILE"
CHANGED="CHANGED"

# Extract version from the module
VERSION=$(grep -Po 'WEBUNTIS_VERSION\s*=>\s*"\K[0-9\.]+' "$MODULE" | head -1)

if [ -z "$VERSION" ]; then
    echo "Could not detect version in $MODULE"
    exit 1
fi

TAG="v$VERSION"

# This script retrieves the latest Git tag and collects commit messages since that tag.
# If a tag exists, it lists commit messages from the tag up to the current HEAD.
# If no tag is found, it lists all commit messages in the repository.
# Find last tag
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null)

# Get commit messages since last tag
if [ -n "$LAST_TAG" ]; then
    CHANGES=$(git log "$LAST_TAG"..HEAD --pretty=format:"- %s")
else
    CHANGES=$(git log --pretty=format:"- %s")
fi

# This script updates the CHANGED file with a new entry containing the current date,
# version, and changes. The new entry is prepended to the file so that the most recent
# changes appear at the top. If the CHANGED file does not exist, it is created.
# Prepare CHANGED entry
TODAY=$(date +%Y-%m-%d)
CHANGED_ENTRY="$TODAY $VERSION\n$CHANGES\n"

# Prepend to CHANGED file (so most recent is at the top)
if [ -f "$CHANGED" ]; then
    { echo -e "$CHANGED_ENTRY"; cat "$CHANGED"; } > "$CHANGED.tmp" && mv "$CHANGED.tmp" "$CHANGED"
else
    echo -e "$CHANGED_ENTRY" > "$CHANGED"
fi

echo "Updated CHANGED file."

# This script checks if a Git tag specified by the variable $TAG exists.
# If the tag does not exist, it creates the tag and pushes it to the remote repository.
# If the tag already exists, it notifies the user.
# Create and push tag if not exists
if ! git rev-parse "$TAG" >/dev/null 2>&1; then
    git tag "$TAG"
    git push origin "$TAG"
    echo "Created and pushed tag $TAG"
else
    echo "Tag $TAG already exists."
fi