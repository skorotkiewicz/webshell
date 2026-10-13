#!/bin/sh
# Keep the previous entry point working.
repository=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
exec sh "$repository/run.sh" "$@"
