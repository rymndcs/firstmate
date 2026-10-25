#!/usr/bin/env bash
# Protected-path enforcement and task hook lifecycle. See --help for interfaces.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -I "$SCRIPT_DIR/fm-protected-paths.py" "$@"
