//! The Unity shader sub-program blob: how Unity wraps SMOL-V modules.
//!
//! SMOL-V itself knows nothing about Unity (`smolv.zig` has no Unity code in
//! it). This file is the other half: the container Unity puts those modules in,
//! and the conventions its Vulkan backend expects of the SPIR-V inside them.
//!
//! Everything here was decoded from shipped Unity 2022.3 AssetBundles, because
//! none of it is documented anywhere.

const std = @import("std");

/// `ShaderCompilerPlatform.Vulkan`.
pub const platform_vulkan: u32 = 18;
/// The program type a Vulkan **code** record carries.
pub const program_vulkan: u32 = 25;
/// Section A's header is this long in every record examined.
pub const section_header_size: u32 = 176;
/// The version-and-flags word every stock record starts with.
pub const container_version: u32 = 0x02000061;

/// The six-word size table that opens a Vulkan record's payload.
///
/// Measured across four shipped shaders, `section_a + section_b` equals the
/// payload length exactly, and `a_payload` equals `section_a - 176`:
///
/// ```text
/// Standard        2940 = 1199 + 1741      XFade      3449 = 1708 + 1741
/// EntityTintMask  3758 =  922 + 2836      VertexLit  4631 =  703 + 3928
/// ```
pub const Header = extern struct {
    version: u32,
    section_a: u32,
    section_b: u32,
    header_size: u32,
    a_payload: u32,
    reserved: u32,
};

/// Which stage each section carries.
///
/// **Read from the modules, not guessed**: decoding both sections of
/// `Legacy Shaders/Transparent/Cutout/VertexLit` and disassembling them gives
/// `OpEntryPoint Fragment` for section A and `OpEntryPoint Vertex` for B.
/// Section B is also the larger module in all four shaders measured, which is
/// the weaker signal that first suggested the opposite and was wrong.
pub const section_a_stage = .fragment;
pub const section_b_stage = .vertex;

/// Unity's descriptor-set convention for the SPIR-V inside a Vulkan record.
///
/// A translator such as `vkd3d-compiler` puts every resource in set 0. Unity
/// does not, and a module that follows the translator's convention collides
/// with the set Unity reserves for resources:
///
/// ```text
/// stock fragment  set 0 binding 0   texture
///                 set 1 binding 0   constant buffer
/// stock vertex    set 1 binding 1   constant buffer
/// ```
pub const set_resources: u32 = 0;
pub const set_constant_buffers: u32 = 1;

/// SPIR-V storage classes that decide which set a variable belongs in.
pub const storage_class_uniform_constant: u32 = 0; // images, samplers
pub const storage_class_uniform: u32 = 2; // constant buffers

/// The `ParserBindChannels` block a Vulkan **code** record carries after its
/// SMOL-V payload — the same structure a d3d11 vertex record ends with.
///
/// A record without it is refused: the shader loads, `Shader.isSupported` is
/// true, and the prop draws in the magenta error shader with no log line. This
/// was the real reason a hand-built Vulkan record was rejected; it was found by
/// byte-diffing against a stock record carrying the same modules — they matched
/// exactly but for the (unvalidated) hash, and stock was 32 bytes longer: this
/// block.
///
/// Layout: `u32 source_mask`, `u32 count`, then `count` × `(u32 source, u32
/// target)`. `source` is the mesh channel (bit 0 Position, 1 Normal, 4
/// TexCoord0, …); `target` is the attribute's slot in the program's
/// vertex-input declaration **plus 13** — **not** the SPIR-V `Location` as
/// stored in the module and not the d3d11 vertex-component slot. Measured
/// across seven stock shaders (VertexLit, Diffuse, Specular, Transparent/*,
/// Bumped Diffuse, Particles/Additive): the module's inputs are decorated
/// `Location 0, 1, 2, …` in declaration order while the bind record carries
/// the same order offset by 13:
///
/// ```text
/// VertexLit / Diffuse (Position, Normal, TexCoord0)      (0,13) (1,14) (4,15)
/// Bumped Diffuse (Position, Normal, Tangent, TexCoord0)  (0,13) (1,14) (2,15) (4,16)
/// Particles/Additive (Position, Color, TexCoord0)        (0,13) (3,14) (4,15)
/// ```
///
/// An earlier revision of this file called the target the SPIR-V input
/// location; that was wrong — the stock modules' locations are 0, 1, 2 while
/// their targets are 13, 14, 15. The runtime reconciles the two (the pipeline
/// is built from the bind record and the module's declared inputs together),
/// so a writer must emit the declaration-slot-plus-13 convention, not the
/// module's own locations.
pub const BindChannel = struct { source: u32, target: u32 };

/// Every stock fragment module is one **combined** image-sampler.
///
/// All six measured stock fragment modules declare their texture as a single
/// `OpTypeSampledImage` variable at descriptor set 0, binding 0, because Unity
/// compiles its Vulkan modules with glslang from the GLSL its HLSLCC emits,
/// where `uniform sampler2D` is one object. Compiling HLSL (`Texture2D` +
/// `SamplerState`) makes glslang emit an image **and** a sampler as two
/// variables on the same binding — a shape no stock module carries. Author the
/// Vulkan fragment in GLSL 450 with `layout(binding = 0) uniform sampler2D`
/// and compile it with glslang in GLSL mode (no `-D`).
pub const fragment_sampler_is_combined = true;

/// The `VGlobals`/`PGlobals` member offsets are per-record, not a fixed engine
/// layout. `unity_ObjectToWorld` sits at 0 in Diffuse and Particles/Additive
/// but 256 in VertexLit; `unity_MatrixVP` at 64, 128, 144 or 528 across the
/// same set. The runtime fills each record's globals buffer at the offsets its
/// own parameter record declares, so a writer chooses its own member offsets
/// and declares them consistently in the parameter record and the module.
pub const globals_offsets_are_per_record = true;

/// The 32-byte field at payload words 20..27 is **not validated**.
///
/// Corrupting every byte of it in an otherwise-untouched stock Vulkan blob
/// still renders (measured 2026-08-25). It looks like a `Hash128` and earlier
/// analysis concluded it was checked; a controlled corrupt-and-load experiment
/// disproved that. Write zero and move on — the record's acceptance depends on
/// the bind-channels block above, not on this.
pub const hash_field_is_validated = false;

test "the size table is six words, as the container expects" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Header));
}

test "a stock header's invariants hold" {
    // VertexLit's, as measured.
    const header = Header{
        .version = container_version,
        .section_a = 703,
        .section_b = 3928,
        .header_size = section_header_size,
        .a_payload = 527,
        .reserved = 0,
    };
    try std.testing.expectEqual(@as(u32, 4631), header.section_a + header.section_b);
    try std.testing.expectEqual(header.a_payload, header.section_a - section_header_size);
}
