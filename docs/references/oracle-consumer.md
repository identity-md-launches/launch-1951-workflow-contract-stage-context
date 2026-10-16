# IdentityMD oracle consumers

A contract pays the `Intake` for an `oracle.request`, a panel of agents answers, and the oracle's
signer signs the result as EIP-712 typed data in **the consumer's own domain**. The plane's writer
then calls the contract back with the attestation and the signature. The contract verifies the
signature and acts on the answer.

Everything here is fixed by contracts that are already live. A brief that restates part of it
(a struct, a type string, an address) may be truncated or wrong. **Where the brief and this
reference disagree on the protocol, this reference wins**, and the summary says what differed.

The reference delivered beside this skill, `REFERENCE.md`, holds the canonical Solidity copied
from the protocol's own contracts: the `OracleAttestation` library and `OracleAttestationConsumer`,
the two worked examples, and a conformance test. Copy them; never retype them.

## Live deployments (2026-10-10)

| | Ethereum (1) | Robinhood Chain (4663) |
| --- | --- | --- |
| `Intake` (version 2) | `0xa43e6f75ee006411f79ac1c84120606c2330de82` | `0xa43e6f75ee006411f79ac1c84120606c2330de82` |
| `Intake` (version 1, still served) | `0x1397434cd35e8a9c8ac312a61d3a285eb31dea56` | `0x1397434cd35e8a9c8ac312a61d3a285eb31dea56` |
| `IntakeDelivery` | `0xce0e6a670aa75e161d02aca3c7f00b94ca428ccb` | `0xce0e6a670aa75e161d02aca3c7f00b94ca428ccb` |
| IMD (the asset paid in) | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` | `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` |
| Oracle signer | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` |

- Action id: `bytes32("oracle.request@oracle-1")` =
  `0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000`, the UTF-8 bytes
  right-padded with zeros, **not** a keccak hash. Price 0.5 IMD (`500000000000000000`) on both
  chains; read it with `Intake.priceOf(action, imd)`.
- This skill is about `oracle.request`. Ethereum and Robinhood Chain also sell `job.open`,
  `job.continue`, `launch.open` and `workflow.open` at the same price (see docs/onchain-intake.md);
  Sepolia sells `oracle.request` only. The native coin is not sold: `request` with asset zero
  reverts `ActionNotSold`.
- Use version 2 for anything new: it has everything version 1 has, plus `requestWithFailure`.
  Version 1 still takes and completes requests, for contracts already pointing at it.
- Sepolia (11155111) has the same `Intake` addresses and `IntakeDelivery`, selling in TestIMD
  `0x44a1cd38474fb1748400e7deb5f8d786cce3f89a` (open `mint`), and only for an answer signed for a
  Sepolia contract. Base (8453) has no `Intake` or `IntakeDelivery` yet. Unit tests use a mock
  either way (see Tests).
- Every one of these is **constructor input and owner-settable**, never a constant: the intake,
  the delivery contract, the action id, the asset and price (set together), the signer. A new
  action version (`oracle-2`) or a moved price must not need a redeploy.

## The intake, as a consumer calls it

```solidity
interface IIntake {
    struct Callback { address target; bytes4 selector; }
    function priceOf(bytes32 action, address asset) external view returns (uint256);
    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external payable returns (bytes32 requestId);
}
```

Ask in one call: `forceApprove(intake, price)` on the IMD the contract holds or just pulled, then
`request(...)`. The intake pulls exactly `amount` and forwards it; nothing is escrowed or refunded.
Keep the returned `requestId`: it is the intake's id, and it is the first argument of the callback.

## The callback

The writer calls `target` with `selector ++ abi.encode(bytes32 requestId, Attestation a, bytes signature)`.
The function's name is yours; its parameter types are not:

```solidity
function onOracleResult(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature) external;
```

- `Attestation` is the protocol's struct, exactly: 15 fields, in this order, with these names:
  `requestId, chainId, questionHash, answerType, answer, figure, fromBlock, toBlock, blockHash,
  panelJobId, panelSize, quorum, agreed, issuedAt, expiresAt`. A struct that drops `figure` or
  renames `agreed` has a different selector and a different type hash. The callback then cannot
  decode, no signature verifies, and every request is paid for and never answered.
- Inherit `OracleAttestationConsumer` and call `_verifyAttestation(a, signature)`. It checks the
  window and the signature over `attestationDigest(a)`, which is the consumer's domain:
  name `"IdentityMD Oracle"`, version `"2"`, `block.chainid`, and `verifyingContract` =
  **this contract**. The Intake is never the verifying contract. The plane sets the domain to the
  callback target (or the `deliver` target), unless the body names its own `consumer`.
- Check `msg.sender == intake` (same chain) or `msg.sender == intakeDelivery` (another chain).
  Only a request this contract made and has not settled may be answered.
- `a.requestId` is the oracle request's UUID; the callback's first argument is the intake's id.
  They differ on purpose. Consume one of them, once.
- Read the answer with the typed decoders (`decodeBool`, `decodeUint256`, …). `answerType` codes:
  bool 0, address 1, bytes32 2, uint256 3, address[] 4, bytes32[] 5.
- `panelSize`, `quorum` and `agreed` are signed. Require `agreed >= quorum` and that the panel and
  quorum are at least what the contract asked for.
- The callback gets a **200 000 gas** stipend inside a try. Verify and store; act in a later call
  of the user's own (an `execute` that reads the stored approval). A callback that reverts or runs
  out of gas is recorded as not delivered and is not retried. A "no" answer is a result to store,
  never a revert.
- `questionHash` covers the question, the resolved block window and the definitions, so a
  contract cannot compute it in advance when the window is relative (`{"hours": N}`). With an
  absolute window (`{"fromBlock","toBlock"}`, already confirmed when asked) it can:
  `oracleQuestionHash(...)` in the protocol package. The pairing of an answer to the intake request
  is the writer's.

## What a callback proves

The signature proves the oracle answered *a* question for *this contract*. It does not prove this
contract asked it: anyone can pay 0.5 IMD, name your contract as the callback, the `deliver`
target or the body's `consumer`, and get their own question answered and signed for you. A
contract that moves value on an answer checks, in this order:

1. **Its own question.** On the asking chain, only a request id it created and has not settled
   (the example's `pending`). A receiver on another chain cannot see who asked, so it pins the
   question: the owner stores the `questionHash` in advance and the receiver refuses any other,
   and takes each pinned question once (the receiver example's `expectQuestion`). A question with
   a relative window cannot be pinned, so a receiver uses absolute windows.
2. **The panel.** `panelSize`, `quorum` and `agreed` are signed. Require `agreed >= quorum`, and a
   panel and agreement at least as large as the value at stake warrants (the examples'
   `setPanelMinimums`). A small panel is cheap to fill with seats one holder controls.
3. **Freshness.** `_verifyAttestation` refuses an expired attestation; check `toBlock` or
   `issuedAt` against how old an answer your use can tolerate.
4. **Failures are not signals.** The failure function is unsigned and anyone can cause one at
   your contract (ask with a bad body and name it). Clear only a request of your own; never move
   value on a failure.
5. **Liveness.** An answer comes minutes later, is attempted once, and can be withheld or lost. A
   design that loses money when an answer is late or missing (a liquidation, a margin call) does
   not belong on this oracle today.

The truth of an answer is the panel's, and its signature is one hot key's. Treat it as a strong
signal for moderate value, not as a price feed for liquidations.

## When no answer comes

A refused body (status 1: bad JSON, unknown key, an ambiguous question) or a panel that did not
agree (status 2) spends the price and never reaches the callback. Do not promise a refund the
contract cannot pay.

Version 2 of the `Intake` can say so. `requestWithFailure(action, body, callback, onFailure, asset, amount)`
names a second function on the callback target, which `complete` calls on status 1 or 2 under
the same 200 000 gas:

```solidity
function onOracleFailure(bytes32 requestId, uint8 status, bytes32 reason, uint16 agreed, uint16 answered, bytes calldata signature) external;
```

- The name is yours; the parameter types are fixed. `reason` is a short code right-padded to 32
  bytes: `bytes32("disagreed")`, `bytes32("body_invalid")`, `bytes32("body_refused")`, … `agreed`
  and `answered` are the panel's counts, zero without a panel. `signature` is empty for now.
- Check `msg.sender == intake` and that the request is one this contract made and has not
  settled, exactly as in the callback. Then clear it and record the reason. The values are
  unsigned: never move money on them.
- `requestWithFailure` exists on version 2 only; on version 1 a call to it reverts. Copy the
  example's `failureHook` flag (owner-set, off by default, `request` while off) so the contract
  works against either, and turn it on against version 2.
- Every pending request still needs a deadline after which its requester can clear it: a failure
  call can run out of gas or never come.

For a delivery on another chain, `"onFailure":"<selector>"` inside `deliver` sends the same call
through `IntakeDelivery`, from either intake version.

## The body

The body is the UTF-8 JSON the HTTP door takes for the action (`PaidOracleInput`), compacted,
strict: an unknown key refuses the whole request.

```json
{"v":1,"question":"…","chainId":1,"window":{"hours":1},"answerType":"bool","evidence":"panel","panelSize":30,"quorum":20,"validForSeconds":900,"definitions":{"credible":"…"}}
```

- `question` 1–2000 characters; each `definitions` value at most 512, each key at most 64;
  `panelSize` from 2 up to the paid door's cap (100 today; `limits.maxPanelSize` from `POST /requests/check`), `quorum <= panelSize`, and a larger panel is refused with the price spent; `validForSeconds` 60 to 30 days;
  `window` is `{"hours":1..720}` or `{"fromBlock","toBlock"}`; `evidence` `"panel"` for facts
  that are not on a chain, `"chain"` (the default) for facts a recipe can reproduce from blocks.
- A question the wording screen finds ambiguous, or that a panel cannot answer from public
  sources, is refused (status 1). Pin the reading in `definitions`. `allowAmbiguous: true` skips
  both screens; use it only when the definitions already pin the reading.
- **Check the question before you bake it.** A question written into a contract cannot change
  once deployed, so one the quote refuses is refused on every attempt, each spending the price.
  Run the body through `POST /requests/check` (`{"action":"oracle.request","input":{"question",
  "panelSize","evidence"}}`, free, no credential) and ship only a question it returns no blockers
  for; say what it answered in your summary. The verifier sends every `"question":"…"` it finds in
  your sources to the same check, and a refusal comes back as a finding that reopens your step.
- **User text is untrusted.** Validate it as UTF-8 and bound its length. JSON-escape it (`"`,
  `\`, control characters) so the body stays valid. Also keep it from reading as your own
  instructions to the panel: quote it, say in the question that it is the user's untrusted text
  to judge, and neutralise the delimiter you quote it with (for example, replace `"` in the
  user's text before quoting it), since the panel reads the decoded question.
- At most 16 KiB of body.

## An answer on another chain

Pay on one chain and receive on another: add
`"deliver":{"chainId":<B>,"target":"<receiver on B>","selector":"<callback selector>","onFailure":"<failure selector>"}`
to the body (`onFailure` optional) and pass **no** callback (target zero) to `request`. The answer is signed for the receiver
on B. The plane completes the request on the asking chain without a callback, then its writer
calls `IntakeDelivery.deliver` on B, which calls the receiver once under the same 200 000 gas.

- The receiver checks `msg.sender == IntakeDelivery` on its own chain. The callback's first
  argument is then the source chain's intake request id, which nothing on B can check, and the
  signature only proves the answer was signed for this receiver, not that its owner asked: pin the
  `questionHash` (see [What a callback proves](#what-a-callback-proves)).
- Deliveries are live on 1 and 4663. A `deliver` to another chain, or beside a callback, is
  refused and the price is spent.
- The delivery is its own transaction, minutes after the payment. It is not atomic with anything
  on the asking chain.

## Ownership and deployment

A launch factory, not a person, deploys launch contracts, so `msg.sender` in a constructor is
the factory. Take the owner as a constructor argument, using the launch's owner placeholder where
the manifest has one; never `Ownable(msg.sender)` on a contract the factory deploys. If the brief
gives no owner and the manifest has no placeholder for it, report that the brief is missing an
input. Never fill an address argument with the zero address, `0x…dEaD` or any other stand-in: the
verifier refuses them.

## Tests

- Copy the conformance test from `REFERENCE.md`. It deploys your consumer at the protocol's
  vector address on the vector's chain and checks that your verification reproduces the
  protocol's digest and accepts the protocol's signature. It is the one test that proves the
  struct, the type string and the domain match what the oracle signs. Self-consistent tests
  (your own key signing your own digest) do not.
- Mock the intake: a contract that records `request(...)`, pulls the price, and can call the
  stored callback with `abi.encode(requestId, a, signature)` from its own address. Test the
  callback from the wrong sender, for an unknown or settled id, with an expired or tampered
  attestation, with a "no" answer, under a 200 000 gas limit, and the clear-after-deadline path.