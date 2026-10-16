# Async Swap v2

Async Swap is a Uniswap v4 hook that turns exact-input swaps into resting limit orders with an on-chain order book and matching engine.

Diagrams: [order lifecycle](docs/order-lifecycle.md#order-lifecycle) · [priority-bid settlement](docs/order-lifecycle.md#priority-bid-settlement) · [contract calls and responses](#contract-call-sequences).

The live Async Swap order state is indexed by `AsyncFiller.Book`: a Patricia radix tree locates bid/ask price levels. Better prices always execute first. Each pool can use FIFO or USDC priority bids to resolve orders at the same price. In priority-bid mode, every order must bid at least $0.10 (100,000 units of six-decimal USDC); a larger bid ranks first and equal bids use FIFO. Priority bids affect matching within this book, not block-builder transaction inclusion order. Price updates re-enter with fresh time priority.

When a new order crosses the book, the Router immediately matches it against up to eight resting orders in the same PoolManager unlock. Matching burns both makers’ ERC-6909 escrow claims and transfers the corresponding tokens to the counterparties. Partial fills stay in the book; input left after a maker’s minimum output is met is returned. Priority bids are escrowed as PoolManager claims when the order is created. A proportional share is donated to currently active v4 LPs as input fills, in the same unlock as settlement. The bid is non-refundable: its remaining share is donated when the order is canceled or terminates; if the pool has no active liquidity, the amount is routed to the protocol FeeVault. If more than eight pairs are crossed, anyone can call `Router.matchBook` to continue in another bounded transaction.

Pool owners can also add ordinary Uniswap v4 liquidity positions. After order-to-order matching, Async Swap tries the remaining order against active pool liquidity. It executes only if the pool consumes the full remaining input and returns at least the maker’s remaining minimum output. Otherwise that attempt rolls back and the order remains available to another counterparty or filler. Anyone can retry a resting order through `Router.fillFromPoolLiquidity` after liquidity or the pool price changes. These fills charge a 30 bps v4 LP fee, accrued to active positions; LPs bear the usual inventory and price risk.

The standalone `MatchingEngine` is an algorithm and stress-test harness; its measurements do not describe the integrated hook’s gas use. Priority bids only resolve same-price book matches. They do not reserve a transaction’s first or last position in a block, prevent builders from reordering transactions, or guarantee execution. Active v4 liquidity means positions in range at the current tick when `donate` runs; out-of-range LP positions do not receive that donation.

## Contract call sequences

Also available in [docs/contract-call-sequences.md](docs/contract-call-sequences.md).

Solid arrows are calls or actions; dashed arrows are returns or delivered results. Each sequence groups related transactions; it is not one transaction from top to bottom. The app and wallet represent the user interface, not trusted settlement components. An indexer may observe emitted events for discovery, but neither an API nor an indexer is required by the contracts.

`AsyncMatching` is a linked external library called in the hook's context. `AsyncFiller`, the price tree, and currency-settlement helpers operate on that same context; they are not independent custodians. Arrows from the matching library to PoolManager therefore execute as the hook. ERC-6909 claims and LP fee accounting live inside PoolManager.

### User order, book matching, and LP fallback

```mermaid
sequenceDiagram
    autonumber
    actor User as Maker
    participant App as App
    participant Wallet as Maker wallet
    actor Relayer
    participant Router
    participant Hook as AsyncSwap hook
    participant Match as AsyncMatching / AsyncFiller
    participant Permit as Permit2
    participant Token as ERC-20 / USDC
    participant PM as PoolManager
    actor Counterparty as Resting maker
    participant Vault as FeeVault

    User->>App: Choose asset, input amount, minimum output, and bid
    App->>Wallet: Request approval, authorization, and order confirmation
    opt Router not yet authorized for this maker and pool
        Wallet->>Hook: setExecutor(poolId, Router, true)
        Hook-->>Wallet: Authorization recorded
    end
    Note over Wallet,Token: Direct ERC-20 input needs Router approval, signed input needs Permit2 approval.<br/>A nonzero USDC bid separately needs Router approval.
    alt Direct order, including native ETH input
        Wallet->>Router: swap(order, userData), exact ETH value if native
    else Signed ERC-20 order
        Wallet-->>Relayer: Permit2 order-witness signature and optional executor grant
        Relayer->>Router: swapWithSig(order, permit, grant)
        opt Signed executor grant needed
            Router->>Hook: setExecutorWithSig(...)
            Hook-->>Router: Grant validated and recorded
        end
    end
    Router->>PM: unlock(create action)
    PM->>Router: unlockCallback(data)
    Router->>PM: swap(exact input, hook data)
    PM->>Hook: beforeSwap(...)
    Hook->>PM: mint input escrow claims to hook
    Hook->>Match: Validate and add order to price book
    Match-->>Hook: Order recorded
    Note over Hook,Match: AsyncOrderCreated event, order is not matched until input and bid funding finish.
    Hook-->>PM: beforeSwap selector and custom accounting delta
    PM-->>Router: Swap delta
    alt Direct input funding
        Router->>PM: Settle input using ERC-20 transfer or forwarded ETH
    else Permit2 input funding
        Router->>PM: sync(input token)
        Router->>Permit: permitWitnessTransferFrom(order witness)
        Permit->>Token: transferFrom(maker, PoolManager, input)
        Token-->>Permit: Transfer succeeds
        Permit-->>Router: Signature and transfer accepted
        Router->>PM: settle()
    end
    opt Nonzero priority bid
        Router->>PM: sync(USDC)
        Router->>Token: transferFrom(maker, PoolManager, bid)
        Token-->>Router: Transfer succeeds
        Router->>PM: settleFor(hook)
        Router->>Hook: recordPriorityFee(key, maker, bid)
        Hook->>Match: Record funded bid and mint escrow claims
        Match->>PM: mint USDC claims to hook
        Match-->>Hook: Bid escrowed
        Hook-->>Router: Bid funding recorded
    end
    Router->>Hook: matchNewOrder(order)
    Hook->>Match: matchIncoming(...)
    loop Up to 8 executable crossing pairs
        Match->>Match: Best opposing price, configured same-price tie-break
        Match->>PM: Burn input claims and settle both order legs
        PM-->>Wallet: ERC-20 proceeds or native claims
        PM-->>Counterparty: ERC-20 proceeds or native claims
        Match->>PM: Donate filled bid shares if active liquidity exists
        Note over Match,Vault: With no active liquidity, bid claims go to FeeVault instead.<br/>Reduce and re-rank remainders, settle residual bids on termination.
    end
    Match-->>Hook: Matched pair count
    opt Incoming order still has a remainder
        Hook->>Hook: External self-call fillOrderFromPoolLiquidity(order, id)
        Hook->>Match: fillFromPoolLiquidity(...)
        Match->>PM: Burn remaining input claims, temporarily set 30 bps LP fee
        Match->>PM: swap(remaining exact input)
        Note over Hook,PM: Hook-originated swap skips this hook's callbacks, it does not create another order.
        PM-->>Match: Actual input and output deltas
        Match->>PM: Restore previous LP fee
        alt Full remaining input consumed and minimum output met
            Match->>PM: Pay output, settle remaining bid
            PM-->>Wallet: ERC-20 proceeds or native claims
            Match-->>Hook: Order removed, liquidity fill event
        else Insufficient liquidity, partial execution, or limit not met
            Match-->>Hook: Self-call reverts, caught by matchNewOrder
            Note over Hook,PM: Only LP attempt rolls back, prior book fills and open remainder survive.
        end
    end
    Hook-->>Router: Matched pair count
    Router-->>PM: Callback complete
    PM-->>Router: Unlock completes if all currency deltas are settled
    Router-->>Wallet: Direct transaction succeeds
    Note over Wallet,Relayer: For signed submission, the transaction result returns to the submitter instead.
```

The LP fee accrues through PoolManager's position accounting. A priority donation is separate: it rewards liquidity active at the current tick when `donate` runs. LPs do not receive an external callback on every fill.

### Private fillers, continuation, repricing, and cancellation

These are alternative actions on open orders. Private fills and LP retries require the Router to remain authorized by the maker. Book continuation is permissionless and processes at most eight pairs per call.

```mermaid
sequenceDiagram
    autonumber
    actor Maker as Maker / wallet
    actor Caller as Filler or public caller
    participant Router
    participant Hook as AsyncSwap hook
    participant Match as AsyncMatching / AsyncFiller
    participant Token as Output ERC-20
    participant PM as PoolManager
    participant Vault as FeeVault

    alt Private filler settles a specific order
        Caller->>Hook: asyncOrderInfo(poolId, orderId)
        Hook-->>Caller: Live remaining input and minimum output
        Caller->>Router: fillOrder(order, maxPrice, data)
        Note over Caller,Hook: Native output requires exact gross ETH, forwarded by Router to hook before unlock.<br/>ERC-20 output requires filler approval to Router.
        Router->>PM: unlock(fill action)
        PM->>Router: unlockCallback(data)
        Router->>Hook: Read live minimum and calculate protocol fee
        Hook-->>Router: Net minimum and fee
        Router->>Router: Require gross output no greater than maxPrice
        opt ERC-20 output
            Router->>PM: sync(output token)
            Router->>Token: transferFrom(filler, PoolManager, gross output)
            Token-->>Router: Transfer succeeds
            Router->>PM: settleFor(hook)
        end
        Router->>Hook: executeOrder(order, filler)
        Hook->>Match: fill(...), validate executor and open order
        Match->>PM: Settle output, pay maker net minimum
        PM-->>Maker: ERC-20 output or native claims
        Match->>PM: mint protocol-fee claims to FeeVault
        Note over PM,Vault: Claims are credited inside PoolManager, FeeVault is not called during a fill.
        Match->>PM: Burn input escrow, pay filler remaining input
        PM-->>Caller: ERC-20 input or native claims
        Match->>PM: Settle remaining bid to active LPs or FeeVault
        Match-->>Hook: Order closed, AsyncOrderFilled event
        Hook-->>Router: Fill complete
        Router-->>PM: Callback complete
        PM-->>Router: Unlock complete
        Router-->>Caller: Transaction succeeds
    else Continue a crossed book
        Caller->>Router: matchBook(key, maxMatches from 1 to 8)
        Router->>PM: unlock(match action)
        PM->>Router: unlockCallback(data)
        Router->>Hook: matchBook(key, maxMatches)
        Hook->>Match: Match best bid and ask, settle pairs and bids
        Match->>PM: Burn claims, pay counterparties, settle bid shares
        Match-->>Hook: Matched pair count
        Hook-->>Router: Matched pair count
        Router-->>PM: Callback complete
        PM-->>Router: Unlock complete
        Router-->>Caller: Transaction succeeds
    else Retry a specific order against LP liquidity
        Caller->>Router: fillFromPoolLiquidity(order)
        Router->>PM: unlock(pool fill action)
        PM->>Router: unlockCallback(data)
        Router->>Hook: tryFillOrderFromPoolLiquidity(order)
        Note over Hook,PM: Same guarded LP self-call as above, no book-priority check.
        Hook-->>Router: true if filled, false if LP attempt rolled back
        Router-->>PM: Callback complete
        PM-->>Router: Unlock complete
        Router-->>Caller: Transaction succeeds, inspect events for actual fill
    else Maker reprices
        Maker->>Hook: updatePrice(order, newAmountOutMin)
        Hook->>Match: Update minimum, re-enter with fresh sequence
        Match-->>Hook: New price and rank
        Hook-->>Maker: AsyncOrderPriceUpdated event
        Note over Maker,PM: No Router or PoolManager unlock, this does not trigger matching by itself.
    else Maker cancels
        Maker->>Router: cancelOrder(order)
        Router->>PM: unlock(cancel action)
        PM->>Router: unlockCallback(data)
        Router->>Hook: cancelOrder(order)
        Hook->>Match: Validate executor, remove open order
        Match->>PM: Burn input claims and return remaining input
        PM-->>Maker: ERC-20 refund or native claims
        Match->>PM: Settle non-refundable remaining bid to LPs or FeeVault
        Match-->>Hook: AsyncOrderCancelled event
        Hook-->>Router: Cancellation complete
        Router-->>PM: Callback complete
        PM-->>Router: Unlock complete
        Router-->>Maker: Transaction succeeds
    end
```

Signed alternatives are `Hook.updatePriceWithSig` and `Router.cancelWithSig`; a relayer can submit the maker's signature. Signature checks precede the corresponding state change or cancellation unlock. Any uncaught revert rolls back the whole transaction, including transfers and donations.

### Pool setup, liquidity providers, and withdrawals

The liquidity manager below is a compatible Uniswap v4 periphery contract, not Async Swap's order Router. Its precise user-facing methods depend on the chosen periphery; the PoolManager calls shown are the common execution path. Setup and withdrawals are separate transactions from order execution.

```mermaid
sequenceDiagram
    autonumber
    actor Operator as Pool initializer
    actor Admin as Protocol owner
    actor LP as Liquidity provider
    actor Holder as Native-claim holder
    participant LM as v4 liquidity manager
    participant Hook as AsyncSwap hook
    participant PM as PoolManager
    participant Native as NativeClaims
    participant Vault as FeeVault
    actor Recipient

    Operator->>PM: initialize(key, sqrtPriceX96)
    PM->>Hook: beforeInitialize(...)
    Hook->>Hook: Require configured USDC and dynamic-fee pool
    Hook-->>PM: beforeInitialize selector
    PM-->>Operator: Initialized tick, Initialize event
    opt Configure ordering mode while book is empty
        Admin->>Hook: setOrderingMode(key, FIFO or PriorityFee)
        Hook-->>Admin: Mode recorded
    end
    LP->>LM: Add funded liquidity in a chosen tick range
    LM->>PM: unlock(liquidity operation)
    PM->>LM: unlockCallback(data)
    LM->>PM: modifyLiquidity(key, params, hookData)
    PM->>Hook: beforeAddLiquidity(...)
    Hook-->>PM: beforeAddLiquidity selector
    PM-->>LM: Liquidity and fee deltas
    LM->>PM: Settle required token amounts
    LM-->>PM: Callback complete
    PM-->>LM: Unlock complete
    LM-->>LP: Position updated
    Note over LP,PM: Eligible positions accrue swap fees and donations in PoolManager accounting.<br/>LPs collect through their chosen liquidity manager, no per-fill LP callback.

    Holder->>PM: approve(NativeClaims, claim ID 0, amount)
    PM-->>Holder: Claim allowance recorded
    Holder->>Native: redeem(recipient, amount)
    Native->>PM: unlock(redemption)
    PM->>Native: unlockCallback(data)
    Native->>PM: burn(holder, native claim ID 0, amount)
    Native->>PM: take(native ETH, recipient, amount)
    PM-->>Recipient: ETH payment
    Native-->>PM: Callback complete, NativeRedeemed event
    PM-->>Native: Unlock complete
    Native-->>Holder: Redemption complete

    Admin->>Vault: collect(currency, recipient)
    Vault->>Hook: owner()
    Hook-->>Vault: Current protocol owner
    Vault->>PM: unlock(fee collection)
    PM->>Vault: unlockCallback(data)
    Vault->>PM: Read and burn FeeVault's currency claims
    Vault->>PM: take(currency, recipient, amount)
    PM-->>Recipient: Collected fees
    Vault-->>PM: Callback complete, FeesCollected event
    PM-->>Vault: Unlock complete
    Vault-->>Admin: Collection complete
```

Native redemption requires a positive amount and claim allowance; failed ETH delivery reverts the redemption and restores the claims. Fee collection only redeems FeeVault's balances and is restricted to the current hook owner. It cannot redeem maker escrow.

Sources: [Router](src/Router.sol), [AsyncSwap](src/AsyncSwap.sol), [AsyncMatching](src/libraries/AsyncMatching.sol), [AsyncFiller](src/libraries/AsyncFiller.sol), [NativeClaims](src/NativeClaims.sol), and [FeeVault](src/FeeVault.sol).

## Build and deployment

`AsyncMatching` is an external Solidity library linked into the hook. `script/deploy.sh <chain-key> [dry-run|broadcast|verify]` (wrapped by `script/deploy-arc.sh` and `script/deploy-unichain.sh`) deploys it deterministically through the shared CREATE2 deployer (`script/00_DeployMatchingLibrary.s.sol`), links that address into the hook bytecode, mines the hook salt, deploys the hook and Router, and records everything under `deployments/<chainId>/`. `verify` publishes sources through Sourcify, tries the chain's Blockscout API, and writes standard JSON inputs for manual upload. Set `ASYNC_MATCHING_LIBRARY_ADDRESS` in `.env.deploy` only to link a library deployed another way. The Foundry test runner links the library automatically.

Install dependencies and run the contract suite with:

```sh
forge soldeer install
forge test
```

Run the local block-packing and adversarial gas benchmark with:

```sh
./script/stress-matching-engine.sh
```

The benchmark starts a fresh local Anvil chain with a 30M gas block limit. A run on 2026-10-14 measured:

| Workload | Transactions included | Block gas used |
| --- | ---: | ---: |
| 100 distinct ordinary prices | 100 | 22.29M / 30M |
| Adversarial high-bit radix paths | 83, then 17 next block | 29.04M / 30M, then 8.89M |
| 100 orders, each filling eight makers | 100 | 26.14M / 30M |

These are local measurements, not production-chain guarantees. The adversarial orders stayed pending for the next block instead of reverting; the stress script reproduces all three scenarios.
