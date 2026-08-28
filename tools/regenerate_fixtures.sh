#!/usr/bin/env bash
# Rebuild src/testdata/*.smolv from the upstream C++ encoder.
#
# The fixtures are what this port is checked against, so they must come from
# the reference implementation rather than from this one - regenerating them
# with our own encoder would make the test assert that we agree with ourselves.
set -euo pipefail

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

for f in smolv.cpp smolv.h; do
    curl -sSfL "https://raw.githubusercontent.com/aras-p/smol-v/main/source/$f" -o "$work/$f"
done

cat > "$work/oracle.cpp" <<'CPP'
#include "smolv.h"
#include <cstdio>
#include <vector>
int main(int argc, char** argv) {
    if (argc != 3) return 2;
    FILE* f = fopen(argv[1], "rb");
    if (!f) return 2;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    std::vector<unsigned char> in(n);
    if (fread(in.data(), 1, n, f) != (size_t)n) return 3;
    fclose(f);
    smolv::ByteArray out;
    if (!smolv::Encode(in.data(), in.size(), out, 0)) return 1;
    FILE* g = fopen(argv[2], "wb");
    fwrite(out.data(), 1, out.size(), g);
    fclose(g);
    printf("%s: spirv=%zu smolv=%zu\n", argv[1], in.size(), out.size());
    return 0;
}
CPP

# zig doubles as the C++ toolchain, so this needs nothing a Zig project lacks.
zig c++ -O2 -o "$work/oracle" "$work/oracle.cpp" "$work/smolv.cpp"

for spv in src/testdata/*.spv; do
    "$work/oracle" "$spv" "${spv%.spv}.smolv"
done

python3 tools/generate_table.py "$work/smolv.cpp"
