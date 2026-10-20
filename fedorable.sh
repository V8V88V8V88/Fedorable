#!/usr/bin/env bash
set -euo pipefail

FEDORABLE_ROOT=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
source "$FEDORABLE_ROOT/lib/ui.sh"
source "$FEDORABLE_ROOT/lib/tasks.sh"
source "$FEDORABLE_ROOT/lib/cli.sh"

main "$@"
