// Turns schema.json plus a trait table into the generated Solidity the collection
// ships: the packed trait chunks, the name table, and the schema constants.
//
// Everything the contracts know about traits comes from here. Edit schema.json,
// never the generated files, and never the blob by hand.
//
//   node scripts/characters/encode-traits.mjs            regenerate from traits.csv
//   node scripts/characters/encode-traits.mjs --fixture  build the synthetic table first
//     add --force to overwrite a table that already holds real rows
//   node scripts/characters/encode-traits.mjs --check    fail if regenerating changes anything

import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { keccak256 } from 'viem'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = join(HERE, '..', '..')
const GEN = join(ROOT, 'contracts', 'src', 'gen')
const FIXTURES = join(ROOT, 'contracts', 'test', 'fixtures')
const CSV = join(FIXTURES, 'traits.csv')
const PROVENANCE = join(FIXTURES, 'traits.provenance.json')
const EXAMPLES = join(ROOT, 'public', 'example', 'metadata')

const args = process.argv.slice(2)
const MAKE_FIXTURE = args.includes('--fixture')
const CHECK = args.includes('--check')
const FORCE = args.includes('--force')

const schema = JSON.parse(readFileSync(join(HERE, 'schema.json'), 'utf8'))
const CATS = schema.categories
const STRIDE_BITS = CATS.reduce((n, c) => n + c.bits, 0)

// ---------------------------------------------------------------- schema checks

function fail(msg) {
  console.error('encode-traits: ' + msg)
  process.exit(1)
}

function warn(msg) {
  console.error('encode-traits: ' + msg)
}

if (STRIDE_BITS % 8 !== 0) fail(`category bits total ${STRIDE_BITS}, which is not a whole number of bytes`)
const STRIDE = STRIDE_BITS / 8
if (schema.imageCount % schema.imagesPerChunk !== 0) {
  fail(`imageCount ${schema.imageCount} does not divide evenly into chunks of ${schema.imagesPerChunk}`)
}
const CHUNKS = schema.imageCount / schema.imagesPerChunk
const FIRST = schema.firstImageId ?? 0

for (const c of CATS) {
  const cap = 1 << c.bits
  if (c.values.length > cap) fail(`${c.name} has ${c.values.length} values but only ${c.bits} bits (${cap} slots)`)
  if (c.values.length === 0) fail(`${c.name} has no values`)
  for (const v of c.values) {
    if (Buffer.byteLength(v) > schema.nameSlot) fail(`${c.name} value "${v}" is longer than ${schema.nameSlot} bytes`)
    if (/["\\]/.test(v) || /[\x00-\x1f]/.test(v)) fail(`${c.name} value "${v}" contains a character that would need JSON escaping`)
  }
  if (Buffer.byteLength(c.name) > schema.nameSlot) fail(`category name "${c.name}" is longer than ${schema.nameSlot} bytes`)
  if (/["\\]/.test(c.name)) fail(`category name "${c.name}" contains a character that would need JSON escaping`)
}

// Shifts run most significant field first, so a record reads left to right in the
// same order the categories are listed.
const SHIFTS = []
let acc = STRIDE_BITS
for (const c of CATS) {
  acc -= c.bits
  SHIFTS.push(acc)
}
// Name slots: the category names first, then every category's padded value table.
const VALUE_BASE = []
let base = CATS.length
for (const c of CATS) {
  VALUE_BASE.push(base)
  base += 1 << c.bits
}
const SLOT_COUNT = base

// ---------------------------------------------------------------- trait table

function mulberry32(a) {
  return function () {
    a |= 0
    a = (a + 0x6d2b79f5) | 0
    let t = Math.imul(a ^ (a >>> 15), 1 | a)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function buildFixture() {
  const rows = []
  const seen = new Set()
  const firstWith = new Map()
  const repeats = []

  // The characters that already exist go in first, read straight from the
  // metadata the art pipeline produced. Everything after them is filler until
  // the real ones arrive.
  let real = 0
  if (existsSync(EXAMPLES)) {
    const files = readdirSync(EXAMPLES)
      .filter((f) => f.endsWith('.json'))
      .map((f) => Number(f.replace('.json', '')))
      .sort((a, b) => a - b)
    for (const id of files) {
      if (!Number.isInteger(id)) {
        fail(`${EXAMPLES} holds a .json whose name is not a character number. Move it elsewhere.`)
      }
      if (id !== rows.length) fail(`example metadata jumps from ${rows.length} to ${id}`)
      const j = JSON.parse(readFileSync(join(EXAMPLES, `${id}.json`), 'utf8'))
      const byName = new Map(j.attributes.map((a) => [a.trait_type, a.value]))
      const row = CATS.map((c) => {
        const v = byName.get(c.name)
        if (v === undefined) fail(`example ${id} has no ${c.name}`)
        if (!c.values.includes(v)) fail(`example ${id}: "${v}" is not a ${c.name} in schema.json`)
        return v
      })
      const key = row.join('|')
      // Two characters may carry the same four traits. Their art still differs,
      // and nothing on chain reads the table for uniqueness, so this is
      // reported against the files it came from rather than refused.
      if (seen.has(key)) repeats.push([id, firstWith.get(key)])
      rows.push(row)
      seen.add(key)
      firstWith.set(key, id)
      real++
    }
  }

  // The vocabulary runs out long before the collection does: four categories
  // give a few hundred distinct sets against ten thousand rows. Unique while
  // they last, repeats after that, rather than spinning for a row that cannot
  // exist.
  const combos = CATS.reduce((n, c) => n * c.values.length, 1)
  const rnd = mulberry32(0x474c414d) // "GLAM"
  while (rows.length < schema.imageCount) {
    const row = CATS.map((c) => c.values[Math.floor(rnd() * c.values.length)])
    const key = row.join('|')
    if (seen.size < combos && seen.has(key)) continue
    seen.add(key)
    rows.push(row)
  }

  const header = ['imageId', ...CATS.map((c) => c.name)].join(',')
  const body = rows.map((r, i) => [FIRST + i, ...r].join(','))
  mkdirSync(FIXTURES, { recursive: true })
  writeFileSync(CSV, header + '\n' + body.join('\n') + '\n')
  console.log(`fixture      ${rows.length} rows, ${real} real -> ${CSV}`)
  if (repeats.length) {
    const shown = repeats.slice(0, 5).map(([a, b]) => `${a} matches ${b}`).join(', ')
    warn(`${repeats.length} characters repeat an earlier set of traits (${shown}${repeats.length > 5 ? ', ...' : ''})`)
  }
  return real
}

// Null unless this run built the table, in which case it is the count of rows
// that came from art metadata.
let fixtureRealRows = null

if (MAKE_FIXTURE) {
  refuseToClobberARealTable()
  fixtureRealRows = buildFixture()
}
else if (!existsSync(CSV)) {
  fail(
    `${CSV} is missing.\n` +
      '  This script will not invent a trait table on its own: silently generated\n' +
      '  traits that later reach mainnet cannot be undone. Pass --fixture if you\n' +
      '  really do want the synthetic one.'
  )
}

/**
 * The fixture writes over traits.csv, which now holds the shipped table. Losing
 * it to a command meant for an empty checkout is a worse outcome than the
 * command refusing, so it asks first.
 */
function refuseToClobberARealTable() {
  if (FORCE || !existsSync(PROVENANCE)) return
  const real = JSON.parse(readFileSync(PROVENANCE, 'utf8')).realRows
  if (!real) return
  fail(
    `${CSV} already holds ${real} rows read from real art metadata.\n` +
      '  --fixture would overwrite them with synthetic traits. Pass --force as\n' +
      '  well if that is really what you want.'
  )
}

function readTable() {
  const lines = readFileSync(CSV, 'utf8').trim().split('\n')
  const header = lines[0].split(',')
  const want = ['imageId', ...CATS.map((c) => c.name)]
  if (header.join(',') !== want.join(',')) {
    fail(`traits.csv header is\n  ${header.join(',')}\nbut the schema wants\n  ${want.join(',')}`)
  }
  if (lines.length - 1 !== schema.imageCount) {
    fail(`traits.csv has ${lines.length - 1} rows, expected ${schema.imageCount}`)
  }

  const index = CATS.map((c) => new Map(c.values.map((v, i) => [v, i])))
  const rows = []
  const seen = new Set()
  let repeated = 0
  for (let n = 1; n < lines.length; n++) {
    const cells = lines[n].split(',')
    const id = Number(cells[0])
    const want = FIRST + n - 1
    if (id !== want) fail(`traits.csv row ${n} has imageId ${cells[0]}, expected ${want}`)
    const row = []
    for (let c = 0; c < CATS.length; c++) {
      const v = index[c].get(cells[c + 1])
      if (v === undefined) fail(`traits.csv row ${n}: "${cells[c + 1]}" is not a ${CATS[c].name} value in schema.json`)
      row.push(v)
    }
    const key = row.join('|')
    if (seen.has(key)) repeated++
    seen.add(key)
    rows.push(row)
  }
  if (repeated) warn(`${repeated} of ${rows.length} rows repeat an earlier set of traits`)
  return rows
}

function readRealRows() {
  if (!existsSync(PROVENANCE)) return 0
  const p = JSON.parse(readFileSync(PROVENANCE, 'utf8'))
  const n = p.realRows
  if (!Number.isInteger(n) || n < 0 || n > schema.imageCount) {
    fail(`traits.provenance.json has realRows ${n}, which is not a count of rows in the table`)
  }
  return n
}

const rows = readTable()

// The count is recorded only once readTable has accepted every row it counts,
// so realRows can never describe a table that does not exist. REAL_ROWS is the
// one thing standing between filler and a mainnet deployment, and a count that
// outlived its rows would pin the guard open over invented traits.
const REAL_ROWS = fixtureRealRows ?? readRealRows()
if (fixtureRealRows !== null && !CHECK) {
  writeFileSync(PROVENANCE, JSON.stringify({ realRows: fixtureRealRows }, null, 2) + '\n')
}

// ---------------------------------------------------------------- pack

const blob = Buffer.alloc(schema.imageCount * STRIDE)
rows.forEach((row, i) => {
  let packed = 0n
  for (let c = 0; c < CATS.length; c++) packed |= BigInt(row[c]) << BigInt(SHIFTS[c])
  for (let b = 0; b < STRIDE; b++) {
    blob[i * STRIDE + b] = Number((packed >> BigInt(8 * (STRIDE - 1 - b))) & 0xffn)
  }
})

const names = Buffer.alloc(SLOT_COUNT * schema.nameSlot)
function putName(slot, text) {
  const b = Buffer.from(text, 'utf8')
  b.copy(names, slot * schema.nameSlot)
}
CATS.forEach((c, i) => putName(i, c.name))
CATS.forEach((c, i) => {
  const cap = 1 << c.bits
  for (let v = 0; v < cap; v++) putName(VALUE_BASE[i] + v, v < c.values.length ? c.values[v] : '-')
})

const hash = (buf) => keccak256(new Uint8Array(buf))

// ---------------------------------------------------------------- emit

const BANNER = `// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;
`

const written = []
function emit(path, body) {
  if (CHECK) {
    const old = existsSync(path) ? readFileSync(path, 'utf8') : ''
    if (old !== body) fail(`${path} is stale. Run: node scripts/characters/encode-traits.mjs`)
  } else {
    writeFileSync(path, body)
  }
  written.push(path)
}

mkdirSync(GEN, { recursive: true })

const chunkHashes = []
for (let k = 0; k < CHUNKS; k++) {
  const first = FIRST + k * schema.imagesPerChunk
  const last = first + schema.imagesPerChunk - 1
  const slice = blob.subarray(k * schema.imagesPerChunk * STRIDE, (k + 1) * schema.imagesPerChunk * STRIDE)
  chunkHashes.push(hash(slice))
  emit(
    join(GEN, `TraitData${k}.sol`),
    `${BANNER}
/**
 * @title TraitData${k}
 * @notice Packed trait records for characters ${first} to ${last}, ${STRIDE} bytes each.
 * @dev Generated by scripts/characters/encode-traits.mjs. Do not edit by hand.
 */
contract TraitData${k} {
    error OutOfChunk();

    /**
     * @notice First character this chunk carries.
     */
    uint256 public constant FIRST_IMAGE_ID = ${first};

    /**
     * @notice How many characters this chunk carries.
     */
    uint256 public constant IMAGE_COUNT = ${schema.imagesPerChunk};

    /**
     * @notice Bytes per record.
     */
    uint256 public constant STRIDE = ${STRIDE};

    bytes private constant DATA =
        hex"${slice.toString('hex')}";

    /**
     * @notice Every record in this chunk.
     * @return The records, in character order
     */
    function data() external pure returns (bytes memory) {
        return DATA;
    }

    /**
     * @notice keccak256 of the records, computed on every call.
     * @return The hash of this chunk's records
     */
    function dataHash() external pure returns (bytes32) {
        return keccak256(DATA);
    }

    /**
     * @notice The packed record for one character.
     * @param imageId Which character, from ${first} to ${last}
     * @return The record, right aligned in a uint40
     */
    function record(uint256 imageId) external pure returns (uint40) {
        if (imageId < FIRST_IMAGE_ID || imageId >= FIRST_IMAGE_ID + IMAGE_COUNT) {
            revert OutOfChunk();
        }
        bytes memory d = DATA;
        uint256 offset = (imageId - FIRST_IMAGE_ID) * STRIDE;
        uint40 packed;
        for (uint256 i = 0; i < STRIDE; ++i) {
            packed = (packed << 8) | uint40(uint8(d[offset + i]));
        }
        return packed;
    }
}
`
  )
}

const namesHash = hash(names)
emit(
  join(GEN, 'TraitNames.sol'),
  `${BANNER}
/**
 * @title TraitNames
 * @notice Every category and value name, one ${schema.nameSlot} byte slot each.
 * @dev Generated by scripts/characters/encode-traits.mjs. Do not edit by hand.
 *      The category names come first, then one block per category with a slot
 *      for every value its bits can hold. Unused slots read as a dash.
 */
contract TraitNames {
    error OutOfRange();

    /**
     * @notice Bytes per name slot.
     */
    uint256 public constant SLOT = ${schema.nameSlot};

    /**
     * @notice Slots in the table.
     */
    uint256 public constant SLOT_COUNT = ${SLOT_COUNT};

    bytes private constant NAMES =
        hex"${names.toString('hex')}";

    /**
     * @notice The whole table.
     * @return The table, in slot order
     */
    function data() external pure returns (bytes memory) {
        return NAMES;
    }

    /**
     * @notice keccak256 of the table, computed on every call.
     * @return The hash of the name table
     */
    function namesHash() external pure returns (bytes32) {
        return keccak256(NAMES);
    }

    /**
     * @notice Several names in one call, with the table loaded once.
     * @param slots Which slots to read
     * @return out The names, in the order asked for
     */
    function namesAt(uint256[] calldata slots) external pure returns (string[] memory out) {
        bytes memory table = NAMES;
        out = new string[](slots.length);
        for (uint256 i = 0; i < slots.length; ++i) {
            if (slots[i] >= SLOT_COUNT) revert OutOfRange();
            out[i] = _read(table, slots[i]);
        }
    }

    /**
     * @notice Read one slot and trim its padding.
     * @param table The name table
     * @param slot Which slot to read
     * @return The name
     */
    function _read(bytes memory table, uint256 slot) private pure returns (string memory) {
        uint256 start = slot * SLOT;
        uint256 len;
        while (len < SLOT && table[start + len] != 0) {
            ++len;
        }
        bytes memory name = new bytes(len);
        for (uint256 i = 0; i < len; ++i) {
            name[i] = table[start + i];
        }
        return string(name);
    }
}
`
)

const list = (v) => v.join(', ')
emit(
  join(GEN, 'TraitSchema.sol'),
  `${BANNER}
/**
 * @title TraitSchema
 * @notice The shape of a packed trait record, and the hashes of the trait
 *         records and the name table.
 * @dev Generated by scripts/characters/encode-traits.mjs. Do not edit by hand.
 */
library TraitSchema {
    /**
     * @notice Characters in the collection.
     */
    uint256 internal constant IMAGE_COUNT = ${schema.imageCount};

    /**
     * @notice Characters whose traits came from the real art metadata. The
     *         deploy script refuses OP Mainnet unless every one did.
     */
    uint256 internal constant REAL_ROWS = ${REAL_ROWS};

    /**
     * @notice Trait categories per character.
     */
    uint256 internal constant CATEGORY_COUNT = ${CATS.length};

    /**
     * @notice Bytes per packed record.
     */
    uint256 internal constant STRIDE = ${STRIDE};

    /**
     * @notice Data contracts the records are split across.
     */
    uint256 internal constant CHUNK_COUNT = ${CHUNKS};

    /**
     * @notice Characters each data contract carries.
     */
    uint256 internal constant IMAGES_PER_CHUNK = ${schema.imagesPerChunk};

${chunkHashes.map((h, k) => `    /**\n     * @notice Expected dataHash of TraitData${k}.\n     */\n    bytes32 internal constant DATA_HASH_${k} = ${h};`).join('\n\n')}

    /**
     * @notice Expected namesHash of TraitNames.
     */
    bytes32 internal constant NAMES_HASH = ${namesHash};

    /**
     * @notice Bit offset of each category inside a record, most significant first.
     * @return One shift per category, in record order
     */
    function shifts() internal pure returns (uint8[${CATS.length}] memory) {
        return [${list(SHIFTS.map((s, i) => (i === 0 ? `uint8(${s})` : String(s))))}];
    }

    /**
     * @notice Value mask for each category.
     * @return One mask per category, in record order
     */
    function masks() internal pure returns (uint40[${CATS.length}] memory) {
        return [${list(CATS.map((c, i) => (i === 0 ? `uint40(${(1 << c.bits) - 1})` : String((1 << c.bits) - 1))))}];
    }

    /**
     * @notice First name slot of each category's value table.
     * @return One slot index per category, in record order
     */
    function valueBase() internal pure returns (uint16[${CATS.length}] memory) {
        return [${list(VALUE_BASE.map((b, i) => (i === 0 ? `uint16(${b})` : String(b))))}];
    }
}
`
)

if (!CHECK) {
  writeFileSync(join(FIXTURES, 'traits.bin'), blob)
  writeFileSync(join(FIXTURES, 'names.bin'), names)
  writeFileSync(
    join(FIXTURES, 'trait-schema.json'),
    JSON.stringify(
      {
        imageCount: schema.imageCount,
        stride: STRIDE,
        nameSlot: schema.nameSlot,
        chunkCount: CHUNKS,
        imagesPerChunk: schema.imagesPerChunk,
        categories: CATS.map((c, i) => ({
          name: c.name,
          bits: c.bits,
          shift: SHIFTS[i],
          mask: (1 << c.bits) - 1,
          valueBase: VALUE_BASE[i],
          values: c.values
        }))
      },
      null,
      2
    ) + '\n'
  )
}

console.log(`schema       ${CATS.length} categories, ${STRIDE_BITS} bits -> ${STRIDE} bytes per record`)
console.log(`traits       ${blob.length} bytes across ${CHUNKS} chunks of ${schema.imagesPerChunk} images`)
console.log(`names        ${names.length} bytes, ${SLOT_COUNT} slots of ${schema.nameSlot}`)
console.log(CHECK ? 'check        generated sources are current' : `wrote        ${written.length} sources + 3 fixtures`)
