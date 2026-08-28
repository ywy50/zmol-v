//! SMOL-V: SPIR-V, but smaller.
//!
//! A Zig implementation of the SMOL-V codec — https://github.com/aras-p/smol-v
//! by Aras Pranckevičius. SMOL-V re-encodes a SPIR-V module into a form roughly
//! 3x smaller that also compresses better, and decodes back to exactly the
//! bytes it was given.
//!
//! It is not a Unity format. Unity is its most prominent user (Vulkan shader
//! data in an AssetBundle is SMOL-V), which is what usually brings people here,
//! but nothing in this file knows anything about Unity.
//!
//! **This is a port, and it is checked against the original rather than
//! trusted.** The opcode table in `op_table.zig` is *generated* from the
//! reference C++ source instead of retyped, and the test suite encodes real
//! SPIR-V through both this code and the upstream C++ and compares the bytes.

const std = @import("std");
const table = @import("op_table.zig");

pub const spirv_magic: u32 = 0x07230203;
pub const smolv_magic: u32 = 0x534D4F4C;
pub const encoding_version: u32 = 1;

// Opcodes the encoder special-cases. These are indices into the generated
// table, so they cannot drift away from it.
const op_nop: u16 = 0;
const op_undef: u16 = 1;
const op_source_continued: u16 = 2;
const op_source: u16 = 3;
const op_source_extension: u16 = 4;
const op_string: u16 = 7;
const op_line: u16 = 8;
const op_extension: u16 = 10;
const op_ext_inst_import: u16 = 11;
const op_vector_shuffle_compact: u16 = 13;
const op_memory_model: u16 = 14;
const op_entry_point: u16 = 15;
const op_type_pointer: u16 = 32;
const op_variable: u16 = 59;
const op_load: u16 = 61;
const op_store: u16 = 62;
const op_access_chain: u16 = 65;
const op_decorate: u16 = 71;
const op_member_decorate: u16 = 72;
const op_vector_shuffle: u16 = 79;
const op_f_negate: u16 = 127;
const op_f_add: u16 = 129;
const op_f_mul: u16 = 133;
const op_label: u16 = 248;

const decoration_offset: u32 = 35;

pub const Error = error{
    /// Not a SPIR-V module: wrong magic, or a length that is not a whole
    /// number of 32-bit words.
    NotSpirv,
    /// A SPIR-V instruction claims a length that runs past the end of the
    /// module, or is too short for the operands its opcode requires.
    Malformed,
    OutOfMemory,
};

const Out = std.ArrayList(u8);

fn write4(out: *Out, allocator: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}

fn writeVarint(out: *Out, allocator: std.mem.Allocator, value_in: u32) !void {
    var value = value_in;
    while (value > 127) {
        try out.append(allocator, @intCast((value & 127) | 128));
        value >>= 7;
    }
    try out.append(allocator, @intCast(value & 127));
}

/// Fold a signed delta into an unsigned varint so that small negative values
/// stay one byte. Deltas go negative on branches and on spirv-remap'd input.
fn zigEncode(value: u32) u32 {
    const signed: i32 = @bitCast(value);
    const sign: u32 = @bitCast(signed >> 31);
    return (value << 1) ^ sign;
}

/// Swap the most common opcodes into the smallest enum slots, so the combined
/// length+opcode word usually fits in a single varint byte.
fn remapOp(op: u16) u16 {
    return switch (op) {
        op_decorate => op_nop,
        op_nop => op_decorate,
        op_load => op_undef,
        op_undef => op_load,
        op_store => op_source_continued,
        op_source_continued => op_store,
        op_access_chain => op_source,
        op_source => op_access_chain,
        op_vector_shuffle => op_source_extension,
        op_source_extension => op_vector_shuffle,
        op_member_decorate => op_string,
        op_string => op_member_decorate,
        op_label => op_line,
        op_line => op_label,
        op_variable => @as(u16, 9),
        @as(u16, 9) => op_variable,
        op_f_mul => op_extension,
        op_extension => op_f_mul,
        op_f_add => op_ext_inst_import,
        op_ext_inst_import => op_f_add,
        op_type_pointer => op_memory_model,
        op_memory_model => op_type_pointer,
        op_f_negate => op_entry_point,
        op_entry_point => op_f_negate,
        else => op,
    };
}

/// Instruction lengths have a known minimum per opcode; subtracting it keeps
/// the common case inside three bits.
fn encodeLen(op: u16, len_in: u32) u32 {
    var len = len_in -% 1;
    if (op == op_vector_shuffle or op == op_vector_shuffle_compact) {
        len -%= 4;
    } else if (op == op_decorate) {
        len -%= 2;
    } else if (op == op_load or op == op_access_chain) {
        len -%= 3;
    }
    return len;
}

fn writeLengthOp(out: *Out, allocator: std.mem.Allocator, len_in: u32, op_in: u16) !void {
    const len = encodeLen(op_in, len_in);
    // A length over 16 bits means the input was malformed — e.g. a vector
    // shuffle shorter than 4 words, whose adjustment above wrapped around.
    if (len > 0xFFFF) return Error.Malformed;
    const op: u32 = remapOp(op_in);
    const word: u32 = ((len >> 4) << 20) | ((op >> 4) << 8) | ((len & 0xF) << 4) | (op & 0xF);
    try writeVarint(out, allocator, word);
}

fn decorationExtraOps(decoration: u32) i32 {
    // RelaxedPrecision, Block..ColMajor
    if (decoration == 0 or (decoration >= 2 and decoration <= 5)) return 0;
    if (decoration >= 29 and decoration <= 37) return 1; // Stream..XfbStride
    return -1; // unknown: the length is written out
}

fn hasResult(op: u16) bool {
    return op < table.known_ops and table.op_data[op].has_result;
}

fn hasType(op: u16) bool {
    return op < table.known_ops and table.op_data[op].has_type;
}

fn deltaFromResult(op: u16) u8 {
    return if (op < table.known_ops) table.op_data[op].delta_from_result else 0;
}

fn varRest(op: u16) bool {
    return op < table.known_ops and table.op_data[op].var_rest;
}

fn encodeMemberDecorates(
    words: []const u32,
    allocator: std.mem.Allocator,
    out: *Out,
    decoration_type: u32,
    start: usize,
) Error!usize {
    var member_at = start;
    var prev_index: u32 = 0;
    var prev_offset: u32 = 0;
    const count_at = out.items.len;
    try out.append(allocator, 0);
    var count: u32 = 0;
    while (member_at < words.len and count < 255) {
        const member_len = words[member_at] >> 16;
        if (member_len < 1 or member_at + member_len > words.len) return Error.Malformed;
        const member_op: u16 = @truncate(words[member_at] & 0xFFFF);
        if (member_op != op_member_decorate) break;
        if (member_len < 4) return Error.Malformed;
        if (words[member_at + 1] != decoration_type) break;

        const member_index = words[member_at + 2];
        try writeVarint(out, allocator, member_index -% prev_index);
        prev_index = member_index;

        const member_dec = words[member_at + 3];
        try writeVarint(out, allocator, member_dec);
        const known_extra = decorationExtraOps(member_dec);
        if (known_extra == -1) {
            try writeVarint(out, allocator, member_len - 4);
        } else if (@as(u32, @intCast(known_extra)) + 4 != member_len) {
            return Error.Malformed;
        }

        if (member_dec == decoration_offset) {
            if (member_len != 5) return Error.Malformed;
            try writeVarint(out, allocator, words[member_at + 4] -% prev_offset);
            prev_offset = words[member_at + 4];
        } else {
            var k: u32 = 4;
            while (k < member_len) : (k += 1) {
                try writeVarint(out, allocator, words[member_at + k]);
            }
        }
        member_at += member_len;
        count += 1;
    }
    out.items[count_at] = @intCast(count);
    return member_at;
}

/// Encode a SPIR-V module into SMOL-V. The caller owns the returned slice.
pub fn encode(allocator: std.mem.Allocator, spirv: []const u8) Error![]u8 {
    if (spirv.len % 4 != 0 or spirv.len < 5 * 4) return Error.NotSpirv;
    const word_count = spirv.len / 4;

    const words = try allocator.alloc(u32, word_count);
    defer allocator.free(words);
    for (words, 0..) |*w, i| {
        w.* = std.mem.readInt(u32, spirv[i * 4 ..][0..4], .little);
    }
    if (words[0] != spirv_magic) return Error.NotSpirv;

    var out: Out = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, spirv.len);

    // The header mirrors SPIR-V's, with a different magic, the SMOL-V encoding
    // version folded into the top byte of the version word, and the decoded
    // size appended so a decoder knows how much to reserve.
    try write4(&out, allocator, smolv_magic);
    try write4(&out, allocator, (words[1] & 0x00FFFFFF) + (encoding_version << 24));
    try write4(&out, allocator, words[2]); // generator
    try write4(&out, allocator, words[3]); // bound
    try write4(&out, allocator, words[4]); // schema
    try write4(&out, allocator, @intCast(spirv.len));

    var prev_result: u32 = 0;
    var prev_decorate: u32 = 0;

    var i: usize = 5;
    while (i < word_count) {
        const instr_len = words[i] >> 16;
        if (instr_len < 1 or i + instr_len > word_count) return Error.Malformed;
        var op: u16 = @truncate(words[i] & 0xFFFF);

        // A vector shuffle of at most 4 components, each in [0..3], collapses
        // into one swizzle byte under the otherwise-unused opcode slot 13.
        var swizzle: u8 = 0;
        if (op == op_vector_shuffle and instr_len <= 9) {
            const s0 = if (instr_len > 5) words[i + 5] else 0;
            const s1 = if (instr_len > 6) words[i + 6] else 0;
            const s2 = if (instr_len > 7) words[i + 7] else 0;
            const s3 = if (instr_len > 8) words[i + 8] else 0;
            if (s0 < 4 and s1 < 4 and s2 < 4 and s3 < 4) {
                op = op_vector_shuffle_compact;
                swizzle = @intCast((s0 << 6) | (s1 << 4) | (s2 << 2) | s3);
            }
        }

        try writeLengthOp(&out, allocator, instr_len, op);

        var ioffs: u32 = 1;
        if (hasType(op)) {
            if (ioffs >= instr_len) return Error.Malformed;
            try writeVarint(&out, allocator, words[i + ioffs]);
            ioffs += 1;
        }
        if (hasResult(op)) {
            if (ioffs >= instr_len) return Error.Malformed;
            const v = words[i + ioffs];
            try writeVarint(&out, allocator, zigEncode(v -% prev_result));
            prev_result = v;
            ioffs += 1;
        }

        // Decorate and MemberDecorate target IDs are written relative to the
        // previous decoration's, which spirv-remap makes densely sequential.
        if (op == op_decorate or op == op_member_decorate) {
            if (ioffs >= instr_len) return Error.Malformed;
            const v = words[i + ioffs];
            try writeVarint(&out, allocator, zigEncode(v -% prev_decorate));
            prev_decorate = v;
            ioffs += 1;
        }

        // A run of MemberDecorate on one type, with linearly increasing member
        // indices, is encoded as a single counted bunch.
        if (op == op_member_decorate) {
            const decoration_type = words[i + ioffs - 1];
            const result = try encodeMemberDecorates(words, allocator, &out, decoration_type, i);
            i = result;
            continue;
        }

        // These operands are IDs near the result ID, so they go out as
        // zig-zagged deltas from it.
        var relative = deltaFromResult(op);
        while (relative > 0 and ioffs < instr_len) : (relative -= 1) {
            try writeVarint(&out, allocator, zigEncode(prev_result -% words[i + ioffs]));
            ioffs += 1;
        }

        if (op == op_vector_shuffle_compact) {
            try out.append(allocator, swizzle);
            ioffs = instr_len;
        } else if (varRest(op)) {
            // Expected to be small integers, so varint pays off.
            while (ioffs < instr_len) : (ioffs += 1) {
                try writeVarint(&out, allocator, words[i + ioffs]);
            }
        } else {
            while (ioffs < instr_len) : (ioffs += 1) {
                try write4(&out, allocator, words[i + ioffs]);
            }
        }

        i += instr_len;
    }

    return out.toOwnedSlice(allocator);
}

/// The size the SMOL-V module decodes back to, read from its header.
pub fn decodedSize(smolv: []const u8) Error!u32 {
    if (smolv.len < 6 * 4) return Error.Malformed;
    if (std.mem.readInt(u32, smolv[0..4], .little) != smolv_magic) return Error.Malformed;
    return std.mem.readInt(u32, smolv[20..24], .little);
}

test "rejects input that is not SPIR-V" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(Error.NotSpirv, encode(allocator, "not spirv at all!!!!!!!!"));
    try std.testing.expectError(Error.NotSpirv, encode(allocator, &[_]u8{ 1, 2, 3 }));
}

test "zig-zag keeps small negatives small" {
    try std.testing.expectEqual(@as(u32, 0), zigEncode(0));
    try std.testing.expectEqual(@as(u32, 2), zigEncode(1));
    try std.testing.expectEqual(@as(u32, 1), zigEncode(@bitCast(@as(i32, -1))));
    try std.testing.expectEqual(@as(u32, 3), zigEncode(@bitCast(@as(i32, -2))));
}

test "opcode remapping is its own inverse" {
    var op: u16 = 0;
    while (op < table.known_ops) : (op += 1) {
        try std.testing.expectEqual(op, remapOp(remapOp(op)));
    }
}

// --- Checked against the reference implementation -------------------------
//
// The fixtures are real SPIR-V (a vertex and a fragment shader produced by
// vkd3d-compiler) and the `.smolv` beside each one is what the upstream C++
// encoder produced from it. Embedding both makes the check hermetic: no
// toolchain, no subprocess, and a byte-for-byte comparison rather than a
// "looks about right" size check. `tools/regenerate_fixtures.sh` rebuilds them.

fn expectMatchesReference(spirv: []const u8, expected: []const u8) !void {
    const encoded = try encode(std.testing.allocator, spirv);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, expected, encoded);
}

test "encodes a fragment shader exactly as the reference C++ does" {
    try expectMatchesReference(
        @embedFile("testdata/unlit_fragment.spv"),
        @embedFile("testdata/unlit_fragment.smolv"),
    );
}

test "encodes a vertex shader exactly as the reference C++ does" {
    try expectMatchesReference(
        @embedFile("testdata/unlit_vertex.spv"),
        @embedFile("testdata/unlit_vertex.smolv"),
    );
}

test "encode rejects SPIR-V with instruction length exceeding module bounds" {
    const allocator = std.testing.allocator;
    // Valid five-word header, then one word whose length field (top 16 bits)
    // claims 1000 words — far past the module end.
    const bad: [6]u32 = .{
        spirv_magic,
        0x00010000,
        0,
        1,
        0,
        (1000 << 16) | 1, // length=1000, opcode=1 (Undef)
    };
    const bytes = std.mem.sliceAsBytes(&bad);
    try std.testing.expectError(Error.Malformed, encode(allocator, bytes));
}

test "encode rejects SPIR-V with zero-length instruction" {
    const allocator = std.testing.allocator;
    const bad: [6]u32 = .{
        spirv_magic,
        0x00010000,
        0,
        1,
        0,
        (0 << 16) | 1, // length=0, opcode=1 — length < 1 is Malformed
    };
    const bytes = std.mem.sliceAsBytes(&bad);
    try std.testing.expectError(Error.Malformed, encode(allocator, bytes));
}

test "the header records the size the module decodes back to" {
    const spirv = @embedFile("testdata/unlit_vertex.spv");
    const encoded = try encode(std.testing.allocator, spirv);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqual(@as(u32, spirv.len), try decodedSize(encoded));
    try std.testing.expect(encoded.len < spirv.len / 2); // it is meant to be smaller
}

test "decodedSize rejects input shorter than 24 bytes" {
    try std.testing.expectError(Error.Malformed, decodedSize(&[_]u8{0} ** 20));
}

test "decodedSize rejects input with wrong magic" {
    var buf: [24]u8 = [_]u8{0} ** 24;
    std.mem.writeInt(u32, buf[0..4], 0xDEADBEEF, .little);
    std.mem.writeInt(u32, buf[20..24], 1234, .little);
    try std.testing.expectError(Error.Malformed, decodedSize(&buf));
}

test "encode rejects empty input" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(Error.NotSpirv, encode(allocator, &[_]u8{}));
}

test "encode rejects 20-byte zero block (passes length check, fails magic)" {
    const allocator = std.testing.allocator;
    const too_short: [20]u8 = [_]u8{0} ** 20;
    try std.testing.expectError(Error.NotSpirv, encode(allocator, &too_short));
}
