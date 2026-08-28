//! A C ABI for the encoder, so a pipeline in any language can call it.
//!
//! This exists instead of a command-line tool because a stable C ABI is the
//! one interface that does not move between Zig releases, and because the
//! caller is usually already loading shared libraries.

const std = @import("std");
const smolv = @import("smolv.zig");

/// Encode `spirv_len` bytes of SPIR-V into a freshly allocated buffer.
///
/// On success returns 0 and writes the buffer and its length through the out
/// parameters; the caller must release it with `zmolv_free`. On failure
/// returns non-zero and leaves the out parameters untouched:
/// 1 = not SPIR-V, 2 = malformed, 3 = out of memory.
export fn zmolv_encode(
    spirv: [*]const u8,
    spirv_len: usize,
    out_ptr: *[*]u8,
    out_len: *usize,
) c_int {
    // A NULL input carries no module to encode; answer with the code the
    // empty-input path would produce instead of dereferencing it.
    if (@intFromPtr(spirv) == 0) return 1;
    const allocator = std.heap.c_allocator;
    const encoded = smolv.encode(allocator, spirv[0..spirv_len]) catch |err| return switch (err) {
        error.NotSpirv => 1,
        error.Malformed => 2,
        error.OutOfMemory => 3,
    };
    out_ptr.* = encoded.ptr;
    out_len.* = encoded.len;
    return 0;
}

/// Release a buffer returned by `zmolv_encode`.
export fn zmolv_free(ptr: [*]u8, len: usize) void {
    std.heap.c_allocator.free(ptr[0..len]);
}

test "zmolv_encode maps failure onto the documented codes" {
    var out_ptr: [*]u8 = undefined;
    var out_len: usize = undefined;

    const not_spirv = [_]u8{0} ** 20;
    try std.testing.expectEqual(@as(c_int, 1), zmolv_encode(not_spirv[0..], 20, &out_ptr, &out_len));

    const header: [5]u32 = .{ 0x07230203, 0, 0, 0, 0 };
    const header_bytes: [*]const u8 = std.mem.sliceAsBytes(&header).ptr;
    try std.testing.expectEqual(
        @as(c_int, 0),
        zmolv_encode(header_bytes, @sizeOf([5]u32), &out_ptr, &out_len),
    );
    try std.testing.expectEqual(@as(usize, 24), out_len);
    zmolv_free(out_ptr, out_len);
}
