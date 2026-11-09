#!/bin/sh
# Pull the project image matching this checkout's container dependencies and convert it to .sif.
# Runs on the HPC (no Docker needed), POSIX sh only.
#
# Usage: .container/hpc-pull.sh [<hardware>] [<rev>]     (defaults: cuda, HEAD)
# Result: images/<image>-<deps tag>.sif and the symlink images/<image>.sif,
#         where <image> is e.g. amml-python-template-cuda (with -slim for slim images)
set -eu

root=$(git rev-parse --show-toplevel)
. "$root/.container/image.conf"
[ -f "$root/.container/image.local.conf" ] && . "$root/.container/image.local.conf"

hardware=${1:-cuda}
rev=${2:-HEAD}

# Keep in sync with deps_tag, image_version and image_repo in .container/image.sh
# shellcheck disable=SC2086  # DEPS_FILES is a word list
tag="deps-$(git -C "$root" ls-tree -r "$rev" -- $DEPS_FILES | sha256sum | cut -c1-12)"
version=$(git -C "$root" show "$rev:Dockerfile" | sed -n 's/^ARG version="\{0,1\}\([a-z]*\).*/\1/p' | head -n 1)
repo="$IMAGE_NAME-$hardware"
[ "$version" = slim ] && repo="$repo-slim"

# shellcheck disable=SC2086
git -C "$root" diff --quiet HEAD -- $DEPS_FILES ||
    echo "warning: uncommitted changes in $DEPS_FILES are NOT part of the image" >&2

if command -v apptainer >/dev/null; then runtime=apptainer
elif command -v singularity >/dev/null; then runtime=singularity
else echo "error: neither apptainer nor singularity found" >&2; exit 1; fi

name=$(basename "$repo")
mkdir -p "$root/images"
sif="$root/images/$name-$tag.sif"
if [ -f "$sif" ]; then
    echo "already present: $sif"
else
    echo "pulling docker://$repo:$tag with $runtime"
    # Pull into a temporary file so an aborted pull never leaves a broken .sif behind
    "$runtime" pull "$sif.tmp" "docker://$repo:$tag" || {
        rm -f "$sif.tmp"
        echo "error: pull failed - was the image built and pushed? (.container/image.sh status on the dev server)" >&2
        exit 1
    }
    mv "$sif.tmp" "$sif"
fi
ln -sfn "$(basename "$sif")" "$root/images/$name.sif"

echo "run with e.g.:"
echo "  $runtime exec $([ "$hardware" = cuda ] && echo '--nv ')--env-file .env --bind $root:/opt/project --pwd /opt/project \\"
echo "    images/$name.sif python $(basename "$IMAGE_NAME")/__init__.py"
