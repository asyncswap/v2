// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UniswapAddresses} from "./config/UniswapAddresses.sol";
import {DeploymentsRegistry} from "./lib/Deployments.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/Test.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Shared helpers for deploy/runtime scripts in protocol/.
/// @dev Mirrors contracts/script/FFIHelper.sol but adapted to the new AsyncOrder shape
///      (amountOutMin + nonce) and the protocol/ source layout.
contract FFIHelper is Script, DeploymentsRegistry {
    using stdJson for string;

    address internal constant OWNER_DEFAULT = 0xb1F0982E02f9F71E60512fd47471d76610CcB556;
    address internal constant OWNER_ANVIL = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    /// @dev Deployer and hook owner. Anvil uses the first default account; elsewhere the
    ///      `DEPLOY_OWNER` env var (set by the chain wrapper from the Foundry keystore) wins over the default.
    address internal OWNER =
        block.chainid == UniswapAddresses.CHAIN_ID_ANVIL ? OWNER_ANVIL : vm.envOr("DEPLOY_OWNER", OWNER_DEFAULT);

    /// @notice Resolves the PoolManager address: canonical chain → use canonical;
    ///         otherwise read the registry written by 00_DeployPoolManager.
    function _getDeployedPoolManager() internal view returns (address) {
        if (UniswapAddresses.hasCanonicalPoolManager(block.chainid)) {
            return UniswapAddresses.poolManager(block.chainid);
        }
        Entry memory pm = _readEntry(block.chainid, "PoolManager");
        require(pm.addr != address(0), "PoolManager not in registry --run 00_DeployPoolManager first");
        return pm.addr;
    }

    function _getDeployedHook() internal view returns (address hookAddress, address routerAddress) {
        Entry memory hook = _readEntry(block.chainid, "AsyncSwap");
        Entry memory router = _readEntry(block.chainid, "Router");
        require(hook.addr != address(0), "AsyncSwap hook not in registry --run 01_DeployHook first");
        require(router.addr != address(0), "Router not in registry --run 01_DeployHook first");
        return (hook.addr, router.addr);
    }

    /* ------------------------- pool key persistence ------------------------- */

    function _poolKeyPath() internal view returns (string memory) {
        return string.concat(
            vm.projectRoot(), "/deployments/", vm.toString(block.chainid), "/", vm.toString(block.chainid), "-pool.json"
        );
    }

    /// @notice Persist the active PoolKey to a sidecar JSON so swap/fill scripts can rebuild it
    ///         without scraping broadcast logs.
    function _savePoolKey(PoolKey memory key) internal {
        string memory k = "poolkey";
        vm.serializeAddress(k, "currency0", Currency.unwrap(key.currency0));
        vm.serializeAddress(k, "currency1", Currency.unwrap(key.currency1));
        vm.serializeUint(k, "fee", uint256(key.fee));
        vm.serializeInt(k, "tickSpacing", int256(key.tickSpacing));
        string memory j = vm.serializeAddress(k, "hooks", address(key.hooks));
        vm.writeJson(j, _poolKeyPath());
    }

    function _loadPoolKey() internal view returns (PoolKey memory key) {
        string memory json = vm.readFile(_poolKeyPath());
        key.currency0 = Currency.wrap(json.readAddress(".currency0"));
        key.currency1 = Currency.wrap(json.readAddress(".currency1"));
        key.fee = uint24(json.readUint(".fee"));
        key.tickSpacing = int24(json.readInt(".tickSpacing"));
        key.hooks = AsyncSwap(payable(json.readAddress(".hooks")));
    }

    /* ------------------------- last order persistence ------------------------- */

    struct OrderRecord {
        address owner;
        bool zeroForOne;
        uint256 amountIn;
        uint256 amountOutMin;
        uint160 sqrtPrice;
        bytes32 salt;
    }

    function _orderPath() internal view returns (string memory) {
        return string.concat(
            vm.projectRoot(),
            "/deployments/",
            vm.toString(block.chainid),
            "/",
            vm.toString(block.chainid),
            "-order.json"
        );
    }

    /// @notice Persist the most-recently-submitted order so 05_ExecuteOrder can fill it without
    ///         relying on event log positions in the broadcast artifact.
    function _saveOrder(OrderRecord memory r) internal {
        string memory k = "lastOrder";
        vm.serializeAddress(k, "owner", r.owner);
        vm.serializeBool(k, "zeroForOne", r.zeroForOne);
        vm.serializeUint(k, "amountIn", r.amountIn);
        vm.serializeUint(k, "amountOutMin", r.amountOutMin);
        vm.serializeUint(k, "sqrtPrice", uint256(r.sqrtPrice));
        string memory j = vm.serializeBytes32(k, "salt", r.salt);
        vm.writeJson(j, _orderPath());
    }

    function _loadOrder() internal view returns (AsyncOrder memory) {
        PoolKey memory key = _loadPoolKey();
        string memory json = vm.readFile(_orderPath());
        return AsyncOrder({
            key: key,
            owner: json.readAddress(".owner"),
            zeroForOne: json.readBool(".zeroForOne"),
            amountIn: json.readUint(".amountIn"),
            amountOutMin: json.readUint(".amountOutMin"),
            priorityFee: 0,
            sqrtPrice: uint160(json.readUint(".sqrtPrice")),
            salt: json.readBytes32(".salt")
        });
    }
}
