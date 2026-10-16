# Hamster Hour

No owner, no house: pari-mutuel only, with results only from the IMD oracle. The contract never owes more than it holds under the supported ERC-20 assumptions below. TEAM gets 1% of non-void bets and nothing else as a privileged beneficiary. It cannot withdraw deposits, reserves, stakes or jackpots. TEAM has only the four public, 48-hour-delayed configuration powers required by the brief. There is no upgrade, pause, token mint, ownership transfer or emergency withdrawal.

This repository delivers the contract stage: `HamsterHour`, `OracleVerifier`, offline Foundry tests, and [ABI exports](docs/ABI.md). Independent review, `launch.json`, source publication, attestation, factory deployment and the website belong to subsequent workflow stages. No deployment has been broadcast.

## Build and test

```sh
forge build
FOUNDRY_FUZZ_SEED=0xe427f6772b7230d5c85541af762798b7daf4fd8f75c5b62f29396f55b3ec9cb1 forge test
forge fmt --check
```

Solidity **0.8.26**, Cancun, optimizer 200 runs, metadata bytecode hash disabled. Dependencies are ordinary vendored source files; no network, environment variables, FFI or filesystem cheatcodes are required by the tests. The same fuzz seed is pinned in `foundry.toml`. See [verification coverage](docs/VERIFICATION.md) and [dependency provenance](docs/DEPENDENCIES.md).

## Deployment parameters

Deploy in this order through the launch factory, with zero ETH:

| Contract | Constructor arguments, in order |
| --- | --- |
| `OracleVerifier` | `signer_ = 0x5598aa9146215bc13eb26f2c692ad1461fd32982` |
| `HamsterHour` | `team_ = $owner`, `verifier_ = $contract:OracleVerifier` |

`$owner` is the supplied launch wallet **0x6cba4751742f6989fa224b2dc5d5d52fcef98a34**. It becomes immutable `TEAM`; neither the factory nor the launch service receives a role. Both constructors are nonpayable, use static address arguments, and make no calls to dependencies. The table is guidance for the separate manifest assignment, not a manifest.

Chain: Ethereum mainnet, id **1**. IMD is fixed at **0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7**; its `symbol()` and 18 `decimals()` were confirmed by Ethereum reads. The signer was obtained from the [public IMD oracle API](https://api.imd.fun/oracle/requests?limit=1), confirmed against [IMD's published protocol reference](https://api.imd.fun/reads/skill/oracle-consumer) and a real signed Squeekchain result. This is an external oracle key, not TEAM. There is no signer rotation because the approved game allows no additional administrative powers. A signer/protocol change requires a new release; existing unanswered windows retain their refund path.

## Windows and bets

Genesis is **1791847800** (2026-10-12 23:30:00 UTC). Each round lasts **600 seconds**; window `k` covers rounds `6k` through `6k+5` and lasts **3600 seconds**. Bet strictly before its start, settle at or after its end, and refund from exactly **48 hours** after its end if it remains unsettled. Before genesis, `currentRound()` and `currentWindow()` return zero and `hasStarted()` is false.

The first bet creates a window and snapshots its start, end, source URL and line. Later settings do not change it. An update to genesis cannot reopen an uncreated window that already started under the previous schedule. Use `windowTimes(k)` to read a created window's actual schedule. Empty windows are never settled and never enter the result history.

Approve IMD to `HamsterHour`, then call `betOverUnder(k, over, amount)`, `betExact(k, guess, amount)` or `betSleep(k, sleeping, amount)`. The minimum **per call** is **0.5 IMD** (`5e17` units). Binary bets can be added on either side. EXACT accepts one immutable ticket per address/window, with a `uint256` guess. Tickets cannot be cancelled or changed.

The line is **1000** until seven windows have successfully settled, then the floored mean of the last seven results **in settlement order**. All successful nonempty settlements count, including ones whose binary markets refund; timeouts do not. A pre-created future window keeps its earlier line. There is no betting horizon, so participants should inspect that snapshot before betting.

## Payout rules and resolved edge cases

Each market has its own pool. An OVER/UNDER or SLEEP pool with only one funded side refunds **100%**, without fees. OVER/UNDER also refunds when the result equals the line: neither strictly above nor strictly below wins. EXACT is not a binary market, so the one-sided rule does not apply to it. A timeout refunds every bet in every market, without any fee or jackpot allocation.

For each remaining market, settlement allocates **5% to staking, 3% to the oracle reserve, 1% to TEAM and the remaining 91% to winners**. Fees round down to whole token units, and the fractional remainder stays with winners. Binary winners share pro rata by their winning stake. The last winning claimant collects that market's rounding remainder, so all winner funds can leave.

EXACT ranks **distinct absolute distances** from the result. First, second and third tiers receive **60%, 30%, 10%** of that market's winner allocation. All tickets in the same tier split it **equally**, irrespective of amount; the last claimant in a tier collects rounding dust. Missing tiers roll their allocations into first: one tier gets 100%, two get 70%/30%. This resolves the brief's unspecified fewer-than-three case. The closest tier also shares the jackpot equally. One ticket/address is not Sybil resistance; one person can buy tickets through multiple addresses. A larger EXACT stake does not buy a larger tied payout.

`claim(k)` pays the caller's market proceeds/refunds, any earned TEAM fee or settlement reimbursement, and its jackpot. Claims never expire. `claim(k, false)` pays only IMD, allowing IMD recovery when an optional prize token rejects transfers; a subsequent `claim(k)` can collect the prize. At the refund deadline, `claim(k)` also finalizes the timeout automatically. Losers have no payout, and duplicate claims fail. A zero-unit share of a tiny tied jackpot can still be acknowledged so the last winner receives its residual unit.

## Oracle operation

Anyone may purchase and submit an attestation. There is no backend signer, direct Squeekchain oracle, Intake callback, or contract-funded request. A keeper pays the external oracle itself and calls `settle(k, attestation, signature)` before the 48-hour deadline. See [the exact request and verification procedure](docs/ORACLE.md).

The contract checks the canonical IMD v2 typed data, caller-domain signature, chain, canonical question hash, answer encoding, validity, replay and panel thresholds. The signer and oracle panel remain the source of truth; the contract cannot inspect the physical wheel. It requires a panel of at least **5**, quorum at least **4**, and `agreed >= quorum`, with `agreed <= panelSize`. There is a **300-second** clock tolerance, including for issuance relative to the window end. Signing the wrong question, domain, source, round range or answer type cannot move funds.

The oracle reserve reimburses exactly **0.5 IMD** to the first successful settlement caller, through `claim(k)`. It reserves that amount at settlement when funded. If insufficient, settlement still succeeds and the reimbursement is deferred until reserve funds are available; it never draws from refunds or prizes or records an unfunded token liability. Anyone can donate specifically with `fundOracleReserve(amount)`. A later `claim(k)` by that settler can reserve and collect the full amount. Deferred reimbursements compete for available reserve funds; no ordering is promised. Reimbursement goes to the transaction caller, not the purchaser named in an off-chain receipt, so public attestations and mempool transactions can be copied.

The initial source is `https://sepolia.squeekchain.com`. The free IMD preflight accepted the exact template with **no blockers**, but returned a `not_answerable` advisory for the sampled rounds. This is not proof that records will be available. Keepers must verify all six published results exist, use the snapshotted source and exact question, and stop spending on unanswered windows at their deadline. Nobody must run a keeper for users to recover timeout refunds.

## Staking and reserve release

Staking opens only after the one-shot token setting is executed. `stake(amount)` pulls that token, `unstake(amount)` returns principal, and `claimStaking()` pulls earned IMD. There is no lock period. Weight is the amount staked **at settlement**, not stake duration. This deliberately permits just-in-time stake and flash-loan competition for a distribution; no holding-period economics were added.

Rewards use an accumulator with precision **1e27**. Each account checkpoints on stake changes and claims; it cannot claim distributions from before its entry. Before configuration, the 5% share accumulates in `preStakingReserve`. Configuration freezes that amount as `releaseTotal`. It releases in **30 equal cumulative fractions**, rounding each cumulative fraction down and releasing the remainder by tranche 30.

Because windows are lazy, “30 windows after setting” is implemented as the first **30 successful nonempty settlements whose snapshotted end is after activation**, in settlement order. Empty windows, timeouts, and already-ended windows settled after activation do not consume tranches. If no stake exists, both current rewards and released tranches accumulate in `stakingUndistributed`; the next settlement with stake distributes the backlog. Staking alone does not distribute a backlog. Accumulator/checkpoint dust remains reserved in the contract with no withdrawal authority.

## Jackpot and token assumptions

ERC-20 transfers into the contract are donations unless they use a betting, staking or reserve-funding function. Only the one-shot jackpot token is paid as a jackpot. Other directly sent tokens remain held, potentially forever: there is no sweep or rescue power.

At settlement, the next EXACT prize is that token's **entire free balance**, excluding every pending claim and, if currencies overlap, IMD liabilities and staking principal. Earlier unclaimed jackpots are reserved, never re-awarded. A settled window without EXACT bets leaves the jackpot for a later window; an empty jackpot pays nothing. All tied closest tickets share the reserved amount, through pull claims. Donations arriving after settlement belong to a future jackpot.

Configured tokens must be honest, non-rebasing ERC-20s with exact transfer amounts. Non-returning tokens are supported. Fee-on-transfer deposits and tokens reporting success without moving funds are rejected. A token that later confiscates, rebases, lies about balances, charges outgoing fees or blocks transfers is outside this solvency assumption. An unreadable jackpot balance is skipped without blocking settlement; a failing jackpot transfer can be bypassed with the IMD-only claim overload. TEAM must inspect token behavior before its irreversible choice.

## After launch

Only TEAM schedules and executes settings; execution requires the exact scheduled value and **48 hours** of delay. Scheduling a replacement restarts the delay. Both phases emit the value publicly. There is no cancellation, upgrade or other setter.

| Setting | Schedule, wait, then execute | Value and source |
| --- | --- | --- |
| Staking token, once | `scheduleStakingToken(token)` → `setStakingToken(token)` | TEAM's chosen deployed staking token, obtained from that token's official deployment record. No address was specified in this brief; staking is intentionally closed until set. |
| Jackpot token, once | `scheduleJackpotToken(token)` → `setJackpotToken(token)` | TEAM's chosen deployed prize token, obtained from its official deployment record. No address was specified; no jackpot is assigned until set. |
| Source URL | `scheduleSourceUrl(url)` → `setSourceUrl(url)` | Public Squeekchain result source. Initial value is the supplied console; a correction can use its official `/status` page. HTTPS, printable ASCII, no quotes/backslashes/spaces, at most 256 bytes. |
| Genesis | `scheduleGenesisTimestamp(timestamp)` → `setGenesisTimestamp(timestamp)` | A corrected round-zero timestamp from Squeekchain's official record. Initial value is the supplied 1791847800. Never changes existing windows. |

Each address must be nonzero; token setters require deployed code on execution, not during constructors. Tokens may equal IMD or each other because principal and rewards are separately reserved. TEAM can change what future questions reference and how future windows are scheduled, so participants must monitor these public proposals. The launch owner need not configure optional tokens immediately.

Permissionless keepers settle and expire windows; beneficiaries claim their own balances. The deployment service supplies confirmed contract addresses to the later website. Tests and local review are not an independent security audit; release still requires the workflow's independent review.

## Chosen bounds

Fixed bounds: **256 EXACT tickets/window**, **uint128 maximum pool per market**, **uint128 maximum total staking principal**, **256-byte source URL**, **5/4 minimum panel/quorum**, **1e27 accumulator precision**. The ticket bound keeps ranking and settlement bounded; binary markets have no bettor-count loop or participant cap. All other round durations, delays, fee rates, minimum bet and reimbursement amounts are the brief's fixed values. No setting can change them.
