# Restoring the art

The contract names the art by CID. A CID is a name, not a location: it stays
correct forever, but it only resolves while somebody is pinning the bytes. If
every pin lapses, the pictures are still recoverable, and this page is how.

Nothing here needs the original author. Anyone who can read it can put the art
back at the same CID.

## What the contract points at

| constant | value | network |
|---|---|---|
| `IPFS_ROOT` | `bafybeide2rqgoymdal3bhump5imrmladdo73umdro4ezbswmvnuprvqdeu` | IPFS |
| `ARWEAVE` | `h9hcgqPaUnpUDbwyXkdoRE_mFuRUN_jFNBPd2Kz4jBM` | Arweave |

Both name the same tree:

```
blue/0.png   blue/0.webp   ...  blue/9999.png   blue/9999.webp
green/0.png  green/0.webp  ...  green/9999.png  green/9999.webp
```

40,000 files, about 24 GB. `id` runs 0 to 9999. Blue is generation 0, green is
every later generation. The PNG is the composited original and the WebP is a
quality 92 copy of it, around a sixth of the bytes.

The two roots hold identical trees, so a path differs only in its scheme:
`ipfs://bafybeide2rqgoymdal3bhump5imrmladdo73umdro4ezbswmvnuprvqdeu/blue/7412.png` and `ar://h9hcgqPaUnpUDbwyXkdoRE_mFuRUN_jFNBPd2Kz4jBM/blue/7412.png`.

Read both off the deployed contract with `ipfsRoot()` and `arweaveManifest()`
rather than trusting this file.

## The fast path

One CAR file reproduces the IPFS CID exactly. A CAR holds the IPFS blocks and
the tree over them, so uploading one restores the original CID rather than
minting a new name for the same pictures.

| file | size | sha256 |
|---|---|---|
| `glamtoon.car` | 24,360,504,083 bytes | `d5b138aaa9943af816bf6d6a73ad041f8e44a7c4c95ed81506e47d805eee9654` |

The file is not in this repository: at 24 GB it is far past what a git host
accepts. The project keeps it offline. Anyone else gets the same file, with the
same hash, from the durable path below.

Upload it to any pinning service that accepts CAR imports. The root CID it
reports must equal `IPFS_ROOT` in the first table of this page. If it does not,
the import was treated as a plain file and the upload is wrong.

The CAR is a single file of about 24 GB, and not every service takes one that
large. Filebase accepted it. Pinata refuses it: its upload server advertises a
maximum of 10 GiB (`Tus-Max-Size: 10737418240`), which no single file holding
the full-size art can fit under. A service that refuses it can still pin the
art by CID, fetching it over IPFS instead, but only while some node is serving
that CID. If none is, put it back
online first, either by uploading the CAR somewhere that takes it or by importing
it into your own IPFS node:

```sh
ipfs dag import glamtoon.car
```

then ask the other services to pin `bafybeide2rqgoymdal3bhump5imrmladdo73umdro4ezbswmvnuprvqdeu` by CID. On Pinata that is its
pin by CID request.

## The durable path

The CAR is derivable, so it does not have to survive. The art itself is on
Arweave, which is paid once and needs nobody to remember anything, and the
recipe below turns those files back into a byte-identical CAR.

### 1. Fetch the art

Every file is at `ar://h9hcgqPaUnpUDbwyXkdoRE_mFuRUN_jFNBPd2Kz4jBM/blue/<id>.png` and the three other
combinations of edition and extension, 40,000 in all. Any Arweave gateway serves
them; this fetches every one into the layout the next step needs:

```sh
mkdir -p glamtoon/blue glamtoon/green
for e in blue green; do
  for i in $(seq 0 9999); do
    for x in png webp; do
      curl -sfL --retry 5 --retry-all-errors -o glamtoon/$e/$i.$x \
        https://arweave.net/h9hcgqPaUnpUDbwyXkdoRE_mFuRUN_jFNBPd2Kz4jBM/$e/$i.$x \
        || echo "failed $e/$i.$x"
    done
  done
done
find glamtoon -type f -name '*.png' | wc -l
find glamtoon -type f -name '*.webp' | wc -l
```

Both counts must be 20000, and nothing may print `failed`. Rerun the loop for any
that did.

`-L` is required: gateways answer each path with a redirect, and without it
`curl` saves the redirect page in place of the image and reports no error. A
gateway that has not cached a file yet may answer 404 at first, which is why the
loop retries; any Arweave gateway serves the same bytes, so `arweave.net` can be
swapped for another such as `turbo-gateway.com`.

### 2. Lay it out

```
glamtoon/
  blue/0.png  blue/0.webp  ...  blue/9999.png  blue/9999.webp
  green/0.png green/0.webp ...  green/9999.png green/9999.webp
```

Only `blue/` and `green/` inside the folder, and only the 40,000 images inside
those. The CID is a hash of the file names and their contents, so a file that is
missing, renamed, added or altered by a single byte gives a different one.

What does not matter: file dates, permissions, the order the files were written,
and hidden files such as `.DS_Store`, which `ipfs-car` leaves out unless told
otherwise. Each of these was tested and produced the identical CAR.

### 3. Pack

```sh
npx --yes ipfs-car@3.1.0 pack glamtoon --no-wrap --output glamtoon.car
```

The version is pinned on purpose. A later release may chunk differently, and a
different chunking gives a different CID for the same pictures.

`--no-wrap` is not optional. Without it the root gains a directory level and
every URL the contract builds points at nothing.

### 4. Check before uploading

```sh
shasum -a 256 glamtoon.car
npx --yes ipfs-car@3.1.0 roots glamtoon.car
```

The hash must match the table above and the root must match the contract. Both
matching means the rebuild is exact and uploading it restores the original CID.

## Verifying a pin

A directory CID resolves even when files are missing from it, so a successful
upload is not evidence of a complete one. `scripts/verify-pin.mjs` walks every
path the contract can build and compares each against a local copy.

```sh
node scripts/verify-pin.mjs --cid bafybeide2rqgoymdal3bhump5imrmladdo73umdro4ezbswmvnuprvqdeu --dir glamtoon --ext .png \
  --gateway https://ipfs.filebase.io/ipfs/
node scripts/verify-pin.mjs --cid bafybeide2rqgoymdal3bhump5imrmladdo73umdro4ezbswmvnuprvqdeu --dir glamtoon --ext .webp \
  --gateway https://ipfs.filebase.io/ipfs/
```

`--dir` is a local copy of the art, holding the `blue/` and `green/` folders.
Here it is the `glamtoon` folder fetched from Arweave in step 1 of the durable
path.

Two runs against the one CID, one per extension. A public gateway answers from
whichever node holds the blocks, so a clean run through one shows the CID is
complete somewhere on the network, not that a given service pins it. To check
what one service pins, make both runs with `--gateway` pointed at that service's
own gateway, and repeat them for every service. The script backs off when a
gateway asks it to wait. ipfs.io and dweb.link have answered every file with 429
since September 2026, so they cannot be used.
