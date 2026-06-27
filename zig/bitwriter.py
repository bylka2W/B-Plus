"""LLVM 13 bitstream encoder — direct record-level construction."""

import struct
import subprocess as _sp
from dataclasses import dataclass, field
from typing import Any

# ── CFG IR Model Layer ──────────────────────────────────────────────

@dataclass
class Block:
    """A basic block with non-terminator instructions, a terminator, and explicit successor edges.

    term format:
      ('ret', None)          → void return
      ('ret', val_ref)       → return value (val_ref = value table index)
      ('br', target_bb_idx)  → unconditional branch
      ('unreachable',)       → unreachable
    """
    label: str
    body: list[dict] = field(default_factory=list)
    term: tuple | None = None

    @property
    def successors(self) -> list[int]:
        if self.term is None:
            return []
        kind = self.term[0]
        if kind == 'ret':
            return []
        if kind == 'br':
            return [self.term[1]]
        if kind == 'unreachable':
            return []
        raise ValueError(f'unknown terminator kind: {kind}')

    def add(self, inst: dict):
        self.body.append(inst)

    def is_terminated(self) -> bool:
        return self.term is not None


@dataclass
class CFGFunction:
    """A function model with explicit control-flow graph.

    blocks is an ordered list; the index of each block is its BB id.
    entry_idx specifies which block is the entry block (default 0).
    value_idx is set by ModuleBuilder during emission (reserved slot in LLVM ValueList).
    """
    name: str
    type_idx: int
    blocks: list[Block] = field(default_factory=list)
    entry_idx: int = 0
    local_consts: list[int] = field(default_factory=list)
    attrs: int = 0
    calling_conv: int = 0
    value_idx: int = -1

    def new_block(self, label: str) -> Block:
        b = Block(label=label)
        self.blocks.append(b)
        return b


LLVM_DIS = r'C:\Program Files\dotnet\packs\Microsoft.NET.Runtime.Emscripten.2.0.23.Sdk.win-x64\6.0.36\tools\bin\llvm-dis.exe'

# ── Block IDs ───────────────────────────────────────────────────────
BLOCKINFO_BLOCK_ID       = 0
MODULE_BLOCK_ID          = 8
CONSTANTS_BLOCK_ID       = 11
FUNCTION_BLOCK_ID        = 12
IDENTIFICATION_BLOCK_ID  = 13
TYPE_BLOCK_ID_NEW        = 17
STRTAB_BLOCK_ID          = 23
MODULE_STRTAB_BLOCK_ID   = 19
METADATA_BLOCK_ID        = 15
METADATA_KIND_BLOCK_ID   = 20

# ── Module codes ────────────────────────────────────────────────────
MODULE_CODE_VERSION         = 1
MODULE_CODE_TRIPLE          = 2
MODULE_CODE_DATALAYOUT      = 3
MODULE_CODE_SOURCE_FILENAME = 16
MODULE_CODE_FUNCTION        = 8
MODULE_CODE_GLOBALVAR       = 7

# ── Type codes (Emscripten LLVM 13 fork) ────────────────────────────
TYPE_CODE_NUMENTRY    = 1
TYPE_CODE_VOID        = 2
TYPE_CODE_FLOAT       = 3
TYPE_CODE_DOUBLE      = 4
TYPE_CODE_LABEL       = 5
TYPE_CODE_INTEGER     = 7
TYPE_CODE_POINTER     = 8
TYPE_CODE_HALF        = 10
TYPE_CODE_ARRAY       = 11
TYPE_CODE_VECTOR      = 12
TYPE_CODE_FUNCTION    = 21
TYPE_CODE_OPAQUE      = 20
TYPE_CODE_STRUCT_ANON = 18
TYPE_CODE_STRUCT_NAME = 19
TYPE_CODE_STRUCT_NAMED = 20
TYPE_CODE_OPAQUE_POINTER = 25

# ── Constants codes ─────────────────────────────────────────────────
CST_CODE_SETTYPE     = 1
CST_CODE_NULL        = 2
CST_CODE_UNDEF       = 3
CST_CODE_INTEGER     = 4
CST_CODE_FLOAT       = 6
CST_CODE_AGGREGATE   = 7
CST_CODE_STRING      = 8
CST_CODE_CSTRING     = 9

# ── Function codes ──────────────────────────────────────────────────
FUNC_CODE_DECLAREBLOCKS  = 1
FUNC_CODE_INST_BINOP     = 2
FUNC_CODE_INST_CAST      = 3
FUNC_CODE_INST_RET       = 10
FUNC_CODE_INST_BR        = 11
FUNC_CODE_INST_PHI       = 16
FUNC_CODE_INST_ALLOCA    = 19
FUNC_CODE_INST_LOAD      = 20
FUNC_CODE_INST_VSELECT   = 29
FUNC_CODE_INST_CALL      = 34
FUNC_CODE_INST_GEP       = 43
FUNC_CODE_INST_STORE     = 44
FUNC_CODE_INST_UNOP      = 56
FUNC_CODE_INST_UNREACHABLE = 15
FUNC_CODE_INST_CMP2      = 28
FUNC_CODE_INST_EXTRACTELT = 6
FUNC_CODE_INST_INSERTELT = 7
FUNC_CODE_INST_SHUFFLEVEC = 8
FUNC_CODE_INST_EXTRACTVAL = 26
FUNC_CODE_INST_INSERTVAL = 27

# ── Cast opcodes ────────────────────────────────────────────────────
CAST_TRUNC=0; CAST_ZEXT=1; CAST_SEXT=2; CAST_FPTOUI=3; CAST_FPTOSI=4
CAST_UITOFP=5; CAST_SITOFP=6; CAST_FPTRUNC=7; CAST_FPEXT=8
CAST_PTRTOINT=9; CAST_INTTOPTR=10; CAST_BITCAST=11; CAST_ADDRSPACECAST=12

# ── Binary opcodes ──────────────────────────────────────────────────
BINOP_ADD=0; BINOP_SUB=1; BINOP_MUL=2; BINOP_UDIV=3; BINOP_SDIV=4
BINOP_UREM=5; BINOP_SREM=6; BINOP_SHL=7; BINOP_LSHR=8; BINOP_ASHR=9
BINOP_AND=10; BINOP_OR=11; BINOP_XOR=12

UNOP_FNEG = 0

# ── BLOCKINFO ───────────────────────────────────────────────────────
BLOCKINFO_SETBID = 1

# ── Wire encoding ───────────────────────────────────────────────────
ENC_FIXED=1; ENC_VBR=2; ENC_ARRAY=3; ENC_CHAR6=4; ENC_BLOB=5

# ── Helpers ─────────────────────────────────────────────────────────
def _encode_align(a):
    if a <= 1:
        return 0
    return a.bit_length()  # log2 + 1

def _get_cast(op):
    return {'trunc':0,'zext':1,'sext':2,'fptoui':3,'fptosi':4,'uitofp':5,
            'sitofp':6,'fptrunc':7,'fpext':8,'ptrtoint':9,'inttoptr':10,
            'bitcast':11,'addrspacecast':12}[op]

def _get_binop(op):
    return {'add':0,'sub':1,'mul':2,'udiv':3,'sdiv':4,'urem':5,'srem':6,
            'shl':7,'lshr':8,'ashr':9,'and':10,'or':11,'xor':12}[op]

def _get_icmp(p):
    return {'eq':32,'ne':33,'ugt':34,'uge':35,'ult':36,'ule':37,
            'sgt':38,'sge':39,'slt':40,'sle':41}[p]

def _get_fcmp(p):
    return {'false':0,'oeq':1,'ogt':2,'oge':3,'olt':4,'ole':5,
            'one':6,'ord':7,'uno':8,'ueq':9,'ugt':10,'uge':11,
            'ult':12,'ule':13,'une':14,'true':15}[p]


# ── String Table ────────────────────────────────────────────────────
class StringTableBuilder:
    def __init__(self):
        self._entries = []
    def add_value(self, value_id, name):
        if not name:
            return
        if isinstance(name, str):
            name = name.encode()
        self._entries.append((value_id, name))
    def get_entries(self):
        return list(self._entries)


# ── Bitstream Writer ────────────────────────────────────────────────
class BitWriter:
    def __init__(self):
        self.Out = bytearray()
        self.CurValue = 0
        self.CurBit = 0
        self.CurCodeSize = 2
        self.BlockScopes = []
        self._n_abbrevs = 0

    def flush(self):
        if self.CurBit:
            self.Out.extend(struct.pack('<I', self.CurValue))
            self.CurBit = 0
            self.CurValue = 0

    def w(self, v, n):
        if n <= 0:
            return
        if self.CurBit + n < 32:
            self.CurValue |= v << self.CurBit
            self.CurBit += n
            return
        ob = self.CurBit + n - 32
        self.CurValue |= v << self.CurBit
        if ob > 0:
            self.Out.extend(struct.pack('<I', self.CurValue & 0xFFFFFFFF))
            self.CurValue = (v >> (n - ob)) & 0xFFFFFFFF
            self.CurBit = ob
        else:
            self.Out.extend(struct.pack('<I', self.CurValue & 0xFFFFFFFF))
            self.CurValue = 0
            self.CurBit = 0

    def vbr(self, v, n):
        thresh = 1 << (n - 1)
        while v >= thresh:
            self.w((v & (thresh - 1)) | thresh, n)
            v >>= n - 1
        self.w(v, n)

    def code(self, c):
        self.w(c, self.CurCodeSize)

    def word_idx(self):
        return len(self.Out) // 4

    def enter(self, bid, cl):
        self.code(1)
        self.vbr(bid, 8)
        self.vbr(cl, 4)
        self.flush()
        si = self.word_idx()
        self.w(0, 32)
        self.BlockScopes.append((self.CurCodeSize, si))
        self.CurCodeSize = cl

    def exit(self):
        pcs, si = self.BlockScopes.pop()
        self.code(0)
        self.flush()
        struct.pack_into('<I', self.Out, si * 4, self.word_idx() - si - 1)
        self.CurCodeSize = pcs

    def unabbrev(self, rc, vals):
        self.code(3)
        self.vbr(rc, 6)
        self.vbr(len(vals), 6)
        for v in vals:
            self.vbr(v, 6)

    def def_abbrev(self, ops):
        n = len(ops)
        self.code(2)
        self.vbr(n, 5)
        for op in ops:
            if op[0] == 'lit':
                self.w(1, 1); self.vbr(op[1], 8)
            elif op[0] == 'fixed':
                self.w(0, 1); self.w(ENC_FIXED, 3); self.vbr(op[1], 5)
            elif op[0] == 'vbr':
                self.w(0, 1); self.w(ENC_VBR, 3); self.vbr(op[1], 5)
            elif op[0] == 'array':
                self.w(0, 1); self.w(ENC_ARRAY, 3)
                if len(op) > 1:
                    el = op[1]
                    if el[0] == 'char6':
                        self.w(0, 1); self.w(ENC_CHAR6, 3)
                    elif el[0] == 'fixed':
                        self.w(0, 1); self.w(ENC_FIXED, 3); self.vbr(el[1], 5)
                    elif el[0] == 'vbr':
                        self.w(0, 1); self.w(ENC_VBR, 3); self.vbr(el[1], 5)
            elif op[0] == 'char6':
                self.w(0, 1); self.w(ENC_CHAR6, 3)
            elif op[0] == 'blob':
                self.w(0, 1); self.w(ENC_BLOB, 3)
        idx = self._n_abbrevs
        self._n_abbrevs += 1
        return idx

    def magic(self):
        self.w(ord('B'), 8); self.w(ord('C'), 8)
        self.w(0x0, 4); self.w(0xC, 4); self.w(0xE, 4); self.w(0xD, 4)

    def char6(self, c):
        tbl = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._"
        self.w(tbl.index(chr(c)) if chr(c) in tbl else 0, 6)

    def blob(self, data):
        self.vbr(len(data), 6)
        # Align to byte boundary
        if self.CurBit % 8:
            self.w(0, 8 - self.CurBit % 8)
        # Write complete bytes from current word
        while self.CurBit >= 8:
            self.Out.append(self.CurValue & 0xFF)
            self.CurValue >>= 8
            self.CurBit -= 8
        self.Out.extend(data)
        # Pad to 4-byte alignment
        while len(self.Out) % 4:
            self.Out.append(0)

    def finish(self):
        self.flush()
        return bytes(self.Out)


# ── Module Builder ───────────────────────────────────────────────────
class ModuleBuilder:
    """Builds an LLVM bitcode module with explicit value/type numbering."""

    def __init__(self, triple='dxil-ms-dx', source='test.ll'):
        self.B = BitWriter()
        self._strtab = StringTableBuilder()
        self.triple = triple
        self.source = source

        # Type table
        self._types = []  # [{'kind':..., 'args':...}]
        self._type_map = {}  # key -> index

        # Value table
        self._values = []  # [{'name':..., 'type_idx':..., ...}]
        self._const_values = []  # global/function constants

        # Globals
        self._globals = []

        # Functions
        self._functions = []  # deferred for later

        # Metadata
        self._named_md = []
        self._md_kinds = []

    # ── Type management ─────────────────────────────────────────────
    def _type_key(self, kind, **kw):
        return (kind,) + tuple(kw.items())

    def _ensure_type(self, kind, **kw):
        key = self._type_key(kind, **kw)
        if key in self._type_map:
            return self._type_map[key]
        idx = len(self._types)
        self._types.append({'kind': kind, 'args': kw})
        self._type_map[key] = idx
        return idx

    def t_void(self):
        return self._ensure_type('void')
    def t_int(self, bits):
        return self._ensure_type('int', bits=bits)
    def t_float(self):
        return self._ensure_type('float')
    def t_double(self):
        return self._ensure_type('double')
    def t_ptr(self, pointee, addrspace=0):
        return self._ensure_type('ptr', pointee=pointee, addrspace=addrspace)
    def t_vec(self, elt, count):
        return self._ensure_type('vec', elt=elt, count=count)
    def t_arr(self, elt, count):
        return self._ensure_type('arr', elt=elt, count=count)
    def t_func(self, ret, params, vararg=False):
        return self._ensure_type('func', ret=ret, params=tuple(params), vararg=vararg)
    def t_label(self):
        return self._ensure_type('label')
    def t_metadata(self):
        return self._ensure_type('metadata')

    # ── Value management ────────────────────────────────────────────
    def add_value(self, name='', type_idx=0, is_const=False, const_kind=None, const_val=None):
        """Add a value and return its slot index."""
        idx = len(self._values)
        self._values.append({
            'name': name, 'type_idx': type_idx,
            'is_const': is_const, 'const_kind': const_kind, 'const_val': const_val,
        })
        return idx

    def add_constant_int(self, type_idx, val):
        return self.add_value('', type_idx, is_const=True, const_kind='int', const_val=val)

    def add_constant_float(self, type_idx, val):
        return self.add_value('', type_idx, is_const=True, const_kind='float', const_val=val)

    def add_constant_null(self, type_idx):
        return self.add_value('', type_idx, is_const=True, const_kind='null')

    def add_constant_undef(self, type_idx):
        return self.add_value('', type_idx, is_const=True, const_kind='undef')

    def add_constant_aggregate(self, type_idx, elt_value_indices):
        idx = self.add_value('', type_idx, is_const=True, const_kind='aggregate')
        self._values[idx]['aggregate_elts'] = elt_value_indices
        return idx

    def add_global(self, name, type_idx, is_constant=False, init_val_idx=0, linkage=0, align=0):
        idx = self.add_value(name, type_idx)
        self._globals.append({
            'name': name, 'type_idx': type_idx,
            'constant': is_constant, 'init': init_val_idx,
            'linkage': linkage, 'align': align,
            'value_idx': idx,
        })
        return idx

    def add_function(self, cfg: CFGFunction):
        idx = self.add_value(cfg.name, cfg.type_idx)
        cfg.value_idx = idx
        self._functions.append(cfg)
        return cfg

    # ── Write Type Table ────────────────────────────────────────────
    def _write_type_table(self):
        if not self._types:
            return
        self.B.enter(TYPE_BLOCK_ID_NEW, 4)
        self.B.unabbrev(TYPE_CODE_NUMENTRY, [len(self._types)])
        for t in self._types:
            k, a = t['kind'], t['args']
            if k == 'void':
                self.B.unabbrev(TYPE_CODE_VOID, [])
            elif k == 'int':
                self.B.unabbrev(TYPE_CODE_INTEGER, [a['bits']])
            elif k == 'float':
                self.B.unabbrev(TYPE_CODE_FLOAT, [])
            elif k == 'double':
                self.B.unabbrev(TYPE_CODE_DOUBLE, [])
            elif k == 'half':
                self.B.unabbrev(TYPE_CODE_HALF, [])
            elif k == 'label':
                self.B.unabbrev(TYPE_CODE_LABEL, [])
            elif k == 'metadata':
                self.B.unabbrev(TYPE_CODE_METADATA, [])
            elif k == 'ptr':
                self.B.unabbrev(TYPE_CODE_OPAQUE_POINTER, [a.get('addrspace', 0)])
            elif k == 'vec':
                self.B.unabbrev(TYPE_CODE_VECTOR, [a['count'], a['elt']])
            elif k == 'arr':
                self.B.unabbrev(TYPE_CODE_ARRAY, [a['count'], a['elt']])
            elif k == 'func':
                vals = [1 if a.get('vararg') else 0, a['ret']]
                vals.extend(a['params'])
                self.B.unabbrev(TYPE_CODE_FUNCTION, vals)
            else:
                self.B.unabbrev(TYPE_CODE_VOID, [])
        self.B.exit()

    # ── Write Constants Block ───────────────────────────────────────
    def _write_constants_block(self, consts):
        if not consts:
            return
        self.B.enter(CONSTANTS_BLOCK_ID, 4)
        last_ty = None
        for vi in consts:
            v = self._values[vi]
            if v['type_idx'] != last_ty:
                last_ty = v['type_idx']
                self.B.unabbrev(CST_CODE_SETTYPE, [v['type_idx']])
            ck = v.get('const_kind')
            if ck == 'int':
                raw = v['const_val']
                if raw >= 0:
                    raw = raw << 1
                else:
                    raw = ((-raw) << 1) | 1
                self.B.unabbrev(CST_CODE_INTEGER, [raw & 0xFFFFFFFFFFFFFFFF])
            elif ck == 'float':
                self.B.unabbrev(CST_CODE_FLOAT, [v['const_val']])
            elif ck == 'null':
                self.B.unabbrev(CST_CODE_NULL, [])
            elif ck == 'undef':
                self.B.unabbrev(CST_CODE_UNDEF, [])
            elif ck == 'aggregate':
                self.B.unabbrev(CST_CODE_AGGREGATE, v.get('aggregate_elts', []))
            else:
                self.B.unabbrev(CST_CODE_NULL, [])
        self.B.exit()

    # ── Write Function (consumes CFGFunction) ──────────────────────
    @staticmethod
    def _term_to_inst(term):
        """Convert a Block.term tuple into an instruction dict for _write_inst."""
        if term is None:
            return None
        kind = term[0]
        if kind == 'ret':
            val = term[1]
            if val is None:
                return {'op': 'retvoid'}
            return {'op': 'retval', 'val_idx': val}
        if kind == 'br':
            return {'op': 'br_uncond', 'dest_bb': term[1]}
        if kind == 'unreachable':
            return {'op': 'unreachable'}
        raise ValueError(f'unknown terminator: {term}')

    def _write_function(self, cfg: CFGFunction):
        self.B.enter(FUNCTION_BLOCK_ID, 4)

        self.B.unabbrev(FUNC_CODE_DECLAREBLOCKS, [len(cfg.blocks)])

        # Write function-local constants
        if cfg.local_consts:
            self._write_constants_block(cfg.local_consts)

        # Track NextValueNo: starts after module-level values + function-local constants
        next_value_id = self._module_value_count + len(cfg.local_consts)

        _VOID_OPS = frozenset(['retvoid', 'retval', 'store',
                               'br_uncond', 'br_cond', 'unreachable'])

        for bb in cfg.blocks:
            # Non-terminator instructions
            for inst in bb.body:
                self._write_inst(inst, next_value_id)
                if inst['op'] not in _VOID_OPS:
                    next_value_id += 1

            # Terminator
            term_inst = self._term_to_inst(bb.term)
            if term_inst is not None:
                self._write_inst(term_inst, next_value_id)
                # Terminators are void — no value slot consumed

        self.B.exit()

    def _rel_val(self, py_idx, next_value_id):
        """Convert Python value index to relative stored value for getValueTypePair.
        If py_idx is a known _values entry, use its mapped LLVM ID.
        Otherwise treat py_idx as the absolute LLVM value ID directly.
        stored = next_value_id - abs_llvm_id
        """
        abs_llvm = self._llvm_id_map.get(py_idx, py_idx)
        return next_value_id - abs_llvm

    def _abs_val(self, py_idx):
        """Convert Python value index to absolute stored value for getFnValueByID."""
        return self._llvm_id_map.get(py_idx, py_idx)

    def _write_inst(self, inst, next_value_id):
        op = inst['op']
        vals = []

        if op == 'retvoid':
            self.B.unabbrev(FUNC_CODE_INST_RET, [])
        elif op == 'retval':
            # retval: [rel_val]  (backward ref, no type)
            vals.append(self._rel_val(inst['val_idx'], next_value_id))
            self.B.unabbrev(FUNC_CODE_INST_RET, vals)
        elif op == 'alloca':
            # alloca: [allocated_type_id, size_type_id, size_val_idx_abs, packed_flags]
            # size: uses getFnValueByID (absolute, not relative)
            size_ty = inst.get('size_type', inst['alloc_type'])
            size_val = self._abs_val(inst.get('size_val', inst.get('size_const_idx', 0)))
            vals.append(inst['alloc_type'])
            vals.append(size_ty)
            vals.append(size_val)
            align_enc = _encode_align(inst.get('align', 1))
            packed = align_enc | (1 << 6)  # ExplicitType=true
            vals.append(packed)
            self.B.unabbrev(FUNC_CODE_INST_ALLOCA, vals)
        elif op == 'load':
            # load: [ptr_rel, res_type_id, align_enc, volatile]
            # ptr read via getValueTypePair (backward ref = 1 value)
            vals.append(self._rel_val(inst['ptr_val'], next_value_id))
            vals.append(inst['res_type'])
            vals.append(_encode_align(inst.get('align', 1)))
            vals.append(1 if inst.get('volatile') else 0)
            self.B.unabbrev(FUNC_CODE_INST_LOAD, vals)
        elif op == 'store':
            # store: [ptr_rel, val_rel, align_enc, volatile]
            # Ptr first, then Val via getValueTypePair (backward ref = 1 value each)
            vals.append(self._rel_val(inst['ptr_val'], next_value_id))
            vals.append(self._rel_val(inst['val_val'], next_value_id))
            vals.append(_encode_align(inst.get('align', 1)))
            vals.append(1 if inst.get('volatile') else 0)
            self.B.unabbrev(FUNC_CODE_INST_STORE, vals)
        elif op == 'binop':
            # binop: [lhs_rel, rhs_rel, opcode]
            vals.append(self._rel_val(inst['lhs_val'], next_value_id))
            vals.append(self._rel_val(inst['rhs_val'], next_value_id))
            vals.append(_get_binop(inst['opcode']))
            self.B.unabbrev(FUNC_CODE_INST_BINOP, vals)
        elif op == 'icmp':
            # icmp: [lhs_rel, rhs_rel, pred]
            vals.append(self._rel_val(inst['lhs_val'], next_value_id))
            vals.append(self._rel_val(inst['rhs_val'], next_value_id))
            vals.append(_get_icmp(inst['pred']))
            self.B.unabbrev(FUNC_CODE_INST_CMP2, vals)
        elif op == 'fcmp':
            # fcmp: [lhs_rel, rhs_rel, pred]
            vals.append(self._rel_val(inst['lhs_val'], next_value_id))
            vals.append(self._rel_val(inst['rhs_val'], next_value_id))
            vals.append(_get_fcmp(inst['pred']))
            self.B.unabbrev(FUNC_CODE_INST_CMP2, vals)
        elif op == 'br_uncond':
            bb_id = inst['dest_bb']
            vals.append(bb_id)
            self.B.unabbrev(FUNC_CODE_INST_BR, vals)
        elif op == 'br_cond':
            vals.append(inst['true_bb'])
            vals.append(inst['false_bb'])
            vals.append(self._rel_val(inst['cond_val'], next_value_id))
            self.B.unabbrev(FUNC_CODE_INST_BR, vals)
        elif op == 'phi':
            vals.append(inst['res_type'])
            for val_idx, bb_id in inst['incomings']:
                vals.append(self._rel_val(val_idx, next_value_id))
                vals.append(bb_id)
            self.B.unabbrev(FUNC_CODE_INST_PHI, vals)
        elif op == 'select':
            # vselect: [true_rel, false_rel, cond_rel]
            vals.append(self._rel_val(inst['true_val'], next_value_id))
            vals.append(self._rel_val(inst['false_val'], next_value_id))
            vals.append(self._rel_val(inst['cond_val'], next_value_id))
            self.B.unabbrev(FUNC_CODE_INST_VSELECT, vals)
        elif op == 'call':
            vals.append(inst.get('attrs_id', 0))
            cc = inst.get('calling_conv', 0)
            vals.append(cc | (1 << 15))  # CALL_EXPLICIT_TYPE
            vals.append(inst['callee_type'])
            vals.append(inst['callee_type'])
            vals.append(self._rel_val(inst['callee_val'], next_value_id))
            for arg in inst.get('args', []):
                vals.append(self._rel_val(arg, next_value_id))
            self.B.unabbrev(FUNC_CODE_INST_CALL, vals)
        elif op == 'gep':
            # gep: [inbounds, elt_type, ptr_rel, ...indices...]
            # ptr via getValueTypePair (backward ref = 1 value)
            vals.append(1 if inst['inbounds'] else 0)
            vals.append(inst['elt_type'])
            vals.append(self._rel_val(inst['ptr_val'], next_value_id))
            for idx_type, idx_val in inst['indices']:
                vals.append(idx_type)
                vals.append(self._rel_val(idx_val, next_value_id))
            self.B.unabbrev(FUNC_CODE_INST_GEP, vals)
        elif op == 'cast':
            vals.append(inst['src_type'])
            vals.append(self._rel_val(inst['src_val'], next_value_id))
            vals.append(inst['dst_type'])
            vals.append(_get_cast(inst['opcode']))
            self.B.unabbrev(FUNC_CODE_INST_CAST, vals)
        elif op == 'extractelement':
            vals.append(inst['vec_type'])
            vals.append(self._rel_val(inst['vec_val'], next_value_id))
            vals.append(inst['idx_type'])
            vals.append(self._rel_val(inst['idx_val'], next_value_id))
            self.B.unabbrev(FUNC_CODE_INST_EXTRACTELT, vals)
        elif op == 'insertelement':
            vals.append(inst['vec_type'])
            vals.append(self._rel_val(inst['vec_val'], next_value_id))
            vals.append(self._rel_val(inst['elt_val'], next_value_id))
            vals.append(inst['idx_type'])
            vals.append(self._rel_val(inst['idx_val'], next_value_id))
            self.B.unabbrev(FUNC_CODE_INST_INSERTELT, vals)
        elif op == 'shufflevector':
            vals.append(inst['vec_type'])
            vals.append(self._rel_val(inst['v1_val'], next_value_id))
            vals.append(self._rel_val(inst['v2_val'], next_value_id))
            vals.append(self._rel_val(inst['mask_val'], next_value_id))
            self.B.unabbrev(FUNC_CODE_INST_SHUFFLEVEC, vals)
        elif op == 'extractvalue':
            vals.append(inst['agg_type'])
            vals.append(self._rel_val(inst['agg_val'], next_value_id))
            vals.extend(inst['indices'])
            self.B.unabbrev(FUNC_CODE_INST_EXTRACTVAL, vals)
        elif op == 'insertvalue':
            vals.append(inst['agg_type'])
            vals.append(self._rel_val(inst['agg_val'], next_value_id))
            vals.append(inst['val_type'])
            vals.append(self._rel_val(inst['val_val'], next_value_id))
            vals.extend(inst['indices'])
            self.B.unabbrev(FUNC_CODE_INST_INSERTVAL, vals)
        elif op == 'fneg':
            vals.append(inst['src_type'])
            vals.append(self._rel_val(inst['src_val'], next_value_id))
            vals.append(UNOP_FNEG)
            self.B.unabbrev(FUNC_CODE_INST_UNOP, vals)
        elif op == 'unreachable':
            self.B.unabbrev(FUNC_CODE_INST_UNREACHABLE, [])

    # ── LLVM ValueList ID tracking ───────────────────────────────────
    def _compute_llvm_ids(self):
        """Assign absolute LLVM ValueList IDs matching LLVM reader's ordering:
           1. Module-level constants
           2. Globals
           3. Functions
           4. (Per-function: constants, then instruction results—tracked separately)
        """
        id_map = {}  # _values index -> LLVM ValueList ID

        local_const_indices = set()
        for f in self._functions:
            local_const_indices.update(f.local_consts)

        llvm_id = 0

        # 1. Module-level constants first (reader's parseConstants in parseModule)
        for vi, v in enumerate(self._values):
            if v.get('is_const') and vi not in local_const_indices:
                id_map[vi] = llvm_id
                llvm_id += 1

        # 2. Globals
        for g in self._globals:
            id_map[g['value_idx']] = llvm_id
            llvm_id += 1

        # 3. Functions
        for f in self._functions:
            id_map[f.value_idx] = llvm_id
            llvm_id += 1

        self._llvm_id_map = id_map
        self._module_value_count = llvm_id

        # 4. Per-function local constants — their IDs start at _module_value_count
        for f in self._functions:
            for vi in f.local_consts:
                id_map[vi] = llvm_id
                llvm_id += 1

    # ── Write Module ────────────────────────────────────────────────
    def write(self):
        B = self.B
        B.magic()

        # Compute LLVM ValueList IDs before writing anything
        self._compute_llvm_ids()

        # Register names in string table
        for func in self._functions:
            vid = self._llvm_id_map[func.value_idx]
            self._strtab.add_value(vid, func.name)

        # Identification block
        B.enter(IDENTIFICATION_BLOCK_ID, 5)
        B.def_abbrev([('lit', 1), ('array',), ('char6',)])
        B.code(4 + 0)
        B.vbr(7, 6)  # length of string
        for c in self.source:
            B.char6(ord(c))
        B.def_abbrev([('lit', 2), ('vbr', 6)])
        B.code(4 + 1)
        B.vbr(0, 6)  # epoch
        B.exit()

        # Module block
        B.enter(MODULE_BLOCK_ID, 3)

        # Version
        B.unabbrev(MODULE_CODE_VERSION, [2])

        # Source filename & triple
        B.unabbrev(MODULE_CODE_SOURCE_FILENAME, [ord(c) for c in self.source])
        B.unabbrev(MODULE_CODE_TRIPLE, [ord(c) for c in self.triple])

        # BLOCKINFO
        B.enter(BLOCKINFO_BLOCK_ID, 2)
        B.unabbrev(BLOCKINFO_SETBID, [TYPE_BLOCK_ID_NEW])
        B.unabbrev(BLOCKINFO_SETBID, [FUNCTION_BLOCK_ID])
        B.exit()

        # Types
        self._write_type_table()

        # Constants (module-level)
        local_const_indices = set()
        for f in self._functions:
            local_const_indices.update(f.local_consts)
        mod_consts = [i for i, v in enumerate(self._values)
                      if v.get('is_const') and v.get('const_kind') is not None
                      and i not in local_const_indices]
        self._write_constants_block(mod_consts)

        # Globals
        for g in self._globals:
            B.unabbrev(MODULE_CODE_GLOBALVAR, [
                g['type_idx'], g.get('constant', 0),
                g.get('init', 0), g.get('linkage', 0),
                0, 0, 0, 0, 0, 0,
            ])

        # Function declarations (module-level records)
        # Format for module version >= 2:
        #   [strtab_offset, strtab_size, type_idx, calling_conv,
        #    isProto, linkage, paramattr, align, section, visibility]
        for func in self._functions:
            strtab_off = 0
            strtab_sz = 0
            B.unabbrev(MODULE_CODE_FUNCTION, [
                strtab_off, strtab_sz,
                func.type_idx, func.calling_conv,
                0, 0, 0, 0, 0, 0,
            ])

        # Function bodies
        for func in self._functions:
            self._write_function(func)

        B.exit()
        B.flush()
        return bytes(B.Out)


# ══════════════════════════════════════════════════════════════════════
# TEST
# ══════════════════════════════════════════════════════════════════════

def build_test_minimal():
    """Minimal test: define void @main() { ret void }"""
    M = ModuleBuilder()
    v = M.t_void()
    f_ty = M.t_func(v, [])
    cfg = CFGFunction('main', f_ty)
    bb = cfg.new_block('entry')
    bb.term = ('ret', None)
    M.add_function(cfg)
    return M

def build_test_ret_i32():
    """
    define i32 @main() {
      ret i32 42
    }
    LLVM value numbering at module level:
      ID 0: const_i32_42
      ID 1: main function
    Function body: NextValueNo = 2
      RET: InstNum = 2, stored_val = 2 - 0 = 2
    """
    M = ModuleBuilder(triple='dxil-ms-dx')
    v = M.t_void()
    i32 = M.t_int(32)
    f_ty = M.t_func(i32, [])

    const_42 = M.add_constant_int(i32, 42)

    cfg = CFGFunction('main', f_ty)
    bb = cfg.new_block('entry')
    bb.term = ('ret', const_42)
    M.add_function(cfg)
    return M

def build_test_alloca():
    """
    define void @main() {
      %a = alloca i32, align 4
      store i32 42, i32* %a
      %b = load i32, i32* %a
      ret void
    }
    
    LLVM value numbering:
      ID 0: main function
      ID 1: const_one (i32 1)     — function-local constant
      ID 2: const_42 (i32 42)     — function-local constant
      ID 3: alloca result %a
      ID 4: load result %b
    """
    M = ModuleBuilder()

    v = M.t_void()
    i32 = M.t_int(32)
    i32p = M.t_ptr(i32)
    f_ty = M.t_func(v, [])

    cfg = CFGFunction('main', f_ty)

    const_one = M.add_constant_int(i32, 1)
    const_42 = M.add_constant_int(i32, 42)

    cfg.local_consts = [const_one, const_42]

    bb = cfg.new_block('entry')
    bb.body = [
        {'op': 'alloca', 'alloc_type': i32, 'align': 4, 'size_val': const_one, 'size_type': i32},
        {'op': 'store', 'ptr_type': i32p, 'ptr_val': 3, 'val_type': i32, 'val_val': const_42, 'align': 4},
        {'op': 'load', 'ptr_type': i32p, 'ptr_val': 3, 'res_type': i32, 'align': 4},
    ]
    bb.term = ('ret', None)

    M.add_function(cfg)
    return M

def build_test_arith():
    """
    define i32 @main(i32 %x, i32 %y) {
      %sum = add i32 %x, %y
      %cmp = icmp sgt i32 %sum, 0
      ret i32 %sum
    }
    """
    M = ModuleBuilder()
    v = M.t_void()
    i32 = M.t_int(32)
    i1 = M.t_int(1)
    f_ty = M.t_func(i32, [i32, i32])  # returns i32, takes i32, i32

    # Constants
    const_zero = M.add_constant_int(i32, 0)

    f = M.add_function('main', f_ty)
    f['local_constants'] = [const_zero]

    # In function: args are %x (ID 0 = after constants) and %y (ID 1)
    # const_zero = ID 0 (local_const)
    # args start at ID 1: %x=1, %y=2
    # Instructions: %sum=3, %cmp=4

    # Adjust: LLVM args are after module-level values. In our simplified model,
    # function-local values are: consts first, then args, then instructions.
    # Actually in LLVM: arguments are incorporated during incorporateFunction
    # BEFORE constants. So args are at IDs 0,1 and constants at 2,3...

    # Let me use explicit value indices directly in this test.

    return M


if __name__ == '__main__':
    import sys
    test_name = sys.argv[1] if len(sys.argv) > 1 else 'ret_i32'
    builders = {
        'minimal': build_test_minimal,
        'ret_i32': build_test_ret_i32,
        'alloca': build_test_alloca,
    }
    M = builders[test_name]()
    data = M.write()
    print('Size: %d bytes' % len(data))
    r = _sp.run([LLVM_DIS, '-', '-o', 'nul'], input=bytes(data), capture_output=True, timeout=5)
    if r.returncode == 0:
        r2 = _sp.run([LLVM_DIS, '-'], input=bytes(data), capture_output=True, timeout=5)
        print('OK!')
        print(r2.stdout.decode()[:1500])
    else:
        print('FAIL: %s' % r.stderr.decode()[:1000])
