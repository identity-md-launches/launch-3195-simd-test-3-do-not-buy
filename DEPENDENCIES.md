# Vendored dependencies

All dependencies are ordinary source files, with no submodules and no runtime package downloads. Upstream source files are unmodified. Only the relevant source directories and license files are retained; upstream tests, build systems and package installations are not needed.

| Directory | Upstream revision | Purpose | License files |
| --- | --- | --- | --- |
| `lib/v4-core` | [Uniswap/v4-core `bea7f6d1c11cd5dc4f0d5151ffa37a1c239feee6`](https://github.com/Uniswap/v4-core/tree/bea7f6d1c11cd5dc4f0d5151ffa37a1c239feee6) | Hook interfaces/math and the real PoolManager in tests; includes the `PoolOperation.sol` types used by the supplied checks | `MIT_LICENSE`, `BUSL_LICENSE`; individual files declare their license |
| `lib/openzeppelin-contracts` | [OpenZeppelin Contracts v5.1.0, `69c8def5f222ff96f2b5beff05dfba996368aa79`](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/69c8def5f222ff96f2b5beff05dfba996368aa79) | Plain ERC-20 implementation | `LICENSE` (MIT) |
| `lib/forge-std` | [forge-std v1.9.6, `3b20d60d14b343ee4f908cb8079495c07f5e8981`](https://github.com/foundry-rs/forge-std/tree/3b20d60d14b343ee4f908cb8079495c07f5e8981) | Test assertions and cheatcode interfaces | `LICENSE-MIT`, `LICENSE-APACHE` |
| `lib/solmate` | [Solmate `89365b880c4f3c786bdd453d4b8e8fe410344a69`](https://github.com/transmissions11/solmate/tree/89365b880c4f3c786bdd453d4b8e8fe410344a69) | Only `src/auth/Owned.sol`, required by the test PoolManager's protocol-fee controller | `LICENSE` defers to per-file SPDX; the vendored `Owned.sol` declares MIT |

The hook and launch token inherit no ownership module. Solmate ownership is used by the external protocol's PoolManager in tests, not either launch contract. All library methods called by the launch contracts are internal and inline; neither artifact needs library linking.

Dependency sources were retrieved from GitHub archive URLs at the exact revisions above. The project pins Solidity 0.8.26, Cancun EVM, optimizer enabled with 200 runs, and `bytecode_hash = "none"` in `foundry.toml`.
