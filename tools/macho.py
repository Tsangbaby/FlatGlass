#!/usr/bin/env python3
"""Minimal Mach-O (32/64, thin+fat) parser: segments, sections, symtab,
dyld bind info, ObjC metadata, Swift 5 metadata sections."""
import struct, sys, os

FAT_MAGICS = {0xcafebabe, 0xcafebabf, 0xbebafeca, 0xbfbafeca}
MH_MAGIC_64 = 0xfeedfacf
MH_MAGIC = 0xfeedface

LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_DYSYMTAB = 0xb
LC_LOAD_DYLIB = 0xc
LC_ID_DYLIB = 0xd
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001f
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022
LC_DYLD_CHAINED_FIXUPS = 0x80000034
LC_DYLD_EXPORTS_TRIE = 0x80000033
LC_ENCRYPTION_INFO_64 = 0x2c
LC_FUNCTION_STARTS = 0x26
LC_MAIN = 0x80000028


class Slice:
    def __init__(self, data, name="", cpu=0, subtype=0):
        self.data = data
        self.name = name
        self.cpu = cpu
        self.subtype = subtype
        self.segs = []       # (name, vmaddr, vmsize, fileoff, filesize, maxprot, initprot, nsects)
        self.sections = {}   # "SEG,sect" -> dict
        self.symtab = (0, 0, 0, 0)  # symoff, nsyms, stroff, strsize
        self.dylibs = []
        self.bind_info = None
        self.chained = None
        self.cryptid = 0
        self.function_starts = None
        self.entry = None
        self._parse()

    # ---------- helpers ----------
    def vm_to_off(self, addr):
        for s in self.segs:
            name, vmaddr, vmsize, fileoff, filesize = s[0], s[1], s[2], s[3], s[4]
            if vmaddr <= addr < vmaddr + vmsize and addr - vmaddr < filesize:
                return fileoff + (addr - vmaddr)
        return None

    def read_vm(self, addr, n):
        off = self.vm_to_off(addr)
        if off is None:
            return None
        return self.data[off:off + n]

    def u32(self, addr):
        b = self.read_vm(addr, 4)
        return struct.unpack('<I', b)[0] if b and len(b) == 4 else None

    def i32(self, addr):
        b = self.read_vm(addr, 4)
        return struct.unpack('<i', b)[0] if b and len(b) == 4 else None

    def u64(self, addr):
        b = self.read_vm(addr, 8)
        return struct.unpack('<Q', b)[0] if b and len(b) == 8 else None

    def cstr(self, addr, limit=4096):
        off = self.vm_to_off(addr)
        if off is None:
            return None
        end = self.data.find(b'\x00', off, off + limit)
        if end < 0:
            return None
        return self.data[off:end].decode('utf-8', 'replace')

    def sect(self, seg, name):
        return self.sections.get(f"{seg},{name}")

    # ---------- parsing ----------
    def _parse(self):
        d = self.data
        magic = struct.unpack('<I', d[:4])[0]
        assert magic == MH_MAGIC_64, f"not 64-bit macho: {hex(magic)}"
        self.header_size = 32
        cpu, subtype, ftype, ncmds, sizeofcmds, flags, res = struct.unpack('<iiIIIII', d[4:32])
        self.ftype = ftype
        self.flags = flags
        if not self.cpu:
            self.cpu = cpu
            self.subtype = subtype
        off = 32
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack('<II', d[off:off + 8])
            if cmd == LC_SEGMENT_64:
                segname = d[off + 8:off + 24].rstrip(b'\x00').decode()
                vmaddr, vmsize, fileoff, filesize, maxprot, initprot, nsects, fl = \
                    struct.unpack("<QQQQIIII", d[off + 24:off + 72])
                self.segs.append((segname, vmaddr, vmsize, fileoff, filesize, maxprot, initprot, nsects))
                so = off + 72
                for i in range(nsects):
                    sname = d[so:so + 16].rstrip(b'\x00').decode()
                    sseg = d[so + 16:so + 32].rstrip(b'\x00').decode()
                    addr, size, offset, align, reloff, nreloc, sflags = \
                        struct.unpack('<QQIIIII', d[so + 32:so + 68])
                    self.sections[f"{sseg},{sname}"] = dict(
                        seg=sseg, name=sname, addr=addr, size=size, offset=offset,
                        align=align, flags=sflags, nreloc=nreloc)
                    so += 80
            elif cmd == LC_SYMTAB:
                self.symtab = struct.unpack('<IIII', d[off + 8:off + 24])
            elif cmd in (LC_LOAD_DYLIB, LC_ID_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB):
                noff = struct.unpack('<I', d[off + 8:off + 12])[0]
                nm = d[off + noff:off + cmdsize].split(b'\x00')[0].decode('utf-8', 'replace')
                self.dylibs.append(('ID' if cmd == LC_ID_DYLIB else 'LOAD', nm))
            elif cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
                self.bind_info = struct.unpack('<10I', d[off + 8:off + 48])
            elif cmd == LC_DYLD_CHAINED_FIXUPS:
                doff, dsz = struct.unpack('<II', d[off + 8:off + 16])
                self.chained = (doff, dsz)
            elif cmd == LC_ENCRYPTION_INFO_64:
                self.cryptid = struct.unpack('<I', d[off + 16:off + 20])[0]
            elif cmd == LC_FUNCTION_STARTS:
                self.function_starts = struct.unpack('<II', d[off + 8:off + 16])
            elif cmd == LC_MAIN:
                self.entry = struct.unpack('<Q', d[off + 8:off + 16])[0]
            off += cmdsize
        self.symtab_dict = None

    def symbols(self):
        if self.symtab_dict is not None:
            return self.symtab_dict
        symoff, nsyms, stroff, strsize = self.symtab
        out = []
        for i in range(nsyms):
            e = self.data[symoff + i * 16: symoff + (i + 1) * 16]
            if len(e) < 16:
                break
            strx, ntype, nsect, ndesc, nvalue = struct.unpack('<IBBHQ', e)
            o = stroff + strx
            end = self.data.find(b'\x00', o)
            nm = self.data[o:end].decode('utf-8', 'replace') if end > 0 else ''
            out.append(dict(name=nm, type=ntype, sect=nsect, desc=ndesc, value=nvalue))
        self.symtab_dict = out
        return out

    # ---------- bind (imports) ----------
    def binds(self):
        """Parse LC_DYLD_INFO bind opcodes -> list of (segment, offset, symbol, dylib, addend)."""
        if not self.bind_info:
            return []
        bind_off, bind_size = self.bind_info[2], self.bind_info[3]
        blob = self.data[bind_off: bind_off + bind_size]
        segs = [s for s in self.segs if s[7] or True]
        threads = [s for s in self.segs]
        res = []
        p = 0
        segidx = 0
        seg_off = 0
        symbol = ''
        addend = 0
        lib_ord = 0
        sym_pfx = ''
        while p < len(blob):
            op = blob[p]
            imm = op & 0x0f
            if op == 0x00:
                p += 1
            elif op == 0x11:  # SET_DYLIB_ORDINAL_IMM
                lib_ord = blob[p] & 0x0f
                p += 1
            elif op == 0x10:  # SET_DYLIB_ORDINAL_ULEB
                val, p = uleb(blob, p + 1)
                lib_ord = val
            elif op == 0x20:  # SET_DYLIB_SPECIAL_IMM
                sign = imm
                lib_ord = sign if sign < 8 else sign - 16
                p += 1
            elif op == 0x40:  # SET_SYMBOL_TRAILING_FLAGS_IMM
                end = blob.find(b'\x00', p + 1)
                symbol = blob[p + 1:end].decode('utf-8', 'replace')
                p = end + 1
            elif op == 0x50:  # SET_TYPE_IMM
                p += 1
            elif op == 0x60:  # SET_ADDEND_SLEB
                val, p = sleb(blob, p + 1)
                addend = val
            elif op == 0x70:  # SET_SEGMENT_AND_OFFSET_ULEB
                segidx = imm
                val, p = uleb(blob, p + 1)
                seg_off = val
            elif op == 0x80:  # ADD_ADDR_ULEB
                val, p = uleb(blob, p + 1)
                seg_off = (seg_off + val) & 0xffffffffffffffff
            elif op == 0x90:  # DO_BIND
                res.append((threads[segidx][0], seg_off, symbol, lib_ord, addend))
                seg_off += 8
                p += 1
            elif op == 0x91:  # DO_BIND_ADD_ADDR_ULEB
                res.append((threads[segidx][0], seg_off, symbol, lib_ord, addend))
                val, p = uleb(blob, p + 1)
                seg_off = (seg_off + 8 + val) & 0xffffffffffffffff
            elif op == 0xa0:  # DO_BIND_ADD_ADDR_IMM_SCALED
                res.append((threads[segidx][0], seg_off, symbol, lib_ord, addend))
                seg_off = (seg_off + 8 + imm * 8) & 0xffffffffffffffff
                p += 1
            elif op == 0xb0:  # DO_BIND_ULEB_TIMES_SKIPPING_ULEB
                cnt, p = uleb(blob, p + 1)
                skip, p = uleb(blob, p)
                for _ in range(cnt):
                    res.append((threads[segidx][0], seg_off, symbol, lib_ord, addend))
                    seg_off = (seg_off + 8 + skip) & 0xffffffffffffffff
            else:
                p += 1
        return res


def uleb(b, p):
    res = 0
    shift = 0
    while True:
        byte = b[p]
        p += 1
        res |= (byte & 0x7f) << shift
        if not byte & 0x80:
            break
        shift += 7
    return res, p


def sleb(b, p):
    res = 0
    shift = 0
    byte = 0
    while True:
        byte = b[p]
        p += 1
        res |= (byte & 0x7f) << shift
        shift += 7
        if not byte & 0x80:
            if byte & 0x40:
                res |= -(1 << shift)
            break
    return res, p


def load(path):
    d = open(path, 'rb').read()
    if len(d) < 8:
        raise ValueError("too small")
    magic = struct.unpack('>I', d[:4])[0]
    slices = []
    if magic in FAT_MAGICS:
        n = struct.unpack('>I', d[4:8])[0]
        for i in range(n):
            base = 8 + i * 20
            cpu, sub, off, size, align = struct.unpack('>iIIII', d[base:base + 20])
            sl = d[off:off + size]
            name = {16777228: 'arm64', -1: 'any'}.get(cpu, f'cpu{cpu}')
            if cpu == 16777228 and (sub & 0xffffff) == 2:
                name = 'arm64e'
            slices.append(Slice(sl, name, cpu, sub))
    else:
        cpu, sub = struct.unpack('<ii', d[4:12])
        slices.append(Slice(d, 'thin', cpu, sub))
    return slices


def cxx_sections(sl):
    return {k: v for k, v in sl.sections.items()}
