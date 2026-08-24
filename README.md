# zmol-v

SMOL-V in Zig — compress SPIR-V shader modules to roughly a third of their size
— plus the **Unity shader blob** container that carries them inside an
AssetBundle.

## Quick start

Add it to your `build.zig.zon`:

```bash
zig fetch --save git+https://github.com/ywy50/zmol-v
```

Use the codec:

```zig
const smolv = @import("smolv");

const encoded = try smolv.encode(allocator, spirv_bytes);
defer allocator.free(encoded);
```

Build and run the tests:

```bash
zig build test --summary all
```

From another language, through the C ABI:

```bash
zig build
```

```python
import ctypes

lib = ctypes.CDLL("zig-out/lib/libzmolv.so")
lib.zmolv_encode.restype = ctypes.c_int
```

Everything below is detail.

## The C ABI

`zig build` also produces `libzmolv.so` (`.dylib`, `.dll`) exporting two
functions, for callers that are not Zig:

```c
int  zmolv_encode(const uint8_t *spirv, size_t len, uint8_t **out, size_t *out_len);
void zmolv_free(uint8_t *ptr, size_t len);
```

`zmolv_encode` returns 0 on success and writes a freshly allocated buffer
through `out`, which the caller releases with `zmolv_free`. Non-zero is
1 = not SPIR-V, 2 = malformed, 3 = out of memory.

There is a C ABI rather than a command-line tool because it is the one
interface that does not move between Zig releases.

## What this is

[SMOL-V](https://github.com/aras-p/smol-v) by Aras Pranckevičius re-encodes a
SPIR-V module into a form about 3x smaller that also compresses better, and
decodes back to exactly the bytes it was given. It does this by knowing what
SPIR-V instructions look like: varint-packing operands that are usually small,
writing result IDs as deltas, and folding the most common opcodes into the
shortest encodings.

This is a Zig implementation of that codec, and it is **checked against the
original rather than trusted**:

- the 367-entry opcode table is **generated** from the reference C++ source by
  `tools/generate_table.py`, not retyped, so it cannot drift by a typo;
- the test suite encodes real SPIR-V modules and compares the output
  **byte for byte** against what the upstream C++ encoder produced from the
  same input. The fixtures under `src/testdata/` are those bytes.

## SMOL-V is not a Unity format

Unity is SMOL-V's most prominent user — the Vulkan shader data in an
AssetBundle is SMOL-V — and that is what usually brings people here. But the
codec itself knows nothing about Unity, and `src/smolv.zig` has no Unity code
in it.

The Unity-specific part lives beside it, because it is the part with no
published description anywhere: how a Unity **shader sub-program blob** wraps
those compressed modules.

## The Unity Vulkan sub-program record

Decoded from shipped Unity 2022.3 AssetBundles. A Vulkan code record is program
type **25**, and its payload is a container:

| word | value | meaning |
|---|---|---|
| 0 | `0x02000060` / `0x02000061` | version and flags |
| 1 | varies | size of section **A** |
| 2 | varies | size of section **B** |
| 3 | `176` | size of section A's header |
| 4 | = word 1 − 176 | section A's payload |
| 5 | `0` | not decoded |

`word1 + word2` equals the payload length exactly. Both sections hold SMOL-V:
the first four bytes at payload offset `word1`, and again at offset 176 inside
section A, are `4c 4f 4d 53` — the SMOL-V magic `0x534D4F4C`. **Two modules per
record**, which is why Unity reports `stageCounts` of 1 for Vulkan where d3d11
uses two records and reports 2.

Measured across four shaders:

```text
Standard        2940 = 1199 + 1741      XFade      3449 = 1708 + 1741
EntityTintMask  3758 =  922 + 2836      VertexLit  4631 =  703 + 3928
```

## Regenerating the fixtures

The reference encoder is not vendored; the fixtures it produced are. To rebuild
them you need the upstream source and a C++ compiler:

```bash
tools/regenerate_fixtures.sh
```

## Credit and licence

The format, the algorithm and the opcode table are Aras Pranckevičius's work in
[aras-p/smol-v](https://github.com/aras-p/smol-v), released into the public
domain (or MIT, at your option). This implementation is offered under the same
terms.
