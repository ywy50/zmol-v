# The Unity Vulkan shader container

Everything here was decoded from shipped Unity 2022.3 AssetBundles
(`7 Days To Die`'s `data.unity3d`), because none of it is documented
anywhere. The constants live in `src/unity.zig`; this page is the measured
detail behind them, with the sources and the numbers.

## The code record

A Vulkan code record is program type **25** and carries **both stages** -
which is why Unity reports `stageCounts` of 1 for Vulkan where d3d11 uses
two records and reports 2.

| word | value | meaning |
|---|---|---|
| 0 | `0x02000060` | version and flags (an earlier survey read `0x02000061`; every code record of six shipped shaders carries `0x60`) |
| 1 | varies | size of section **A** |
| 2 | varies | size of section **B** |
| 3 | `176` | size of section A's header |
| 4 | = word 1 - 176 | section A's payload |
| 5 | `0` | not decoded |

`word1 + word2` equals the payload length, which is padded to 4 before the
bind-channels block that follows the payload. A record whose payload length
was left unaligned made a live Vulkan draw fault on AMD RADV - device lost,
no log line - because the runtime read the bind block from mid-padding.

Both sections hold SMOL-V: the first four bytes at payload offset `word1`,
and again at offset 176 inside section A, are `4c 4f 4d 53` - the SMOL-V
magic `0x534D4F4C`.

Measured across four shaders:

```text
Standard        2940 = 1199 + 1741      XFade      3449 = 1708 + 1741
EntityTintMask  3758 =  922 + 2836      VertexLit  4631 =  703 + 3928
```

### Section order

Section A is the fragment stage, section B the vertex stage, read from
`OpEntryPoint` of the decoded modules - not guessed. Section B is also the
larger module in all four shaders measured, which is the weaker signal that
first suggested the opposite and was wrong.

## The parameter records that precede the code record

A Vulkan blob opens with one or more **parameter** records (program types 2
and 3) declaring the buffers, textures and bindings the material binder keys
on, then the code record(s).

### The entry index is `(stage << 24) | (kind << 16) | slot`

Each entry carries an index that is **not** a plain slot. Measured across
every stock parameter record in the installed game (VertexLit, Diffuse,
Bumped Diffuse, Specular, Particles/Additive, Transparent/*): the index
encodes the binding program's stage in the top byte, a kind byte, and the
slot in the low 16 bits:

```text
stage  0x04 = vertex program   0x08 = fragment program
kind   0x01 = constant buffer  0x00 = texture
```

| entry | stage | kind | slot | index |
|---|---|---|---|---|
| `_MainTex` (texture) | 0x08 | 0x00 | 0 | `0x08000000` |
| `VGlobals` in a vertex record (cbuffer) | 0x04 | 0x01 | 0 | `0x04010000` |
| `VGlobals` in a fragment record (cbuffer) | 0x04 | 0x01 | 1 | `0x04010001` |
| `PGlobals` (cbuffer) | 0x08 | 0x01 | 0 | `0x08010000` |

Constant-buffer entries carry `array_size 0` (the third word of the binding
entry). A writer that emitted plain slot indices with array size 1 saw its
Vulkan draw fault on AMD RADV - device lost, no log line - with every other
dimension of the record stock-shaped. The entries are what the material
binder keys on; the module's own descriptor sets/bindings are derived from
the modules, so the two conventions coexist.

## The 32-byte field at payload words 20..27 is not validated

Corrupting every byte of it in an otherwise-untouched stock Vulkan blob
still renders (measured 2026-08-25). It looks like a `Hash128` and earlier
analysis concluded it was checked; a controlled corrupt-and-load experiment
disproved that. Write zero and move on - the record's acceptance depends on
the bind-channels block, not on this field.

## The bind-channels block

A Vulkan code record carries a `ParserBindChannels` block after its SMOL-V
payload - the same structure a d3d11 vertex record ends with. A record
without it is refused: the shader loads, `Shader.isSupported` is true, and
the prop draws in the magenta error shader with no log line.

Layout: `u32 source_mask`, `u32 count`, then `count` x `(u32 source, u32
target)`. `source` is the mesh channel (bit 0 Position, 1 Normal, 4
TexCoord0, ...); `target` is the attribute's slot in the program's
vertex-input declaration **plus 13** - **not** the SPIR-V `Location` as
stored in the module and not the d3d11 vertex-component slot. Measured
across seven stock shaders (VertexLit, Diffuse, Specular, Transparent/*,
Bumped Diffuse, Particles/Additive): the module's inputs are decorated
`Location 0, 1, 2, ...` in declaration order while the bind record carries
the same order offset by 13:

```text
VertexLit / Diffuse (Position, Normal, TexCoord0)      (0,13) (1,14) (4,15)
Bumped Diffuse (Position, Normal, Tangent, TexCoord0)  (0,13) (1,14) (2,15) (4,16)
Particles/Additive (Position, Color, TexCoord0)        (0,13) (3,14) (4,15)
```

An earlier revision of this file called the target the SPIR-V input
location; that was wrong - the stock modules' locations are 0, 1, 2 while
their targets are 13, 14, 15. The runtime reconciles the two (the pipeline
is built from the bind record and the module's declared inputs together),
so a writer must emit the declaration-slot-plus-13 convention, not the
module's own locations.

## Descriptor sets

Unity's convention for the SPIR-V inside a Vulkan record:

```text
stock fragment  set 0 binding 0   texture
                set 1 binding 0   constant buffer
stock vertex    set 1 binding 1   constant buffer
```

A translator such as `vkd3d-compiler` puts every resource in set 0; a
module that follows the translator's convention collides with the set Unity
reserves for resources. The storage class decides which set a variable
belongs in: `UniformConstant` (images, samplers) goes to set 0, `Uniform`
(constant buffers) to set 1.

## The fragment is one combined image-sampler

Every measured stock fragment module declares its texture as a single
`OpTypeSampledImage` variable at descriptor set 0, binding 0, because Unity
compiles its Vulkan modules with glslang from the GLSL its HLSLCC emits,
where `uniform sampler2D` is one object. Compiling HLSL (`Texture2D` +
`SamplerState`) makes glslang emit an image **and** a sampler as two
variables on the same binding - a shape no stock module carries, and one
whose draw killed a live client on AMD RADV. Author the Vulkan fragment in
GLSL 450 with `layout(binding = 0) uniform sampler2D` and compile it with
glslang in GLSL mode.

## VGlobals/PGlobals member offsets are per-record

`unity_ObjectToWorld` sits at 0 in Diffuse and Particles/Additive but 256 in
VertexLit; `unity_MatrixVP` at 64, 128, 144 or 528 across the same set. The
runtime fills each record's globals buffer at the offsets its own parameter
record declares, so a writer chooses its own member offsets and declares
them consistently in the parameter record and the module.

## It renders

Every convention on this page was proven as a whole on 2026-08-25: a writer
that emits the code record, the bind-channels block, and the parameter
record with the entry encoding above draws its textured prop in a live
7 Days to Die client under `-force-vulkan` - `pass=6 fail=0`, DONE, zero
magenta pixels in the captured frame - where every earlier shape drew the
magenta error shader or lost the Vulkan device. The acceptance lives in
`hordeforge/7dtd-asset-pipeline` (the SelfTestMod block suites) and the
same facts are recorded in its `docs/research/research-provenance.md`.
