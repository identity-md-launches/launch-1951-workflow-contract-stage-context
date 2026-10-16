#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
mkdir -p docs/abi
forge inspect src/HamsterHour.sol:HamsterHour abi --json > docs/abi/HamsterHour.json
forge inspect src/OracleVerifier.sol:OracleVerifier abi --json > docs/abi/OracleVerifier.json
