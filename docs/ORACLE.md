# IMD attestation integration

The public [IMD documentation](https://imd.fun/docs/#the-attestation) and [protocol reference](https://api.imd.fun/reads/skill/oracle-consumer) define EIP-712 version 2. This project copies the reference's `OracleAttestation` schema/hash library, and implements a caller-scoped consumer in `OracleVerifier`. The upstream example's ownership and signer-rotation interface is deliberately not adopted: the approved game permits only four TEAM settings.

## Keeper procedure

1. Read `window(k)`, including its frozen `source`, `endsAt` and `status`. Wait until the end and until all six real records are available. Do not request future guesses or accept fabricated substitutes.
2. Read `question(k)`. This is exactly `What is the total number of wheel passes recorded by Squeekchain for rounds {6k} through {6k+5} inclusive, as published at {sourceUrl}? Answer as a single uint256.`
3. Buy an IMD `oracle.request` through the oracle's normal paid route, with the body below. Keep this as a separate, reviewable action by the keeper; this repository never pays, signs or broadcasts such a request.
4. Retrieve `GET https://api.imd.fun/oracle/requests/<UUID>/attestation`. The public result includes `domain`, `types`, `message`, `signature` and `signer`. Read the parent `/oracle/requests/<UUID>` record for its `jobId`, then link to `https://explorer.imd.fun/jobs/<jobId>` for the panel and attestation. This is the same UUID encoded in `panelJobId`; UI links should use returned service URLs where available.
5. Check the domain's `verifyingContract` is **HamsterHour**, not OracleVerifier or the Intake. Check the returned signer equals `oracleVerifier.oracleSigner()` and the current chain is 1. Rebuild `questionHash(k, message.fromBlock, message.toBlock)` and compare it to the signed hash. The service's `answerType` string `uint256` encodes as numeric **3** in Solidity.
6. Submit `settle(k, a, signature)` before `endsAt + 172800`. The oracle UUID is left-aligned into a `bytes32` (16 UUID bytes, then 16 zero bytes). The result's `message` supplies the rest of the fields. Use the ABI tuple order below. Validity expiration is inclusive; the game settlement deadline is exclusive.
7. After successful settlement, the submitter calls `claim(k)` to collect the reserved reimbursement. If the 3% reserve is not yet sufficient for 0.5 IMD, anyone may fund it with `fundOracleReserve`; only the recorded settler receives that window's reimbursement. If no settlement succeeds, anyone calls `voidWindow(k)`, or a bettor calls `claim(k)`, at the timeout.

Build a body with these fields (symbols here describe values; they are not literal request placeholders):

| Key | Value |
| --- | --- |
| `v` | `1` |
| `question` | Exact returned `question(k)` |
| `chainId` | `1` |
| `window` | `{ "fromBlock": confirmedStartBlock, "toBlock": confirmedEndBlock }`, or `{ "hours": 24 }` |
| `answerType` | `"uint256"` |
| `evidence` | `"panel"` |
| `panelSize` | At least `5` (suggested `5`) |
| `quorum` | At least `4`, no greater than panel size (suggested `4`) |
| `validForSeconds` | `86400` |
| `consumer` | `{ "chainId": 1, "verifyingContract": confirmedHamsterHourAddress }` |

Do not add optional `definitions`, guards, or alternate question text: this game accepts the canonical document below, without them. There is no on-chain block-window pin before asking; the contract reconstructs and verifies the exact signed document on submission. A relative window is therefore supported without trusting the supplied hash. The six **round numbers in the question** define what is counted; the Ethereum block range is context for the off-chain panel, not a replacement for that round range.

The canonical question document is compact UTF-8 JSON with recursively sorted keys:

```text
{"answerType":"uint256","chainId":1,"evidence":"panel","question":"<exact generated question>","v":1,"window":{"fromBlock":<signed fromBlock>,"toBlock":<signed toBlock>}}
```

Its keccak-256 must equal `a.questionHash`. `questionDocument` returns the actual bytes for a window. All generated question text is ASCII, and URL validation excludes characters that would need JSON escaping. The document layout is independently checked against a [real published Squeekchain attestation](https://api.imd.fun/oracle/requests/753b4996-34e7-420a-8768-d784231195da), not just self-signed unit tests.

## Signed fields

Domain: `{name:"IdentityMD Oracle", version:"2", chainId:1, verifyingContract:HamsterHour}`.

```text
OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)
```

`answer` is exactly 32 bytes, `abi.encode(uint256(totalPasses))`. EIP-712 hashes it as `keccak256(answer)`. `figure` remains in the signed structure and is not used in place of the typed answer. `fromBlock <= toBlock`; both are unsigned 64-bit values. The question chain must equal the execution chain. The signed panel fields must satisfy the fixed minimums. The verifier accepts the attester's ECDSA signature even if its EOA later acquires EIP-7702 code; it does not grant an alternate ERC-1271 signing authority.

`OracleVerifier.verify` verifies in **its caller's domain**, consumes `(caller, requestId)` once and returns the number. HamsterHour is the caller during settlement. Someone calling the verifier directly cannot consume HamsterHour's signature or affect the game's state. A separate HamsterHour status transition prevents repeat settlement with a new oracle request id.

The 300-second tolerance accommodates oracle/chain clock drift. `issuedAt` must not exceed `now + 300`, `issuedAt <= expiresAt`, `now <= expiresAt`, and `issuedAt >= window.endsAt` (no tolerance on this bound: an attestation signed before the last round ended cannot include it). The game also requires its own settlement deadline. A failed signature verification rolls back status, consumption and all accounting.

## Recorded evidence and limits

* The [protocol digest vector](../test/Oracle.t.sol) reproduces IMD's independently generated digest `0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c` and recovers its published fixture signer.
* [The real result fixture](references/squeekchain-attestation.json) was fetched on 2026-10-16. It says 1470 passes for rounds 468–470 and was signed by `0x5598aa9146215bc13eb26f2c692ad1461fd32982`. Its historical consumer is the zero domain. That zero is part of the real fixture, **never a launch argument**; the test proves that the same signature is rejected for HamsterHour's domain. The fixture is not a valid settlement for a six-round HamsterHour window.
* [The free template preflight](references/question-check.json) returned `blockers: []` and a `not_answerable` suggestion. It was not a paid oracle request and does not guarantee future results. No private account or credential was used.
* IMD's key and panel are trusted for factual accuracy; an actual compromised signer can attest to false passes. Mainnet oracle delivery and production funding have not been exercised by this assignment. The timeout protects bets from missing answers, not dishonest valid answers.
