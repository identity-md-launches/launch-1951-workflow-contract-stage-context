# Contract interfaces

The JSON arrays in [HamsterHour.json](abi/HamsterHour.json) and [OracleVerifier.json](abi/OracleVerifier.json) are generated from the pinned build. Regenerate them with `bash scripts/export-abis.sh`. Do not invent deployment addresses; the workflow's confirmed deployment handoff provides them.

## HamsterHour

| Interface | Purpose |
| --- | --- |
| `window(k)` | Full market snapshot, pools, line, status, outcome, ranks, allocated payouts, claims and oracle UUID. Status: 0 uncreated, 1 open/pending, 2 settled, 3 timed out. An open status after start does not mean betting is open. |
| `windowTimes(k)`, `currentRound()`, `currentWindow()`, `hasStarted()`, `isBettingOpen(k)` | Current clock and authoritative per-window deadlines. A new default candidate is zero before genesis, otherwise `currentWindow()+1`, clamped to at least `closedWindowFloor()`. |
| `position(k, account)` | Both binary-side stakes, EXACT amount and guess, and separate IMD/jackpot claimed flags. |
| `currentLine()`, `recentResults(i)`, `settledWindows()` | Next new window's line and seven-result settlement-order ring buffer. |
| `exactEntries(k)`, `exactGuess(k, index)` | Bounded EXACT tickets for displaying market guesses. Bettor addresses are indexed by `Bet` events. |
| `betOverUnder(k, over, amount)`, `betSleep(k, sleeping, amount)` | Pull a binary IMD bet; true is over/yes, false is under/no. |
| `betExact(k, guess, amount)` | Pull one EXACT ticket per account/window. |
| `question(k)`, `questionDocument(k, fromBlock, toBlock)`, `questionHash(k, fromBlock, toBlock)` | Frozen human-readable oracle question, canonical document and keccak hash. |
| `settle(k, attestation, signature)` | Permissionless signed result submission during the settlement interval. No token transfer to users occurs here. |
| `voidWindow(k)` | Permissionless timeout finalization. |
| `claim(k)` | Pull IMD and jackpot entitlements. |
| `claim(k, includeJackpot)` | Use the overloaded signature explicitly in client libraries; `false` collects IMD separately if the prize token fails. |
| `stake(amount)`, `unstake(amount)`, `claimStaking()` | Pull staking principal in, return it, or collect earned IMD. |
| `stakes(account)`, `pendingStaking(account)`, `totalStaked()`, `accIMDPerStake()` | Position, pending IMD and accumulator. |
| `preStakingReserve()`, `releaseTotal()`, `reserveReleased()`, `releaseWindows()`, `stakingActivatedAt()`, `stakingUndistributed()` | Reserve-release accounting and no-stake backlog. |
| `fundOracleReserve(amount)`, `oracleReserve()` | Permissionless earmarked donations and unallocated reserve. |
| `imdLiability()`, `jackpotLiability()` | Accounted IMD and outstanding prize obligations. |
| `TEAM()`, `oracleVerifier()`, `IMD()`, `stakingToken()`, `jackpotToken()`, `sourceUrl()`, `genesisTimestamp()` | Immutable identities and active settings. Optional token getter zero means not configured; it is not a deployment stand-in. |
| `scheduleStakingToken/setStakingToken`, `scheduleJackpotToken/setJackpotToken`, `scheduleSourceUrl/setSourceUrl`, `scheduleGenesisTimestamp/setGenesisTimestamp` | TEAM-only schedule/execute pairs; exact parameters and 48-hour delay required. |
| `pendingConfig(settingHash)` | Pending value hash and execution time. Named setting hashes are exposed as constants. |

Pools/reward arrays use indexes **0 OVER/UNDER, 1 EXACT, 2 SLEEP**. Binary side arrays use **0 false, 1 true**. EXACT distance/rank arrays are ordered nearest first. All IMD amounts are integer units with 18 decimals; staking and prize amounts use their own token's units.

For binary implied payouts before settlement, deduct the specified per-market fee floors and divide the winner allocation pro rata by the selected side's pool. This is an estimate: future bets can change it, and one-sided/equal-line markets refund. EXACT estimates must implement distinct-distance tiers, equal tied tickets and missing-tier allocation as documented in README. Do not label stakes or reserves as jackpot: available jackpot is `balanceOf(game) - jackpotLiability - (token==IMD ? imdLiability : 0) - (token==stakingToken ? totalStaked : 0)`, floored at zero if an unsupported token reports a deficit.

Events cover creation, each bet, successful settlement and split, binary voids, timeout void, claims, staking actions, reward distribution, reserve funding/reimbursement, jackpot reservation/failure, and both configuration phases. Index `WindowCreated`, `Bet`, `Settled`, `WindowVoided`, `Claimed` and `ConfigScheduled/ConfigChanged` for the later website. `Settled.requestId` is the oracle UUID, not an Ethereum transaction hash or an Intake id.

## OracleVerifier

`constructor(address signer_)` has no admin. `oracleSigner()` is immutable. `attestationDigest(a, consumer)` exposes the exact EIP-712 digest; the explicit consumer is a read-only calculation parameter. `verify(a, signature, expectedQuestion)` consumes a valid `uint256` attestation for **msg.sender**, returning the number. `consumed(consumer, requestId)` is the replay record. `AttestationConsumed` logs consumer, request and question hash.

See [ORACLE.md](ORACLE.md) for the 15-field tuple, which must be encoded in declaration order. The generated ABI includes every custom error for client decoding. Common failures are `BettingClosed`, `BelowMinimum`, `DuplicateExactBet`, `ExactFull`, `NotSettleable`, `NotTimedOut`, `NothingToClaim`, `TokenNotConfigured`, `TimelockNotReady`, `WrongQuestion`, `BadSignature`, `AlreadyConsumed`, and `InvalidValidityWindow`.
