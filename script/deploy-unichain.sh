#!/usr/bin/env bash
# Unichain mainnet (130). Thin wrapper over the chain-agnostic script/deploy.sh.
set -euo pipefail
exec "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/deploy.sh" unichain "$@"
