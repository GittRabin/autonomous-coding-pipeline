#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[setup] setup.sh is deprecated; running install.sh instead"
exec "$SCRIPT_DIR/install.sh" "$@"
