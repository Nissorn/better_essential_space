#!/usr/bin/env python3
"""Filter a dex file's class_defs to classes matching given descriptor prefixes.

Keeps all data sections intact (orphaned data is legal in dex); only the
class_defs table is narrowed and the header checksums are recomputed.
"""
import hashlib
import struct
import sys
import zlib


def read_uleb128(data: bytes, off: int) -> tuple[int, int]:
    result = 0
    shift = 0
    while True:
        b = data[off]
        off += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            return result, off
        shift += 7


def get_string(data: bytes, string_ids_off: int, idx: int) -> str:
    off = struct.unpack_from('<I', data, string_ids_off + 4 * idx)[0]
    _, str_start = read_uleb128(data, off)
    end = data.index(b'\x00', str_start)
    return data[str_start:end].decode('utf-8', errors='replace')


def main() -> None:
    src, dst, *prefixes = sys.argv[1:]
    prefixes = tuple(prefixes)
    data = bytearray(open(src, 'rb').read())

    class_defs_size = struct.unpack_from('<I', data, 96)[0]
    class_defs_off = struct.unpack_from('<I', data, 100)[0]
    string_ids_off = struct.unpack_from('<I', data, 60)[0]
    type_ids_off = struct.unpack_from('<I', data, 68)[0]

    entry = 32  # sizeof class_def_item
    kept = []
    for i in range(class_defs_size):
        base = class_defs_off + i * entry
        class_idx = struct.unpack_from('<I', data, base)[0]
        descriptor_idx = struct.unpack_from('<I', data, type_ids_off + 4 * class_idx)[0]
        descriptor = get_string(data, string_ids_off, descriptor_idx)
        if descriptor.startswith(prefixes):
            kept.append(data[base:base + entry])

    print(f'class_defs: {class_defs_size} -> {len(kept)}')
    # Rewrite the class_defs table IN PLACE: file size and every other offset
    # (map_list, class_data_off, ...) stay valid. Slots beyond the new size are
    # stale bytes no reader will touch.
    for i, entry_bytes in enumerate(kept):
        base = class_defs_off + i * entry
        data[base:base + entry] = entry_bytes
    struct.pack_into('<I', data, 96, len(kept))
    # ART requires zero padding between sections: blank the stale entries left
    # behind by the narrowed table.
    stale_start = class_defs_off + len(kept) * entry
    stale_end = class_defs_off + class_defs_size * entry
    data[stale_start:stale_end] = b'\x00' * (stale_end - stale_start)
    # Patch the map_list TYPE_CLASS_DEF_ITEM entry so ART's consistency check
    # (map size vs header size) passes.
    map_off = struct.unpack_from('<I', data, 52)[0]
    map_size = struct.unpack_from('<I', data, map_off)[0]
    for i in range(map_size):
        base = map_off + 4 + i * 12
        mtype = struct.unpack_from('<H', data, base)[0]
        if mtype == 0x0006:  # TYPE_CLASS_DEF_ITEM
            struct.pack_into('<I', data, base + 4, len(kept))
            break
    # Signature (SHA-1 over everything from file_size field onward) then checksum.
    body = bytes(data[32:])
    data[12:32] = hashlib.sha1(body).digest()
    struct.pack_into('<I', data, 8, zlib.adler32(bytes(data[12:])) & 0xFFFFFFFF)
    open(dst, 'wb').write(bytes(data))
    print(f'wrote {dst} ({len(data)} bytes)')


if __name__ == '__main__':
    main()
