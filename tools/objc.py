import struct, macho

def _parse_class(sl, cls_addr, out):
    d = sl.data
    ro_ptr = sl.u64(cls_addr + 32) or 0
    ro = ro_ptr & 0xffffffffff
    if ro >= 0x100000000: ro -= 0x100000000
    if not ro: return None
    flags = sl.u32(ro)
    instStart = sl.u32(ro + 4)
    instSize = sl.u32(ro + 8)
    name_ptr = sl.u64(ro + 24) & 0xffffffffff
    name = sl.cstr(name_ptr)
    mlist = sl.u64(ro + 32) & 0xffffffffff
    ivars = sl.u64(ro + 48) & 0xffffffffff
    iv = []
    if ivars:
        entsize = 0
        cnt = sl.u32(ivars + 4)
        # ivar_list_t: uint32 entsize/flags, uint32 count
        entsize = sl.u32(ivars) & 0xffff
        if entsize == 0: entsize = 32
        p = ivars + 8
        for i in range(cnt or 0):
            off_ptr = sl.u64(p)
            iv_name_ptr = sl.u64(p + 8) & 0xffffffffff
            type_ptr = sl.u64(p + 16) & 0xffffffffff
            align = sl.u32(p + 24)
            size = sl.u32(p + 28)
            iv.append((sl.cstr(iv_name_ptr), sl.cstr(type_ptr), hex(off_ptr or 0), size))
            p += entsize
    methods = []
    if mlist:
        flags2 = sl.u32(mlist)
        cnt2 = sl.u32(mlist + 4)
        p = mlist + 8
        entsize2 = flags2 & 0xfffc
        relative = bool(flags2 & 0x80000000)
        for i in range(cnt2 or 0):
            if relative:
                off = sl.i32(p)
                sel = (p + (off >> 0)) & 0xffffffff
                namep = sl.u64(p + 4) & 0xffffffffff
                selp = p + (sl.i32(p) >> 0)
                methods.append(sl.cstr(selp))
                p += 12
            else:
                selp = sl.u64(p) & 0xffffffffff
                methods.append(sl.cstr(selp))
                p += entsize2 or 24
    out.append(dict(name=name, super=hex(sl.u64(cls_addr + 8) or 0), instSize=instSize, instStart=instStart, ivars=iv, methods=methods))

def classes(sl):
    out = []
    s = sl.sect('__DATA_CONST', '__objc_classlist') or sl.sect('__DATA', '__objc_classlist')
    if not s: return out
    for i in range(s['size'] // 8):
        p = sl.u64(s['addr'] + i * 8)
        if not p: continue
        _parse_class(sl, p & 0xffffffffff, out)
    return out
