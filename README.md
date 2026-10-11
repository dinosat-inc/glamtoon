# Glamtoon

Ten thousand character portraits, each drawn once and issued in two editions that
differ only in the colour behind them. On OP Mainnet, immutable, ownerless,
no proxy.

- **Blue is the genesis.** Exactly one per character, ten thousand in all, sold.
  Opens at 0.01 ETH and steps up by 0.01 every two and a half thousand sold, to
  0.04 ETH for the last two and a half thousand.
- **Green is free.** Anyone can mint the next generation of any character for the
  cost of gas. Generation 1, then 2, then 3, without limit.

Every token is `Glamtoon #<id>`, with ` Gen <n>` after it for a green, and lives
at `https://glamtoon.com/token/<tokenId>`.
That URL is compiled into the contract and cannot be changed after deployment.

## Deployed

On OP Mainnet since 10 October 2026. Every contract is verified on Optimistic
Etherscan and is an exact match on Sourcify, and its code is the build this
repository produces.

| | | |
|---|---|---|
| `GlamToon` | [`0x2F2aD1a35815002EA80cDc9A32F8d75cA59d62E7`](https://optimistic.etherscan.io/address/0x2F2aD1a35815002EA80cDc9A32F8d75cA59d62E7) | the token |
| `Treasury` | [`0x529A0AE140F3064Ab5CCE35d9Cc38C0Cd800179c`](https://optimistic.etherscan.io/address/0x529A0AE140F3064Ab5CCE35d9Cc38C0Cd800179c) | where the sale and the royalties are paid |
| `TraitData0` | [`0xeCFe121DB5A0EdAEc4D477150F807BeadCa85C29`](https://optimistic.etherscan.io/address/0xeCFe121DB5A0EdAEc4D477150F807BeadCa85C29) | traits of characters 0 to 4999 |
| `TraitData1` | [`0xD3746533ac87c32aE5133F41dBB8e8D4c25D21b8`](https://optimistic.etherscan.io/address/0xD3746533ac87c32aE5133F41dBB8e8D4c25D21b8) | traits of characters 5000 to 9999 |
| `TraitNames` | [`0x43DAEaBD6Fd5A6c3F9fBe191b6d6E18094b910Fc`](https://optimistic.etherscan.io/address/0x43DAEaBD6Fd5A6c3F9fBe191b6d6E18094b910Fc) | the category and value names |

The sale opens on 31 October 2026 at 18:10 UTC (`SALE_START` is 1793470200),
eighteen years after the Bitcoin white paper was announced. Until then both
editions revert `NotStarted`.

## Layout

| | |
|---|---|
| `contracts/` | the Foundry project: the ERC-721, the treasury, the deploy script, the tests |
| `scripts/characters/` | the trait encoder, and the only place generated Solidity comes from |
| `scripts/verify-pin.mjs` | checks that a pinned copy of the art holds every file |
| `metadata/` | the art's own metadata, one file per character, which the tests hold the on-chain traits to |
| `PROVENANCE.md` | how to restore the art at its CID from the Arweave copy |

## Working on it

```sh
npm install

npm run build          # forge build
npm run test           # 695 tests, which forge 1.8 and later report as 663
npm run test:symbolic  # 36 Halmos proofs
npm run fmt

npm run traits         # regenerate the packed trait sources from traits.csv
npm run traits:check   # fail if the generated sources are stale
```

`contracts/README.md` is the real documentation: the contracts, the metadata
shape, the trait encoding and the deployment runbook.

## The art

The contract names the art by an IPFS CID and by an Arweave manifest. The
pictures are not in this repository, and neither is the 24 GB CAR file they were
pinned from. They do not need to be. The Arweave copy is permanent, and
[PROVENANCE.md](PROVENANCE.md) is how anyone fetches the files back from it,
packs them into the same CAR, byte for byte, and pins the art again at the same
CID if every pin lapses.

## Before mainnet

The contract cannot be fixed after deployment, so these came first, in this
order.

1. **Audit.** Done as a line-by-line review by two independent AI reviewers,
   with the full test suite, the 36 symbolic proofs and deliberate breakage of
   the guards. The DinoSAT suite of 222 properties followed, and
   `contracts/DINOSAT_REPORT.md` is its report. No audit firm was engaged, and
   nothing on this list substitutes for one.
2. **Real art.** Done: the two identifiers at the top of
   `contracts/src/GlamToon.sol`, `IPFS_ROOT` and `ARWEAVE`, name the pinned art,
   and [PROVENANCE.md](PROVENANCE.md) records both. What remains is keeping the
   pins alive, which `contracts/README.md` spells out.
3. **Real traits.** Done: `contracts/test/fixtures/traits.csv` carries all ten
   thousand, read from the art. `TraitSchema.REAL_ROWS` records how many came
   from art metadata and the deploy refuses a real chain unless it reaches ten
   thousand.
4. **glamtoon.com answering** at `/token/<tokenId>`, since every token links
   there permanently. Done.
5. **A rehearsal on a fork of OP Mainnet**, exercising the guards rather than
   tiptoeing round them. The deploy script refuses every testnet. Done, the
   last one with the real addresses minutes before the deployment.

## Licence

© Glamtoon.

The code is licensed under the [Apache License 2.0](LICENSE). Anyone may use
it, commercially too, as long as every copy and fork keeps the [NOTICE](NOTICE)
crediting Glamtoon and marks the files it changed.

The character art is licensed under [CC BY 4.0](LICENSE-ART). Anyone may use it,
commercially too, crediting it as Glamtoon (https://glamtoon.com). Holding a
token is not needed for that and grants nothing more.

Neither licence covers the Glamtoon name or logo.
