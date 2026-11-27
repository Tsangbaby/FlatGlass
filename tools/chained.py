#!/usr/bin/env python3
"""Resolve chained-fixup GOT slots -> imported symbol names."""
import struct
import macho


def imports_table(sl):
    off, size = sl.chained
    hdr = sl.data[off:off + 28]
    ver, starts_off, imports_off, syms_off, cnt, ifmt, sfmt = struct.unpack('<7I', hdr)
    imports = []
    base = off
    for i in range(cnt):
        if ifmt == 1:      # DYLD_CHAINED_IMPORT
            v = struct.unpack('<I', sl.data[base + imports_off + i * 4: base + imports_off + i * 4 + 4])[0]
            name_off = v >> 9
            lib = (v >> 24) & 0x3F
            weak = (v >> 30) & 1
        elif ifmt == 2:    # DYLD_CHAINED_IMPORT_ADDEND
            v, add = struct.unpack('<Ii', sl.data[base + imports_off + i * 8: base + imports_off + i * 8 + 8])
            name_off = v >> 9
            lib = (v >> 24) & 0x3F
        else:
            v, add, name_off, lib = 0, 0, 0, 0
            name_off = 0
        p = base + syms_off + name_off
        e = sl.data.find(b'\x00', p)
        imports.append(sl.data[p:e].decode('utf-8', 'replace'))
    return imports, starts_off, base


def got_map(sl):
    imports, starts_off, base = imports_table(sl)
    # starts in image
    p = base + starts_off
    seg_count = struct.unpack('<I', sl.data[p:p + 4])[0]
    seg_offs = struct.unpack(f'<{seg_count}I', sl.data[p + 4:p + 4 + seg_count * 4])
    out = {}
    for si, so in enumerate(seg_offs):
        if so == 0:
            continue
        q = p + so
        size, page_size, fmt, seg_index, max_valid = struct.unpack('<IHHHH', sl.data[q:q + 12])
        page_count = (size - 12) // 2
        starts = struct.unpack(f'<{page_count}H', sl.data[q + 12:q + 12 + page_count * 2])
        segname, vmaddr, vmsize, fileoff, filesize = sl.segs[si][:5]
        for pi, st in enumerate(starts):
            if st == 0xFFFF:
                continue
            page = vmaddr + pi * page_size
            off_in = (st & 0x7FFF) * 4 if page_size == 0x4000 else (st & 0x7FFF) * 8
            chain = page + off_in
            while chain:
                fo = sl.vm_to_off(chain)
                if fo is None:
                    break
                val = struct.unpack('<Q', sl.data[fo:fo + 8])[0]
                is_bind = (val >> 63) & 1
                nxt = (val >> 51) & 0xFFF
                if is_bind:
                    ordinal = (val >> 32) & 0xFFFF
                    addend = (val >> 39) & 0xFF
                    if addend & 0x40:
                        addend -= 0x100
                    nm = imports[ordinal] if ordinal < len(imports) else f'?{ordinal}'
                    out[chain] = (nm, addend)
                chain = (chain + nxt * 4) if nxt else 0
    return out
