# SIMDTEST3 test coverage

The token is a valueless rehearsal token. DO NOT BUY.

Run `forge build` and `forge test`. For the assignment's reproducible fuzz input, run:

```sh
FOUNDRY_FUZZ_SEED=0x76105d90bf01c6e1e5a45c5d3867eecbfd0e53653aa2d95e2c5cd48db02ea12f forge test -vv
```

The fork suite reads `ROBINHOOD_RPC_URL` and selects Robinhood block **111252324** itself. The value may be a URL or socket path. No command-line fork flags are needed. Only an empty variable skips these tests; a required state read that Foundry cannot complete fails the suite. Foundry can recover from an unsupported optional RPC method, as described below. To check the offline fallback in a separate process, run `env -u ROBINHOOD_RPC_URL forge test`.

The RPC header at the pinned height has `l1BlockNumber = 26387701`, which Foundry exposes through Solidity's `block.number`. Fork selection uses the Robinhood block above. Fork tests never roll to another block. Timestamp comparisons use the same pinned state; block-number variation is tested offline.

| Suite | Additional coverage |
| --- | --- |
| `fork/RobinhoodFork.t.sol` | Live IMD transfers in both currency orders; all four swap modes; fee rounding boundaries; unchanged rate and destination after time advances and rejected admin calls; insufficient input settlement rollback; invalid swaps; stolen/overdrawn/repeated claim redemption attempts; unpaid batch rollback and retry. |
| `HookAtomic.t.sol` | Four-mode batches compared against separate transactions from the same snapshot, with 1,000 fuzz cases per ordering; reverting/false-returning vault transfers; failed batch rollback; retry within the same transaction; nested redemption refusal; claim backing after full LP withdrawal; fee event amounts checked against balances. |
| `HookInvariant.t.sol` | Both currency orders, each with 256 sequences of 64 calls. Trades, time/block advances, vault transfer failures, valid/invalid redemption, claim theft attempts, liquidity changes, and LP fee collection are interleaved. Invariants check conservation, fixed supply, IMD claim backing, and cumulative fees equal vault receipts plus pending claims. Remaining claims must all redeem after each sequence. |
| `helpers/AtomicSwapActor.sol` | A prefunded test router that checks hook deltas during each swap, then checks settlement and relocking before the enclosing transaction ends. |

The existing offline swap, token, failure-path, and single-sided launch tests remain in place. No new dependencies are required.

Local validation with the seed above: `forge build` succeeded; the full run passed **84 tests**, including **24 fork cases**, with no failures or skips. Without `ROBINHOOD_RPC_URL`, **60 tests passed** and the **two fork suites skipped** in setup. Each invariant suite executed 16,384 handler calls with no unexpected reverts. No reproducible implementation defect was found in these checks.

The reported external check failure is still an RPC compatibility blocker, despite those passing test results. It records an unsupported `eth_getAccountInfo` request as a failed fork check. Reproduction with RPC caching disabled also passed all **24 fork cases**, while Foundry's backend trace confirmed that its initial `eth_getAccountInfo` probe failed and it continued with standard account requests:

```sh
FOUNDRY_FUZZ_SEED=0x76105d90bf01c6e1e5a45c5d3867eecbfd0e53653aa2d95e2c5cd48db02ea12f forge test --no-storage-caching --match-path test/fork/RobinhoodFork.t.sol -vv
```

This request originates in Foundry, not the Solidity tests. The [fork backend used by Forge 1.8.3](https://github.com/foundry-rs/foundry-core/blob/327739f0d2b848725b462271276f27aecd8b8ff9/crates/fork-db/src/backend.rs#L356-L413) initially races `eth_getAccountInfo` against `eth_getBalance`, `eth_getTransactionCount`, and `eth_getCode`; an unsupported probe switches it to the standard requests. The [account-fetch policies](https://github.com/foundry-rs/foundry-core/blob/327739f0d2b848725b462271276f27aecd8b8ff9/crates/fork-db/src/cache.rs#L35-L47) provide automatic probing or mandatory `eth_getAccountInfo`, with no standard-requests-only policy. The method rejection alone therefore does not demonstrate missing archive state.

The external gate needs to distinguish a recovered optional-method probe from an unsuccessful required state read, or its RPC adapter must support the probed method. There is no test-only repair for that backend behavior while retaining the required live fork. The tests remain pinned to the specified block, preserve live IMD bytecode, and skip only for an empty RPC variable. No contract defect is claimed from this infrastructure error.

Fork tests use the deployed IMD code and balances at the pinned block, with test funding for their traders. They deploy the project's token/hook and the vendored v4 PoolManager into that fork. They do not replace live IMD bytecode, broadcast transactions, or claim to exercise a production launch factory or an already deployed SIMDTEST3 pool. The supplied vault's weekly distribution and the separate remainder claim contract are outside this implementation and this suite.

The fee oracle uses executed gross IMD and actual vault/claim balance changes. It also checks the static v4 fee of 12500 and that the launch token is not taxed. The configured 0.75% hook and 1.25% LP rates act on their respective swap amounts; the tests do not assume both are deductions from one common base.
