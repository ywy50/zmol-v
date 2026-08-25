//! The Unity shader sub-program blob: how Unity wraps SMOL-V modules.
//!
//! SMOL-V itself knows nothing about Unity (`smolv.zig` has no Unity code in
//! it). This file is the other half: the container Unity puts those modules
//! in, and the conventions its Vulkan backend expects of the SPIR-V inside
//! them. The measured detail behind every constant here is in
//! `docs/unity-vulkan-container.md` (decoded from shipped Unity 2022.3
//! AssetBundles; none of it is documented anywhere).

const std = @import("std");

/// `ShaderCompilerPlatform.Vulkan`.
pub const platform_vulkan: u32 = 18;
/// The program type a Vulkan code record carries (both stages in one record).
pub const program_vulkan: u32 = 25;
/// Section A's header is this long in every record examined.
pub const section_header_size: u32 = 176;
/// Version and flags; measured `0x02000060` on every stock code record.
pub const container_version: u32 = 0x02000060;

/// The six-word size table that opens a Vulkan record's payload.
/// `section_a + section_b` equals the payload length (padded to 4 before the
/// bind-channels block); `a_payload` equals `section_a - 176`.
pub const Header = extern struct {
    version: u32,
    section_a: u32,
    section_b: u32,
    header_size: u32,
    a_payload: u32,
    reserved: u32,
};

/// Section A is the fragment stage, section B the vertex stage - read from
/// `OpEntryPoint` of the decoded modules, not guessed.
pub const section_a_stage = .fragment;
pub const section_b_stage = .vertex;

/// Unity's descriptor-set convention: textures in set 0, constant buffers in
/// set 1 (a translator like vkd3d-compiler puts everything in set 0).
pub const set_resources: u32 = 0;
pub const set_constant_buffers: u32 = 1;

/// SPIR-V storage classes that decide which set a variable belongs in.
pub const storage_class_uniform_constant: u32 = 0; // images, samplers
pub const storage_class_uniform: u32 = 2; // constant buffers

/// A code record's `ParserBindChannels` tail: `u32 source_mask`, `u32 count`,
/// then `count` x (source, target). A record without it is refused silently.
/// Target is the vertex-input declaration slot plus 13, not the SPIR-V
/// `Location` and not the d3d11 component slot.
pub const BindChannel = struct { source: u32, target: u32 };

/// Every stock fragment module is one combined `OpTypeSampledImage` at set 0
/// binding 0; author the fragment in GLSL so glslang emits that shape.
pub const fragment_sampler_is_combined = true;

/// `VGlobals`/`PGlobals` member offsets are per-record, not a fixed engine
/// layout; declare the writer's own offsets in the parameter record.
pub const globals_offsets_are_per_record = true;

/// The 32-byte field at payload words 20..27 is not validated (a live client
/// renders a stock blob with every byte corrupted); write zero.
pub const hash_field_is_validated = false;

/// Parameter-record entry index encoding: `(stage << 24) | (kind << 16) |
/// slot`, with constant-buffer entries carrying array size 0. The material
/// binder keys on these; the module's own descriptor sets are separate.
pub const param_entry_index_stage_vertex: u32 = 0x04;
pub const param_entry_index_stage_fragment: u32 = 0x08;
pub const param_entry_index_kind_cbuffer: u32 = 0x01;
pub const param_entry_index_kind_texture: u32 = 0x00;
pub const param_entry_texture_slot0: u32 = 0x08000000;
pub const param_entry_vglobals_vertex_record: u32 = 0x04010000;
pub const param_entry_vglobals_fragment_record: u32 = 0x04010001;
pub const param_entry_pglobals: u32 = 0x08010000;

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
