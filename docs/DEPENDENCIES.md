# Offline dependency provenance

All required dependencies are committed as ordinary source files. There are no package installs, submodules, external library paths, compiler binaries or network calls in the build/test process. `foundry.toml` pins solc by version; the execution profile supplies that compiler.

| Component | Upstream version and retrieval | Files retained |
| --- | --- | --- |
| OpenZeppelin Contracts | [v5.4.0](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.4.0), fetched from its versioned GitHub source archive | Import closure for ERC-20 interfaces/implementation (test token), SafeERC20, Math, Strings, ECDSA and ReentrancyGuard; original MIT license. |
| forge-std | [v1.9.7](https://github.com/foundry-rs/forge-std/tree/v1.9.7), fetched from its versioned GitHub source archive | Test/Vm/assertion/cheatcode/invariant import closure; original MIT and Apache-2.0 licenses. |
| IMD OracleAttestation | [Public oracle-consumer reference](https://api.imd.fun/reads/skill/oracle-consumer), retrieved 2026-10-16 | The `OracleAttestation` library copied into `src/libraries/OracleAttestation.sol`. Unused base-consumer code and its imports were omitted; formatting was normalized by Forge. The schema, constants and internal hash function are unchanged. MIT SPDX retained. |

[dependencies.sha256](dependencies.sha256) fingerprints every retained vendored file, its license, and the copied oracle library. Validate with:

```sh
sha256sum -c docs/dependencies.sha256
```

Protocol reference snapshots are retained in `docs/references/oracle-consumer.md` and `docs/references/oracle-consumer-REFERENCE.md`. The service identified their original content digests respectively as:

* `398813f65da6463ef3a227aaded65da48c38d471b0d79c066ae6c58279f08e3d`
* `631ce64ce79c3d883d4c3f388a2bd5785efb04efe39ffe1a275e3b262166e7a8`

These reference documents explain the live protocol, not this application's administrative policy. HamsterHour's approved no-owner design overrides the upstream example's recommendations for owner-settable protocol dependencies. The pinned eth-security input was read as a security checklist; it is not needed to build and is not shipped as a runtime dependency.

The real oracle fixture and free question preflight are public service responses, not credentials or deployment configuration. No machine-specific RPC endpoint, account information or key is included. Keys and synthetic addresses in `test/` are exclusively test fixtures; the real launch signer and TEAM parameters are documented separately in README.
