# SIMD TEST 3 — DO NOT BUY

**This is a valueless test token, not a real coin. It must not be bought.**

This Foundry project implements the SIMDTEST3 launch token and its immutable Uniswap v4 fee hook on Robinhood Chain, chain ID **4663**. The hook sends a **0.75% fee in IMD** to the supplied SIMD Test Vault. It never converts fees into ETH.

There is no owner, admin, setter, proxy, upgrade, pause, blocklist, mint entry point, anti-sniper tax, or time/block-dependent behavior in either deployed contract. Only two contracts are launch artifacts: `TestToken` and `TestHook`. Contracts under `test/` are test scaffolding.

## Deployment parameters

| Item | Fixed value or launch-supplied parameter |
| --- | --- |
| Token artifact | `src/TestToken.sol:TestToken`, no constructor arguments |
| Name | `SIMD TEST 3 - DO NOT BUY` |
| Symbol | `SIMDTEST3` |
| Decimals | 18 |
| Supply | 1,000,000,000 tokens = `1000000000000000000000000000` minor units |
| Initial holder | The deploying factory, `msg.sender`; this confers no privileges |
| Logo | `https://www.si-md.xyz/logo.jpg`, also exposed as `LOGO_URI()` |
| Hook artifact | `src/TestHook.sol:TestHook` |
| Hook constructor | `(IPoolManager manager_, address token_)` = `($poolManager, $token)` |
| Pair | IMD, `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` |
| Vault | `0x8Fe1805a83bCF70F514bC716Cd88C05051d6fF21` |
| Hook fee | `75 / 10000`, fixed forever |
| Pool LP fee | `12500 / 1000000` = 1.25%, static |
| Tick spacing | 60 |
| Hook permission mask | `0x20cc` = 8396, within the low 14 address bits |
| Compiler / EVM | Solidity 0.8.26 / Cancun |

The manager and token are immutable constructor arguments, not hardcoded deployment addresses. The constructor performs no external calls or code-existence checks. It rejects zero parameters, IMD as the launch token, and an address with incorrect hook permission bits. Neither constructor takes an owner or a private key.

The launch deployer must deploy the token first, mine a CREATE2 salt for the **actual factory, creation code and encoded constructor arguments**, deploy the hook, then initialize the pool in the same launch transaction. The required relationship is:

```text
uint160(hookAddress) & 0x3fff == 0x20cc
```

Both sorted currency orders are supported. The hook accepts only the pool containing this exact launch token and IMD, with this hook, fee 12500 and tick spacing 60. `beforeInitialize` prevents opening its predicted pool while hook code is absent. It imposes no sender or initial-price restriction; the launch factory can initialize at the opening price derived from the policy's 2,500 IMD market cap. The one-to-one price used in local tests is only a test fixture.

The factory handles all allocations: 10% to its MerkleDistributor, 26.69% to liquidity, and 63.31% to the supplied remainder/claim destination `0xD68114FC3359F93Ccc93BeE90229ac366bC173bE`. The token mints the entire supply once to the factory, without deductions or reservations. The hook receives no launch allocation. This project does not implement the existing vault, weekly splitting, staking, swarm jobs, a claim contract, or a launch manifest.

## Exact fee accounting

The fee is **`floor(gross executed IMD × 75 / 10000)`**, rounded down to IMD minor units. On a buy, gross IMD is the trader's input including the hook fee. On a sell, gross IMD is the pool output before the hook fee. Transfers outside this pool have no token tax. Trades below the rounding threshold can owe zero fee.

Let `A` be the requested amount, `C` the IMD amount actually used/produced by the AMM, and `F` the hook fee:

| Swap | Accounting |
| --- | --- |
| Buy, exact IMD input | Reserve `floor(A × 75 / 10000)` from the budget. On a full fill, the user spends exactly `A`. On a partial fill, charge only `floor(C × 75 / 9925)` and leave unused input with the router. |
| Buy, exact token output | Return an IMD input fee of `floor(C × 75 / 9925)`. Preserve the requested token output when liquidity permits. |
| Sell, exact token input | Deduct `floor(C × 75 / 10000)` from actual IMD output. |
| Sell, exact IMD output | Request gross pool output `A + floor(A × 75 / 9925)` and deduct 75 bps of actual gross output. A full fill delivers exactly the requested net IMD. |

For the two modes specifying IMD, `beforeSwap` needs the executed amount before committing a specified-currency delta. It obtains that amount using a **self-only, deliberately reverted simulation** of `PoolManager.swap`. Uniswap suppresses this hook's callbacks for that internal call. The revert rolls back pool state, LP/protocol fees, logs and transient deltas. The real swap then executes normally. This avoids charging unfilled orders and empty pools. It costs an extra pool traversal in those two modes.

A transient slot carries the specified fee into `afterSwap` and is cleared **before** any token transfer. For the other two modes, `afterSwap` calculates the fee directly from the real swap delta. The hook never charges the launch token, changes the LP fee, decodes caller-controlled fee settings, or replaces the AMM with a no-op swap.

**The two configured rates sum to a nominal 2%.** They do not represent a flat 2% deduction from the same amount: v4 charges its LP fee on AMM input, and this hook charges the IMD side. For example, a full 100 IMD exact-input buy pays 0.75 IMD to the vault and 1.240625 IMD in LP fees (1.25% of the remaining 99.25 IMD), before price impact. On sells the LP fee is in SIMDTEST3 and the hook fee is in IMD. Neither rate is adjusted to disguise this composition. Additional protocol fees, if enabled by the external PoolManager's governance, and price impact are outside the hook's control.

## Liveness and unpaid fees

The hook tries to send IMD directly from the manager to the fixed vault within the swap. On a fresh manager, the buy's input may not have been settled yet. IMD could also refuse a transfer to the vault. A failed `take` is caught, and the same fee becomes an ERC-6909 **IMD claim held by this hook on that manager**. The real swap can finish and settle normally; the fee is neither waived nor converted.

Anyone can read `pendingFees()` and call `redeemFees(amount)` once sufficient transferable IMD is available. Redemption unlocks the manager, burns that amount of the hook's own IMD claims and transfers IMD **only to the fixed vault**. There is no recipient argument, bounty, operator role, or configurable destination. It supports partial redemption, up to `type(int128).max` per call. A failed or excessive redemption is atomic and preserves all claims. It cannot be nested in an existing manager unlock.

Valid, funded swaps have no hook gate based on the trader, router, time, block, or vault availability. Core v4 constraints still apply: invalid price limits, inadequate settlement, insufficient gas and unrepresentable deltas can revert. Exact-output targets whose gross-up would exceed signed `int256` are explicitly rejected instead of wrapping into exact input. Transfers needed for the underlying trade must work; no hook can make a paused or otherwise nontransferable pair token settle. The compatibility assumption is the supplied IMD's normal ERC-20 transfer behavior, verified on the recorded fork. Rebasing or transfer-tax changes in an external token are not supported.

## After launch

- **Setters: none.** No setup transaction, fee switch, privileged key or ownership transfer exists.
- The launch service supplies and verifies the real PoolManager and token arguments, mines the hook address, opens/seeds the pool, performs policy allocations, and publishes verified source and addresses. This assignment broadcasts no transaction.
- The existing vault's operators are responsible for its weekly staker/swarm/dev/marketing distribution. This hook only delivers IMD to its fixed address and does not call or validate that separate distribution logic.
- Any participant may monitor `FeePaid`, `FeeDeferred`, `FeesRedeemed` and `pendingFees()`. If a fee is deferred, someone must submit `redeemFees` after the manager can pay it; there is no automatic timer or keeper privilege. Ordinary swaps do not require outstanding claims to be redeemed first.
- Routers must account for returned hook deltas and enforce their usual maximum-input/minimum-output conditions. They must settle all currencies before relocking the manager. LP fee collection with a zero liquidity change and full LP withdrawals remain available; no liquidity callback is enabled.
- There is no rescue or sweep function. Do not send unrelated assets directly to the hook. The logo URL is fixed in the token, but the external image host controls the image served there.

## Build and test

All Solidity dependencies are vendored as ordinary files under `lib/`; no network install, submodule, FFI, filesystem cheatcode permission, or environment variable is needed for the default suite. Foundry needs its installed Solidity 0.8.26 compiler. See [DEPENDENCIES.md](DEPENDENCIES.md) for exact upstream revisions and licenses.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x76105d90bf01c6e1e5a45c5d3867eecbfd0e53653aa2d95e2c5cd48db02ea12f forge test
forge fmt --check
```

The offline suite uses the real vendored v4 PoolManager with a local IMD stand-in. It exercises both currency orders and all four swap modes; fuzzes complete/partial fills; checks dust, empty liquidity, tick crossing, huge requested input, unchanged rates over time, authorization failures, immutable recipients, transfer failures, claim redemption, factory fee collection, and token conservation. Stateful invariants randomize trades, transfer failures, redemption and time/block changes.

Fork tests use the **live deployed IMD implementation and state**, with a new real v4 PoolManager, hook and launch token deployed only inside the fork. The test trader's IMD balance is funded with Foundry's `deal`; token code is never replaced on the fork. These tests do not impersonate the production factory or claim to test an already deployed SIMDTEST3 pool. They deliberately report a skip when no fork was selected, so the offline verifier needs no network and the fork results remain distinguishable.

The public endpoint is published in [Robinhood's connection documentation](https://docs.robinhood.com/chain/connecting/). Reproduce the recorded fork run with:

```sh
FOUNDRY_FUZZ_SEED=0x76105d90bf01c6e1e5a45c5d3867eecbfd0e53653aa2d95e2c5cd48db02ea12f \
  forge test --match-contract 'Robinhood.*ForkTest' \
  --fork-url https://rpc.mainnet.chain.robinhood.com \
  --fork-block-number 111250446 -vv
```

The public RPC prunes historical state: replaying that precise block later requires an archive-capable RPC supplied with `--fork-url`. For a fresh rehearsal on the public endpoint, select a recent block instead. Neither the tests nor the contracts depend on an RPC URL or environment variable stored in the project.

Both sorting orders are exercised on the fork. See [docs/VALIDATION.md](docs/VALIDATION.md) for recorded results and [docs/SECURITY.md](docs/SECURITY.md) for the scoped review and remaining trust boundaries. The local review and tests are not an independent security audit.
