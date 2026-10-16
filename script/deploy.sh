#!/usr/bin/env bash
# Chain-agnostic deployment wrapper for the AsyncSwap hook and Router.
#
#   script/deploy.sh <chain-key> [dry-run|broadcast|verify]
#
# <chain-key> is a key under "chains" in script/config/chains.json whose deployment status is
# "prepared". Per-chain wrappers (deploy-unichain.sh, deploy-arc.sh) call this script.
#
#   dry-run    simulate everything against the RPC, mine the hook salt, send nothing (default)
#   broadcast  deploy AsyncMatching (if missing), the hook and the Router; sync the registry
#   verify     publish sources for every registry entry via Sourcify, then try Blockscout and
#              write standard JSON inputs for manual upload as a fallback
#
# .env.deploy must provide RPC_URL (or the chain's rpcUrlEnv) and, for broadcast, DEPLOYER_ACCOUNT
# (a Foundry keystore). DEPLOY_OWNER may pin the owner address; otherwise it is read from the
# keystore for broadcast and falls back to the script default for dry runs.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/.env.deploy"
CHAIN_CONFIG="$ROOT_DIR/script/config/chains.json"
OWNER_DEFAULT="0xb1F0982E02f9F71E60512fd47471d76610CcB556"
CREATE2_DEPLOYER="0x4e59b44847b379578588920cA78FbF26c0B4956C"

CHAIN_KEY="${1:-}"
mode="${2:-dry-run}"
if [[ -z "$CHAIN_KEY" ]]; then
  echo "Usage: $0 <chain-key> [dry-run|broadcast|verify]" >&2
  exit 2
fi
if [[ "$mode" != "dry-run" && "$mode" != "broadcast" && "$mode" != "verify" ]]; then
  echo "Usage: $0 <chain-key> [dry-run|broadcast|verify]" >&2
  exit 2
fi

for tool in forge cast python3 bun; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
done

# The salt miner (script/mine-hook-salt.ts) needs viem from package.json.
if [[ ! -d "$ROOT_DIR/node_modules/viem" ]]; then
  echo "Installing script dependencies (bun install)."
  (cd "$ROOT_DIR" && bun install --frozen-lockfile)
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing $CONFIG_FILE. Copy .env.deploy.example and set RPC_URL and DEPLOYER_ACCOUNT." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1090
source "$CONFIG_FILE"
set +a

# ---- chain config -------------------------------------------------------------------------
chain_config_values="$(python3 - "$CHAIN_CONFIG" "$CHAIN_KEY" <<'PY'
import json
import re
import sys

config_path, chain_key = sys.argv[1:]
with open(config_path, encoding="utf-8") as config_file:
    config = json.load(config_file)
chain = config.get("chains", {}).get(chain_key)
if chain is None:
    raise SystemExit(f"Chain '{chain_key}' is missing from {config_path}.")
if chain.get("deployment", {}).get("status") != "prepared":
    raise SystemExit(f"{chain['name']} is not marked prepared for deployment.")
contracts = chain.get("contracts", {})
addr_re = r"0x[0-9a-fA-F]{40}"
usdc = contracts.get("usdc")
if not isinstance(usdc, str) or not re.fullmatch(addr_re, usdc):
    raise SystemExit(f"{chain['name']} has no verified USDC address in {config_path}.")
pool_manager = contracts.get("poolManager")
if not isinstance(pool_manager, str) or not re.fullmatch(addr_re, pool_manager):
    raise SystemExit(f"{chain['name']} has no PoolManager address in {config_path}.")
print(chain["chainId"], usdc, pool_manager, chain.get("rpcUrlEnv") or "", chain.get("explorerUrl") or "", chain["name"].replace(" ", "_"))
PY
)"
read -r expected_chain_id DEPLOY_NUMERAIRE_ADDRESS POOL_MANAGER_ADDRESS rpc_url_env explorer_url chain_name <<< "$chain_config_values"
chain_name="${chain_name//_/ }"
export DEPLOY_NUMERAIRE_ADDRESS

# The chain's own RPC variable (e.g. RPC_URL_ARC) wins over the generic RPC_URL.
if [[ -n "$rpc_url_env" && -n "${!rpc_url_env:-}" ]]; then
  RPC_URL="${!rpc_url_env}"
fi
: "${RPC_URL:?Set RPC_URL (or ${rpc_url_env:-RPC_URL}) in .env.deploy}"

chain_id="$(cast chain-id --rpc-url "$RPC_URL")"
if [[ "$chain_id" != "$expected_chain_id" ]]; then
  echo "Refusing: RPC returned chain ID $chain_id, expected configured chain $expected_chain_id ($chain_name)." >&2
  exit 1
fi

has_code() {
  local code
  code="$(cast code "$1" --rpc-url "$RPC_URL")"
  [[ -n "$code" && "$code" != "0x" ]]
}

has_code "$DEPLOY_NUMERAIRE_ADDRESS" || { echo "Refusing: configured USDC $DEPLOY_NUMERAIRE_ADDRESS has no code on $chain_name." >&2; exit 1; }
has_code "$POOL_MANAGER_ADDRESS" || { echo "Refusing: configured PoolManager $POOL_MANAGER_ADDRESS has no code on $chain_name." >&2; exit 1; }
has_code "$CREATE2_DEPLOYER" || { echo "Refusing: CREATE2 deployer $CREATE2_DEPLOYER is missing on $chain_name." >&2; exit 1; }

# ---- owner ----------------------------------------------------------------------------------
if [[ -z "${DEPLOY_OWNER:-}" ]]; then
  if [[ "$mode" == "broadcast" ]]; then
    : "${DEPLOYER_ACCOUNT:?Set DEPLOYER_ACCOUNT to a Foundry keystore in .env.deploy}"
    echo "Reading deployer address from keystore '$DEPLOYER_ACCOUNT' (password prompt)."
    DEPLOY_OWNER="$(cast wallet address --account "$DEPLOYER_ACCOUNT")"
  else
    DEPLOY_OWNER="$OWNER_DEFAULT"
    echo "DEPLOY_OWNER not set; dry run uses the default owner $DEPLOY_OWNER. The hook salt depends on the owner, so set DEPLOY_OWNER for a faithful rehearsal."
  fi
fi
export DEPLOY_OWNER
OWNER="$DEPLOY_OWNER"

registry="$ROOT_DIR/deployments/$chain_id/$chain_id.json"

# ---- verify mode ----------------------------------------------------------------------------
if [[ "$mode" == "verify" ]]; then
  [[ -f "$registry" ]] || { echo "No registry at $registry; broadcast first." >&2; exit 1; }
  read -r lib_addr hook_addr router_addr vault_addr <<< "$(python3 - "$registry" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))["contracts"]
def a(n):
    e = c.get(n)
    return e["address"] if e else "-"
print(a("AsyncMatching"), a("AsyncSwap"), a("Router"), a("FeeVault"))
PY
)"
  for pair in "AsyncMatching:$lib_addr" "AsyncSwap:$hook_addr" "Router:$router_addr" "FeeVault:$vault_addr"; do
    [[ "${pair#*:}" != "-" ]] || { echo "Registry is missing ${pair%%:*}." >&2; exit 1; }
  done
  hook_args="$(cast abi-encode "constructor(address,address,address)" "$POOL_MANAGER_ADDRESS" "$DEPLOY_NUMERAIRE_ADDRESS" "$OWNER")"
  router_args="$(cast abi-encode "constructor(address,address,address)" "$POOL_MANAGER_ADDRESS" "$hook_addr" 0x000000000022D473030F116dDEE9F6B43aC78BA3)"
  vault_args="$(cast abi-encode "constructor(address)" "$POOL_MANAGER_ADDRESS")"
  lib_flag="src/libraries/AsyncMatching.sol:AsyncMatching:$lib_addr"
  out_dir="$ROOT_DIR/deployments/$chain_id/verify"
  mkdir -p "$out_dir"

  verify_one() {
    local name="$1" addr="$2" target="$3" args="$4"
    local extra=()
    [[ -n "$args" ]] && extra+=(--constructor-args "$args")
    [[ "$name" == "AsyncSwap" ]] && extra+=(--libraries "$lib_flag")
    echo "== $name @ $addr"
    forge verify-contract --chain "$chain_id" --verifier sourcify --watch "${extra[@]}" "$addr" "$target" \
      || echo "   Sourcify verification failed for $name (see above)." >&2
    if [[ -n "$explorer_url" ]]; then
      forge verify-contract --chain "$chain_id" --verifier blockscout --verifier-url "$explorer_url/api?" "${extra[@]}" "$addr" "$target" \
        || echo "   Blockscout submission failed for $name (the explorer API may sit behind a bot challenge); upload $out_dir/$name.json manually at $explorer_url/address/$addr#code." >&2
    fi
    forge verify-contract --chain "$chain_id" --show-standard-json-input "${extra[@]}" "$addr" "$target" > "$out_dir/$name.json"
  }
  verify_one AsyncMatching "$lib_addr" src/libraries/AsyncMatching.sol:AsyncMatching ""
  verify_one AsyncSwap "$hook_addr" src/AsyncSwap.sol:AsyncSwap "$hook_args"
  verify_one Router "$router_addr" src/Router.sol:Router "$router_args"
  verify_one FeeVault "$vault_addr" src/FeeVault.sol:FeeVault "$vault_args"
  echo "Standard JSON inputs written to $out_dir for manual verification."
  exit 0
fi

# ---- AsyncMatching library ------------------------------------------------------------------
# Deterministic address: CREATE2 via the shared deployer with the salt in 00_DeployMatchingLibrary.
lib_init_code="$(forge inspect src/libraries/AsyncMatching.sol:AsyncMatching bytecode)"
lib_salt="$(cast keccak "asyncswap.v2.AsyncMatching")"
lib_predicted="$(cast create2 --deployer "$CREATE2_DEPLOYER" --salt "$lib_salt" --init-code-hash "$(cast keccak "$lib_init_code")" | awk '/Address:/ {print $2} /^0x/ {print $1}' | tail -1)"
if [[ -n "${ASYNC_MATCHING_LIBRARY_ADDRESS:-}" && "$ASYNC_MATCHING_LIBRARY_ADDRESS" != "0x0000000000000000000000000000000000000000" ]]; then
  has_code "$ASYNC_MATCHING_LIBRARY_ADDRESS" || { echo "Refusing: ASYNC_MATCHING_LIBRARY_ADDRESS $ASYNC_MATCHING_LIBRARY_ADDRESS has no code on $chain_name." >&2; exit 1; }
  lib_addr="$ASYNC_MATCHING_LIBRARY_ADDRESS"
  echo "Using pre-deployed AsyncMatching at $lib_addr."
else
  lib_addr="$lib_predicted"
  if has_code "$lib_addr"; then
    echo "AsyncMatching already deployed at $lib_addr."
  elif [[ "$mode" == "broadcast" ]]; then
    : "${DEPLOYER_ACCOUNT:?Set DEPLOYER_ACCOUNT to a Foundry keystore in .env.deploy}"
    echo "Deploying AsyncMatching to $lib_addr on $chain_name ($chain_id) from $OWNER."
    DEPLOY_DRY_RUN=false forge script "$ROOT_DIR/script/00_DeployMatchingLibrary.s.sol" \
      --rpc-url "$RPC_URL" --sender "$OWNER" --broadcast --account "$DEPLOYER_ACCOUNT"
    has_code "$lib_addr" || { echo "AsyncMatching has no code at $lib_addr after broadcast." >&2; exit 1; }
  else
    echo "AsyncMatching will be deployed to $lib_addr (simulating)."
    DEPLOY_DRY_RUN=true forge script "$ROOT_DIR/script/00_DeployMatchingLibrary.s.sol" --rpc-url "$RPC_URL" --sender "$OWNER"
  fi
fi

# ---- hook + router ----------------------------------------------------------------------------
forge_args=(
  script "$ROOT_DIR/script/01_DeployHook.s.sol"
  --rpc-url "$RPC_URL"
  --ffi
  --sender "$OWNER"
  --libraries "src/libraries/AsyncMatching.sol:AsyncMatching:$lib_addr"
)
if [[ "$mode" == "broadcast" ]]; then
  : "${DEPLOYER_ACCOUNT:?Set DEPLOYER_ACCOUNT to a Foundry keystore in .env.deploy}"
  forge_args+=(--broadcast --account "$DEPLOYER_ACCOUNT")
  export DEPLOY_DRY_RUN=false
  echo "Broadcasting AsyncSwap + Router on $chain_name ($chain_id) from $OWNER."
else
  export DEPLOY_DRY_RUN=true
  echo "Dry run on $chain_name ($chain_id) as $OWNER: no transactions will be broadcast."
fi
forge "${forge_args[@]}"

if [[ "$mode" == "broadcast" ]]; then
  python3 "$ROOT_DIR/script/sync-deployment-record.py" \
    --chain-id "$chain_id" \
    --registry "$registry" \
    --broadcast "$ROOT_DIR/broadcast/01_DeployHook.s.sol/$chain_id/run-latest.json"
  echo "Deployed. Next: '$0 $CHAIN_KEY verify', then initialize a pool with script/02_InitializePool.s.sol (never pair the native currency on chains whose gas token has an ERC-20 twin, e.g. Arc)."
fi
