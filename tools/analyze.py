#!/usr/bin/env python3
"""Disassemble a Mach-O slice with ObjC selector / C-string / symbol annotation."""
import sys, struct
sys.path.insert(0, '/var/deepbot/sessions/5806710535/ws/tools')
import macho
from stubs import stub_names
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
from capstone.arm64 import ARM64_OP_REG, ARM64_OP_IMM, ARM64_OP_MEM

mask = lambda p: p & 0xffffffffff


class Annotator:
    def __init__(self, sl):
        self.sl = sl
        self.selrefs = {}
        s = sl.sect('__DATA', '__objc_selrefs')
        if s:
            for off in range(0, s['size'], 8):
                a = s['addr'] + off
                p = sl.u64(a)
                if p:
                    nm = sl.cstr(mask(p))
                    if nm:
                        self.selrefs[a] = nm
        self.str_by_addr = {}
        for sec in ('__cstring',):
            for seg in ('__TEXT',):
                s = sl.sect(seg, sec)
                if s:
                    blob = sl.data[s['offset']:s['offset'] + s['size']]
                    pos = 0
                    for part in blob.split(b'\x00'):
                        if part:
                            self.str_by_addr[s['addr'] + pos] = part.decode('utf-8', 'replace')
                        pos += len(part) + 1
        self.cfmap = {}
        for seg in ('__DATA_CONST', '__DATA', '__TEXT'):
            s = sl.sect(seg, '__cfstring')
            if not s:
                continue
            for i in range(s['size'] // 32):
                a = s['addr'] + i * 32
                ptr = sl.u64(a + 16)
                if ptr is None:
                    continue
                t = mask(ptr)
                if t >= 0x100000000:
                    t -= 0x100000000
                ln = sl.u64(a + 24) & 0xffff
                txt = sl.read_vm(t, ln)
                if txt:
                    self.cfmap[a] = txt.decode('utf-8', 'replace')
        self.sym = {}
        for s in sl.symbols():
            if s['value']:
                self.sym[s['value']] = s['name']
        try:
            self.sym.update(stub_names(sl))
        except Exception:
            pass
        self.funcs = sorted([(s['value'], s['name']) for s in sl.symbols()
                             if s['value'] and s['name'] and not s['name'].startswith('_OBJC_')], key=lambda x: x[0])

    def func_end(self, start):
        txt = self.sl.sect('__TEXT', '__text')
        end = txt['addr'] + txt['size']
        for v, n in self.funcs:
            if v > start:
                return min(v, end)
        return end

    def listing(self, start, name=None):
        sl = self.sl
        off = sl.vm_to_off(start)
        end = self.func_end(start)
        code = sl.data[off:off + (end - start)]
        md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
        md.detail = True
        reg = {}   # reg -> (kind, value)
        out = []
        if name:
            out.append(f"\n/* {name}  @ {start:#x} */")
            out.append(f"{name}:")
        for ins in md.disasm(code, start):
            note = ''
            m = ins.mnemonic
            ops = ins.operands
            # adrp
            if m == 'adrp' and len(ops) == 2 and ops[0].type == ARM64_OP_REG:
                r = ins.reg_name(ops[0].reg)
                reg[r] = ('page', ops[1].imm)
            elif m == 'add' and len(ops) == 3 and ops[1].type == ARM64_OP_REG and ops[2].type == ARM64_OP_IMM:
                r1 = ins.reg_name(ops[1].reg)
                if r1 in reg and reg[r1][0] == 'page':
                    t = reg[r1][1] + ops[2].imm
                    reg[ins.reg_name(ops[0].reg)] = ('addr', t)
                    note = self.describe_target(t)
                else:
                    reg[ins.reg_name(ops[0].reg)] = ('other', 0)
            elif m == 'ldr' and len(ops) == 2 and ops[1].type == ARM64_OP_MEM:
                base = ins.reg_name(ops[1].mem.base)
                dis = ops[1].mem.disp
                if base in reg and reg[base][0] in ('page', 'addr'):
                    tgt = reg[base][1] + dis
                    if reg[base][0] == 'page':
                        tgt = reg[base][1] + dis
                    note = self.describe_target(tgt)
                    reg[ins.reg_name(ops[0].reg)] = ('loaded', tgt)
            elif m == 'bl':
                tgt = ops[0].imm
                note = self.sym.get(tgt, '')
                if tgt in self.sym:
                    note = '-> ' + self.sym[tgt]
            elif m in ('b',) and len(ops) == 1 and ops[0].type == ARM64_OP_IMM:
                tgt = ops[0].imm
                if tgt in self.sym:
                    note = '-> ' + self.sym[tgt]
            elif m == 'adr':
                note = self.describe_target(ops[1].imm)
            line = f"  {ins.address:08x}  {ins.bytes.hex():<8} {m:<8} {ins.op_str}"
            if note:
                line = f"{line:<64} ; {note}"
            out.append(line)
        return '\n'.join(out)

    def describe_target(self, a):
        if a in self.selrefs:
            return f'sel "{self.selrefs[a]}"'
        if a in self.str_by_addr:
            return f'str "{self.str_by_addr[a]}"'
        if a in self.cfmap:
            return f'CFString "{self.cfmap[a]}"'
        if a in self.sym:
            return f'&{self.sym[a]}'
        return ''


if __name__ == '__main__':
    path = sys.argv[1]
    names = sys.argv[2:] if len(sys.argv) > 2 else None
    for sl in macho.load(path):
        if sl.name.startswith('arm64e'):
            continue
        an = Annotator(sl)
        if not names:
            for v, n in an.funcs:
                print(an.listing(v, n))
        else:
            for want in names:
                for v, n in an.funcs:
                    if n == want or n.lstrip('_') == want.lstrip('_'):
                        print(an.listing(v, n))
