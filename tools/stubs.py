import struct, macho
from macho import uleb


def imports(sl):
    off, size = sl.chained
    ver, starts_off, imports_off, syms_off, cnt, ifmt, sfmt = struct.unpack('<7I', sl.data[off:off + 28])
    out = []
    for i in range(cnt):
        unit = 4 if ifmt == 1 else 8
        v = struct.unpack('<I', sl.data[off+imports_off+i*unit: off+imports_off+i*unit+4])[0]
        no = v >> 9
        p = off + syms_off + no
        e = sl.data.find(b'\x00', p)
        out.append(sl.data[p:e].decode('utf-8', 'replace'))
    return out


def _adrp(insn, addr):
    immlo = (insn >> 29) & 3
    immhi = (insn >> 5) & 0x7FFFF
    imm = (immhi << 2) | immlo
    if imm & (1 << 20):
        imm -= 1 << 21
    return (addr & ~0xFFF) + (imm << 12)


def stub_names(sl):
    imp = imports(sl)
    res = {}
    for secname in ('__stubs',):
        s = sl.sect('__TEXT', secname)
        if not s:
            continue
        for i in range(s['size'] // 12):
            a = s['addr'] + i * 12
            fo = sl.vm_to_off(a)
            adrp = struct.unpack('<I', sl.data[fo:fo+4])[0]
            ldr = struct.unpack('<I', sl.data[fo+4:fo+8])[0]
            page = _adrp(adrp, a)
            disp = ((ldr >> 10) & 0xFFF) * 8
            got = page + disp
            gfo = sl.vm_to_off(got)
            if gfo is None:
                continue
            v = struct.unpack('<Q', sl.data[gfo:gfo+8])[0]
            if (v >> 62) == 2:
                ordn = v & 0xFFFFFF
            elif v >> 63:
                ordn = (v >> 32) & 0xFFFF
            else:
                continue
            if ordn < len(imp):
                res[a] = imp[ordn]
    return res
