#!/usr/bin/env bash
# Arc mainnet (5042). Gas is paid in USDC; the numeraire is the ERC-20 USDC precompile at 0x3600…0000.
# Never initialize a native-currency pool on Arc: native and ERC-20 USDC are the same balance.
set -euo pipefail
exec "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/deploy.sh" arc "$@"
