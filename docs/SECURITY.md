# Scoped implementation review

This is a local design/code review, not an independent audit. Scope: `TestHook`, `TestToken`, their deployment parameters and accounting tests. The external IMD token, vault, chain, launch factory and PoolManager have their own trust models.

## Authority and lifecycle

- Only the immutable PoolManager can call the three enabled callbacks and the redemption unlock callback. The swap simulation accepts only the hook itself and always reverts; outsiders cannot use it to execute a swap with suppressed hooks.
- The entire pool identity is immutable: sorted token/IMD currencies, fee 12500, spacing 60 and this hook address. The hook checks it at initialization and on both swap callbacks. No first-caller binding, allowlist or mutable registry exists.
- The constructor validates address permission bits. The enabled mask is exactly `0x20cc`: `beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, `afterSwapReturnDelta`. All liquidity/donation callbacks are absent. Initializing a predicted hook address with no code fails on the mandatory initialization callback.
- No function exposes ownership, configuration, arbitrary calls, approvals, delegatecall, selfdestruct, token minting after construction, asset sweeping or a recipient override. Callback `sender` and `hookData` cannot change the fee or destination.
- The token uses the unmodified OpenZeppelin ERC-20. Its only mint is the constructor's 10^27 minor units to its deployer. Ordinary transfers preserve the amount and total supply.

## Value conservation

For gross executed IMD `G`, the fee `F = floor(75G/10000)`. The hook delta is always positive in IMD and zero in SIMDTEST3. For buys with pool input `C`, `F = floor(75C/9925)` ensures `F = floor(75(C+F)/10000)`; full exact-input buys additionally consume the requested budget, including its rounding dust. Exact-output IMD sells gross up the target before the swap and deduct the fee afterward.

Each fee creates exactly one negative hook delta through `take` or `mint`. The corresponding returned swap delta credits the hook by the same amount, leaving no unsettled hook balance. Immediate payout transfers the token directly from manager to vault. Deferred payout mints a manager IMD claim to the hook. Redemption burns only the hook's own claims and takes the same currency to the same vault, netting to zero. A failed `take` rolls back its transfer and accounting before the fallback mint executes.

The live amount must be known before returning a specified-currency delta. A reverted inner swap provides that amount without finalizing any state; the manager's documented self-call suppression prevents recursion. A strict 36-byte `QuoteResult` is decoded; unrelated errors are bubbled. This adds execution cost on the IMD-specified paths. No persistent pool mutation, fee growth, transfer or approval survives a quote.

For a price-limited partial input fill, reducing the precharged fee only increases the remaining pool budget; it cannot move execution beyond the same price/liquidity limit. For a partial exact output, the reduced gross target still covers the amount available before that limit. Tests cover both arguments, zero fills, dust rounding, multiple tick ranges and unchanged LP fee growth after a quote.

Fees use full-precision multiplication/division. Amounts from v4 are widened from int128 before taking their absolute value, including `int128.min`. Input magnitudes also handle `int256.min`. Output gross-up is checked against `int256.max`; fee returns use checked int128 casts. The final user deltas remain subject to v4's int128 representability limits. These are arithmetic limits, not trade limits configured by an administrator.

## Failure paths and interactions

The transient fee slot is cleared before transferring IMD. A later swap in the same unlock starts by writing its own slot value, including zero for unspecified-IMD modes. The hook has no external-call-before-persistent-state-update pattern for user balances. Redeeming during another unlock fails at the manager; claims are burned before the token transfer and restored by rollback if that transfer fails.

Immediate vault transfer failure is isolated with `try/catch`. Insufficient physical manager IMD, a reverting transfer and a false-returning transfer all produce an IMD claim, keeping a valid underlying swap live. There is no exception route to another recipient or token. A failed redemption does not become a prerequisite for later swaps. Tests check these paths and eventual redemption of all accumulated fees.

There is no generic protection against arbitrary future changes to external IMD behavior, chain censorship, a malicious substituted PoolManager, or exhaustion of the transaction's gas. The quoted simulation assumes the standard v4 implementation and its self-call suppression. Deployment must supply the genuine manager and verify chain/token identity. A protocol-fee controller belongs to the external manager and can affect protocol trading costs; this hook has no control over it. Fee-on-transfer/rebasing IMD implementations would violate accounting assumptions and require a new reviewed design.

## Validation boundaries

Local integration/fuzz tests use an actual v4 PoolManager, not mocked swap accounting. Handler invariants check token conservation and that all fees equal vault receipts plus unpaid manager claims across randomized operations. Fork tests exercise live IMD transfers in both sorting orders. Runtime scans use the supplied checks' reachable-opcode approach to detect delegatecall/callcode/selfdestruct, and selected forbidden administrative selectors are rejected.

No Slither, Mythril, formal verification, independent contributor audit, production factory transaction or existing vault-distribution audit is claimed. The deployment service must perform its independent review and full factory rehearsal before launch. Weekly distribution and remainder claims remain external responsibilities.
