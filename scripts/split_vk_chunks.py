#!/usr/bin/env python3
"""
Split the generated mul_mm.comp.cpp (87MB, 541 SPIR-V table pairs) into
~9MB chunks at pair boundaries so each chunk compiles under a 2GB RAM limit.
Usage (run AFTER the Vulkan build generates the file, BEFORE compiling it):
    python3 scripts/split_vk_chunks.py <path-to-mul_mm.comp.cpp>
Outputs: native/vk_chunks/part_NN.cpp
The ggml-vulkan CMakeLists skip mul_mm.comp; native/CMakeLists.txt links
native/vk_chunks/*.o (compile each part with -O0, see build_vk_chunks.sh).
"""
import os
import sys

LIMIT = 9_000_000  # bytes per chunk


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    src = sys.argv[1]
    if not os.path.isfile(src):
        print(f"file not found: {src}")
        sys.exit(1)
    out_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                           "vk_chunks")
    os.makedirs(out_dir, exist_ok=True)

    with open(src, "r", encoding="utf-8") as f:
        lines = f.read().split("\n")

    pairs = sum(1 for l in lines if l.startswith("const uint64_t"))
    header = lines[0]  # #include "ggml-vulkan-shaders.hpp"

    chunks = []
    cur = []
    cur_size = 0
    for ln in lines[1:]:
        if ln.startswith("const uint64_t") and cur_size > LIMIT:
            chunks.append(cur)
            cur = []
            cur_size = 0
        cur.append(ln)
        cur_size += len(ln) + 1
    if cur:
        chunks.append(cur)

    print(f"pairs: {pairs} chunks: {len(chunks)}")
    for i, ch in enumerate(chunks, 1):
        with open(os.path.join(out_dir, f"part_{i:02d}.cpp"), "w", encoding="utf-8") as f:
            f.write(header + "\n")
            f.write("\n".join(ch))
    print(f"written to {out_dir}")


if __name__ == "__main__":
    main()
