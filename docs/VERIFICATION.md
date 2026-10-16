# Verification record

Final local run: **2026-10-16**, Foundry **1.8.3**, solc **0.8.26**, optimizer **200**, Cancun. These are contributor checks, not independent launch authority or a security audit.

| Check | Result |
| --- | --- |
| `forge build` | Pass |
| `forge test -vv` | **56 passed, 0 failed, 0 skipped**, seven suites |
| `forge fmt --check` | Pass |
| ABI-to-artifact comparison | Both committed ABI arrays exactly match the compiled artifacts |
| Creation/runtime size | HamsterHour **21,586 / 20,850 bytes**; OracleVerifier **3,148 / 2,978 bytes** |
| EIP-170 / EIP-3860 limits | Both runtimes below 24,576 bytes, creation payloads with arguments below 49,152 bytes |
| Library linking | No creation-bytecode link references |
| Runtime opcode rehearsal | No DELEGATECALL, CALLCODE or SELFDESTRUCT; PUSH payload bytes skipped as in the protected floor |
| Factory-style deployment | CREATE2 rehearsal with real documented signer/TEAM, static constructor arguments, zero ETH |
| Oracle compatibility | Independent protocol digest/signature vector, plus a real signed Squeekchain uint256 result and canonical question hash |

Both fuzz tests use **512 runs**, with seed `0xe427f6772b7230d5c85541af762798b7daf4fd8f75c5b62f29396f55b3ec9cb1`. The accounting suite runs **128 sequences × 64 actions = 8,192 actions**, checks two invariants after actions, and reports **zero handler reverts** with `fail_on_revert = true`. Foundry reports that invariant group as one test. Each sequence is drained afterward to check that unclaimed principal/prizes are not stranded and only explicit reserves and bounded staking dust remain.

## Coverage

| Suite | Meaningful checks |
| --- | --- |
| `Markets.t.sol` | Three independent pools, binary weight math and conservation fuzzing, fee totals, one-sided and equal-line refunds, EXACT equal ties and absent ranks, entry minimum/duplicate/late failure, deadline/refund boundaries, reimbursement shortfall/funding, no reimbursement for fee-less settlements, empty-window rejection, 256-ticket settlement. |
| `ExactFuzz.t.sol` | Arbitrary full-width uint256 guesses/results; streaming rank output compared with an independent insertion sort; all winning payouts sum to the exact market allocation. |
| `Oracle.t.sol` | Early/predated (any issuedAt before window end)/future/expired messages, malformed answers, wrong chain/consumer/question/window, invalid signer/signature encoding/high-s, weak/inconsistent panels, bad block range, replay, front-run preconsumption rejection, atomic retry, EIP-7702 signer code, published conformance fixtures and exact question text. |
| `Configuration.t.sol` | Clock/genesis boundaries, seven-result rolling line and frozen snapshots, max-uint averaging, all eight TEAM-only methods, mismatched/early/replaced/replayed settings, one-shot tokens, input validation, no reopening of past windows, earlier genesis closes existing windows whose corrected start passed, constructor behavior without deployed dependencies. |
| `StakingJackpot.t.sol` | Unset/set staking, settlement-time weights and claims after unstaking, 30 release tranches, no-stake backlog, shared-currency custody, earlier unclaimed prizes, equal ties and residual units, no-EXACT/lone-ticket/timeout rollover (lone ticket cannot take a jackpot ahead of a contested window), failed payouts/retry and IMD-only fallback, taxed/false-return/non-returning tokens, reentrancy error verification. |
| `AccountingInvariant.t.sol` | Random bets, stakes, unstakes, settlements, expirations, reserve donations, jackpot donations and claims. Independent sum of outstanding claims/reserves cannot exceed IMD liabilities; token balance backs IMD liabilities, staking principal and jackpot promises simultaneously; final drain checks. |
| `Deployment.t.sol` | Factory deployment, actual parameter ownership, bytecode size and instruction-level forbidden-opcode checks. |

The maximum-entry EXACT test measures approximately **1,506,768 gas** for its settlement call after `vm.cool` on the application and verifier. This is a local EVM measurement, not a production gas guarantee; the test requires it below 8 million. Claims and staking have no participant-count loops. Successful settlement scans at most 256 guesses. The deployment test's overall gas includes its per-byte assertion loop and is not the factory's deployment gas estimate.

## Repairs and limits

Local adversarial review identified and fixed a tiny-jackpot claim issue: after IMD-only claims, zero-rounded tied jackpot shares must still be acknowledged so the last winner can claim the remaining unit. Its regression test uses a one-unit prize split between two closest tickets. The optional jackpot balance read also bounds both callee gas and copied return data, so a broken prize token cannot prevent market settlement.

Forge's build lints were reviewed. Timestamp checks implement the requested timed windows and timelocks; ERC-20 and verifier calls are guarded, their effects revert atomically on failure, and configuration emits generic keyed events that the lint does not associate with individual storage fields. Narrow casts for window times follow explicit uint64 bounds. No Slither, Mythril, independent audit or paid live oracle request was run.

The supplied protected tests are service-driven: their environment and owner harness are supplied at manifest/review time. They were read, not edited or falsely reported as executed here. Local deployment tests rehearse the relevant constructor, bytecode and ownership properties without requiring those service inputs. Tests make no network calls, read no environment variables, use no filesystem/FFI cheatcodes, and do not depend on external time or test order.

The free oracle template check returned no blockers but a `not_answerable` advisory. A real historic fixture proves cryptographic/schema compatibility; it does not prove a newly purchased six-round result will arrive. Keepers must verify source availability. The independent review and later deployment simulation remain required workflow stages.
