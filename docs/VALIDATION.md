# Recorded validation

Completed 2026-11-10 with Solidity **0.8.26**, Cancun EVM, optimizer enabled (200 runs), and metadata bytecode hash disabled. The exact build configuration is in `foundry.toml`; all imported dependencies are vendored.

## Final checks

| Check | Result |
| --- | --- |
| `forge build` | Passed |
| `forge test` with the assignment's fuzz seed | **47 passed, 0 failed**; the two fork suite setups explicitly skipped because no fork was selected |
| Four fuzz tests | 1,000 cases each: full and partial fills in both currency orderings |
| Stateful invariant campaign | 128 runs × 32 calls = **4,096 calls, 0 reverts**, checking both conservation properties; Foundry groups the two invariants into one reported test entry |
| Explicit Robinhood fork run | **14 passed, 0 failed, 0 skipped**, seven tests per currency ordering |
| `forge fmt --check` | Passed |

Seed used for all final local and fork test commands:

```text
0x76105d90bf01c6e1e5a45c5d3867eecbfd0e53653aa2d95e2c5cd48db02ea12f
```

The invariant handler exercised 1,026 trades, 968 transfer-failure changes, 1,055 redemption calls and 1,047 time/block advances. All outstanding fees were redeemable to the fixed vault once transfers were restored. No test reads or modifies environment variables.

## Robinhood fork evidence

Final source was exercised at:

| Field | Value |
| --- | --- |
| Chain ID | 4663 |
| Block | **111250446** (`0x6a18c0e`) |
| Block hash | `0xbd03ab6ceaaa21996d0fc50d905b569666eb5c9beddad40e7a587178efa92e10` |
| RPC used | `https://rpc.mainnet.chain.robinhood.com` |
| Pair contract | `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` |
| Pair checks | Deployed code present, symbol `IMD`, decimals 18 |

Each ordering ran exact-input and exact-output buys and sells, rate invariance/failed redirection attempts, partial fills in all four modes, and a fresh manager holding only launch tokens that deferred a fee and then redeemed it to the vault. Direct-transfer cases asserted **actual IMD balance increases at the vault** and zero deferred fees, rather than merely inspecting an event or mocked call. Settlement and conservation assertions execute in the shared fixture.

These tests deploy new instances of the genuine vendored v4 PoolManager and the two launch contracts within a Robinhood fork. They exercise the deployed IMD implementation using a test-funded trader balance. They do not replace IMD code, submit transactions, use a funded wallet, test the existing vault's distribution logic, or claim to rehearse the production factory.

Earlier runs also passed at block 111241496. During the final rerun, the official public RPC returned `historical state ... is not available`; a second public endpoint returned `block reference is outside the public history window`. The final run therefore used the newer pinned block above and passed all 14 cases. Historical reproduction requires an archive-capable provider. The default offline suite does not contact either endpoint.

## Deployment artifacts

| Artifact | Creation bytecode | Runtime bytecode | External library links |
| --- | ---: | ---: | --- |
| `TestHook` | 7,097 bytes | 6,233 bytes | None |
| `TestToken` | 2,704 bytes | 1,793 bytes | None |

Both runtimes are below the EIP-170 limit. Tests deploy the hook with actual CREATE2 address mining and validate its `0x20cc` permissions. Runtime scans reject reachable delegatecall, callcode and selfdestruct opcodes using the supplied floor's approach.

Foundry's advisory source lint still reports explicit signed/unsigned conversions, event emission following external calls, unused empty unlock return data, and a quote-result local assigned through assembly. These paths were reviewed: sign branches and checked fee casts bound the conversions; manager calls are checked/revert or deliberately caught; events describe the completed payment; the unlock returns no application data; and only a strictly decoded quote assigns the executed amount, with all other paths reverting. These warnings are not compiler errors. No static-analyzer or independent-audit pass is claimed.

The supplied protected tests were read as acceptance definitions. Their external attestation harness and environment-driven creation-code inputs are not shipped or impersonated here; equivalent permission, authorization, initialization, ownership, supply, runtime and factory-fee-collection behavior is covered by the delivered tests. The network verifier remains responsible for running its protected checks on the final attested artifacts.
