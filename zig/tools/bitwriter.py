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
      ('br_cond', cond, bb_true, bb_false) → conditional branch
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
        if kind == 'br_cond':
            return [self.term[2], self.term[3]]
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

# ── DXIL Resource Model ────────────────────────────────────────────────

# DXIL resource classes (from DXC's dxc/HLSL/DxilConstants.h)
DXIL_RESOURCE_CLASS_SRV     = 0
DXIL_RESOURCE_CLASS_UAV     = 1
DXIL_RESOURCE_CLASS_SAMPLER = 2
DXIL_RESOURCE_CLASS_CBUF    = 3

# SRV kinds
DXIL_SRV_KIND_TEXTURE2D     = 1
DXIL_SRV_KIND_TEXTURE3D     = 3
DXIL_SRV_KIND_TEXTURECUBE   = 4
DXIL_SRV_KIND_TEXTURE2DARRAY = 6
DXIL_SRV_KIND_TYPED_BUFFER  = 9
DXIL_SRV_KIND_RAW_BUFFER    = 10
DXIL_SRV_KIND_STRUCTURED_BUFFER = 11

# UAV kinds
DXIL_UAV_KIND_RW_TEXTURE2D  = 1
DXIL_UAV_KIND_RW_TYPED_BUFFER = 9
DXIL_UAV_KIND_RW_RAW_BUFFER = 10
DXIL_UAV_KIND_RW_STRUCTURED_BUFFER = 11

# DXIL scalar element types (for typed resources)
DXIL_ELEMENT_TYPE_I32  = 1
DXIL_ELEMENT_TYPE_F32  = 2
DXIL_ELEMENT_TYPE_F16  = 3
DXIL_ELEMENT_TYPE_I16  = 3
DXIL_ELEMENT_TYPE_I64  = 4
DXIL_ELEMENT_TYPE_F64  = 4

RESOURCE_KIND_NAMES = {
    ('t', 1): 'Texture2D', ('t', 3): 'Texture3D', ('t', 4): 'TextureCube',
    ('t', 6): 'Texture2DArray',
    ('u', 1): 'RWTexture2D',
    ('s',): 'Sampler',
    ('b',): 'CBuffer',
}


@dataclass
class DXILResource:
    """A DXIL resource declaration with binding info."""
    name: str
    res_class: int          # SRV/UAV/SAMPLER/CBUF
    res_kind: int           # Texture2D=1, etc.
    reg_type: str           # 't', 'u', 's', 'b'
    reg_num: int            # register number
    space: int = 0          # descriptor space
    elt_type: int = 0       # DXIL scalar element type (for typed resources)
    stride: int = 0         # byte stride (for structured buffers)
    value_idx: int = -1     # LLVM ValueList ID

    def tag(self):
        return f'{self.reg_type}{self.reg_num}space{self.space}'

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
TYPE_CODE_OPAQUE      = 6
TYPE_CODE_STRUCT_ANON = 18
TYPE_CODE_STRUCT_NAME = 19
TYPE_CODE_STRUCT_NAMED = 20
TYPE_CODE_METADATA     = 16
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

# ── Metadata codes (Emscripten LLVM 13 fork) ────────────────────────
# These are ONLY valid inside METADATA_BLOCK (15), NOT in MODULE_BLOCK.
METADATA_STRING_OLD    = 1   # raw chars (UNHANDLED by non-lazy reader!)
METADATA_VALUE         = 2   # [type_idx, value_id] wraps LLVM value as metadata
METADATA_NODE          = 3   # [1based_md_ids...] new-style MDNode
METADATA_NAME          = 4   # raw chars for named metadata key
METADATA_DISTINCT_NODE = 5
METADATA_OLD_NODE      = 8
METADATA_OLD_FN_NODE   = 9
METADATA_NAMED_NODE    = 10  # references a NAME'd node
METADATA_STRINGS       = 35  # blob: ULEB128(len)+chars per string

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
        self.BlockScopes.append((self.CurCodeSize, si, self._n_abbrevs))
        self.CurCodeSize = cl
        self._n_abbrevs = 0  # each block has its own abbreviation table

    def exit(self):
        pcs, si, saved_abbrevs = self.BlockScopes.pop()
        self.code(0)
        self.flush()
        struct.pack_into('<I', self.Out, si * 4, self.word_idx() - si - 1)
        self.CurCodeSize = pcs
        self._n_abbrevs = saved_abbrevs

    def abbrev_record(self, abbrev_idx, vals, blob_data=None):
        """Emit an abbreviated record. Vals are encoded as VBR(6)."""
        self.code(4 + abbrev_idx)
        for v in vals:
            self.vbr(v, 6)
        if blob_data is not None:
            self.blob(blob_data)

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

        # DXIL resources
        self._resources = []

        # Metadata
        self._named_md = []

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

    # ── DXIL type helpers ──────────────────────────────────────────
    def t_dx_handle(self):
        """%dx.types.Handle = type { ptr } — resource handle"""
        i8 = self.t_int(8)
        i8p = self.t_ptr(i8)
        return self._ensure_type('struct_anon', elts=(i8p,))

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

    # ── DXIL Resource management ────────────────────────────────────
    def add_dx_resource(self, res: DXILResource):
        """Register a DXIL resource: creates a global @dx.types.Handle variable."""
        handle_ty = self.t_dx_handle()
        handle_ptr = self.t_ptr(handle_ty)
        # GLOBALVAR takes the VALUE type, not the pointer type
        gv_idx = self.add_global(res.name, handle_ty, linkage=0)
        res.value_idx = gv_idx
        self._resources.append(res)
        return res

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
                # TYPE_CODE_POINTER (8) for typed pointers: [pointee_type_idx]
                # addrspace defaults to 0
                self.B.unabbrev(TYPE_CODE_POINTER, [a['pointee']])
            elif k == 'vec':
                self.B.unabbrev(TYPE_CODE_VECTOR, [a['count'], a['elt']])
            elif k == 'arr':
                self.B.unabbrev(TYPE_CODE_ARRAY, [a['count'], a['elt']])
            elif k == 'func':
                vals = [1 if a.get('vararg') else 0, a['ret']]
                vals.extend(a['params'])
                self.B.unabbrev(TYPE_CODE_FUNCTION, vals)
            elif k == 'struct_anon':
                # STRUCT_ANON: [ispacked, eltty x N]
                self.B.unabbrev(TYPE_CODE_STRUCT_ANON, [0] + list(a['elts']))
            elif k == 'dx_handle':
                self.B.unabbrev(TYPE_CODE_OPAQUE, [])
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
                # LLVM sign-rotation: check signed negativity in the value's bit width
                ty = self._types[v['type_idx']]
                bits = ty['args'].get('bits', 32)
                is_neg = bool((raw >> (bits - 1)) & 1) if bits > 0 else (raw < 0)
                if is_neg:
                    # Negate in the type's bit width: twos_complement = ~raw + 1 (mod 2^bits)
                    neg = ((-raw) & ((1 << bits) - 1)) if raw < 0 else ((~raw + 1) & ((1 << bits) - 1))
                    raw = (neg << 1) | 1
                else:
                    raw = raw << 1
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
        if kind == 'br_cond':
            return {'op': 'br_cond', 'cond_val': term[1], 'true_bb': term[2], 'false_bb': term[3]}
        if kind == 'unreachable':
            return {'op': 'unreachable'}
        raise ValueError(f'unknown terminator: {term}')

    def _write_function(self, cfg: CFGFunction):
        self.B.enter(FUNCTION_BLOCK_ID, 4)

        self.B.unabbrev(FUNC_CODE_DECLAREBLOCKS, [len(cfg.blocks)])

        nargs = len(self._types[cfg.type_idx]['args']['params'])

        # LLVM reader ordering: args BEFORE constants
        # So function-local constants start after module values + args
        next_value_id = self._module_value_count + nargs

        # Write function-local constants and assign their LLVM IDs
        if cfg.local_consts:
            self._write_constants_block(cfg.local_consts)
            for i, vi in enumerate(cfg.local_consts):
                self._const_llvm_map[vi] = next_value_id + i
            next_value_id += len(cfg.local_consts)

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

    def _rel_val(self, abs_llvm, next_value_id):
        """Relative encoding for getValue/getValueTypePair (UseRelativeIDs=true)."""
        return next_value_id - abs_llvm

    def _phi_val(self, abs_llvm, next_value_id):
        """PHI encoding: sign-rotated relative for getValueSigned."""
        diff = next_value_id - abs_llvm
        if diff >= 0:
            return diff << 1
        return ((-diff) << 1) | 1

    def _rel(self, operand, next_value_id):
        """Resolve operand: tuple ('const', py_idx) or int (LLVM ID) → relative value."""
        if isinstance(operand, tuple) and operand[0] == 'const':
            return self._rel_val(self._const_llvm_map[operand[1]], next_value_id)
        return self._rel_val(operand, next_value_id)

    def _phi_rel(self, operand, next_value_id):
        """Resolve PHI operand to sign-rotated relative value."""
        if isinstance(operand, tuple) and operand[0] == 'const':
            return self._phi_val(self._const_llvm_map[operand[1]], next_value_id)
        return self._phi_val(operand, next_value_id)

    def _write_inst(self, inst, next_value_id):
        op = inst['op']
        vals = []

        if op == 'retvoid':
            self.B.unabbrev(FUNC_CODE_INST_RET, [])
        elif op == 'retval':
            vals.append(self._rel(inst['val_idx'], next_value_id))
            self.B.unabbrev(FUNC_CODE_INST_RET, vals)
        elif op == 'alloca':
            size_ty = inst.get('size_type', inst['alloc_type'])
            size_val = self._rel(inst.get('size_val', inst.get('size_const_idx', 0)), next_value_id)
            vals.append(inst['alloc_type'])
            vals.append(size_ty)
            vals.append(size_val)
            align_enc = _encode_align(inst.get('align', 1))
            packed = align_enc | (1 << 6)
            vals.append(packed)
            self.B.unabbrev(FUNC_CODE_INST_ALLOCA, vals)
        elif op == 'load':
            vals.append(self._rel(inst['ptr_val'], next_value_id))
            vals.append(inst['res_type'])
            vals.append(_encode_align(inst.get('align', 1)))
            vals.append(1 if inst.get('volatile') else 0)
            self.B.unabbrev(FUNC_CODE_INST_LOAD, vals)
        elif op == 'store':
            vals.append(self._rel(inst['ptr_val'], next_value_id))
            vals.append(self._rel(inst['val_val'], next_value_id))
            vals.append(_encode_align(inst.get('align', 1)))
            vals.append(1 if inst.get('volatile') else 0)
            self.B.unabbrev(FUNC_CODE_INST_STORE, vals)
        elif op == 'binop':
            vals.append(self._rel(inst['lhs_val'], next_value_id))
            vals.append(self._rel(inst['rhs_val'], next_value_id))
            vals.append(_get_binop(inst['opcode']))
            self.B.unabbrev(FUNC_CODE_INST_BINOP, vals)
        elif op == 'icmp':
            vals.append(self._rel(inst['lhs_val'], next_value_id))
            vals.append(self._rel(inst['rhs_val'], next_value_id))
            vals.append(_get_icmp(inst['pred']))
            self.B.unabbrev(FUNC_CODE_INST_CMP2, vals)
        elif op == 'fcmp':
            vals.append(self._rel(inst['lhs_val'], next_value_id))
            vals.append(self._rel(inst['rhs_val'], next_value_id))
            vals.append(_get_fcmp(inst['pred']))
            self.B.unabbrev(FUNC_CODE_INST_CMP2, vals)
        elif op == 'br_uncond':
            bb_id = inst['dest_bb']
            vals.append(bb_id)
            self.B.unabbrev(FUNC_CODE_INST_BR, vals)
        elif op == 'br_cond':
            # Fork format: [TrueBB, FalseBB, Cond_rel]
            vals.append(inst['true_bb'])
            vals.append(inst['false_bb'])
            vals.append(self._rel(inst['cond_val'], next_value_id))
            self.B.unabbrev(FUNC_CODE_INST_BR, vals)
        elif op == 'phi':
            vals.append(inst['res_type'])
            for val_idx, bb_id in inst['incomings']:
                vals.append(self._phi_rel(val_idx, next_value_id))
                vals.append(bb_id)
            self.B.unabbrev(FUNC_CODE_INST_PHI, vals)
        elif op == 'select':
            vals.append(self._rel(inst['true_val'], next_value_id))
            vals.append(self._rel(inst['false_val'], next_value_id))
            vals.append(self._rel(inst['cond_val'], next_value_id))
            self.B.unabbrev(FUNC_CODE_INST_VSELECT, vals)
        elif op == 'call':
            vals.append(inst.get('attrs_id', 0))
            cc = inst.get('calling_conv', 0)
            vals.append(cc | (1 << 15))
            vals.append(inst['callee_type'])
            vals.append(inst['callee_type'])
            vals.append(self._rel(inst['callee_val'], next_value_id))
            for arg in inst.get('args', []):
                vals.append(self._rel(arg, next_value_id))
            self.B.unabbrev(FUNC_CODE_INST_CALL, vals)
        elif op == 'gep':
            vals.append(1 if inst['inbounds'] else 0)
            vals.append(inst['elt_type'])
            vals.append(self._rel(inst['ptr_val'], next_value_id))
            for idx_type, idx_val in inst['indices']:
                vals.append(idx_type)
                vals.append(self._rel(idx_val, next_value_id))
            self.B.unabbrev(FUNC_CODE_INST_GEP, vals)
        elif op == 'cast':
            vals.append(inst['src_type'])
            vals.append(self._rel(inst['src_val'], next_value_id))
            vals.append(inst['dst_type'])
            vals.append(_get_cast(inst['opcode']))
            self.B.unabbrev(FUNC_CODE_INST_CAST, vals)
        elif op == 'extractelement':
            vals.append(inst['vec_type'])
            vals.append(self._rel(inst['vec_val'], next_value_id))
            vals.append(inst['idx_type'])
            vals.append(self._rel(inst['idx_val'], next_value_id))
            self.B.unabbrev(FUNC_CODE_INST_EXTRACTELT, vals)
        elif op == 'insertelement':
            vals.append(inst['vec_type'])
            vals.append(self._rel(inst['vec_val'], next_value_id))
            vals.append(self._rel(inst['elt_val'], next_value_id))
            vals.append(inst['idx_type'])
            vals.append(self._rel(inst['idx_val'], next_value_id))
            self.B.unabbrev(FUNC_CODE_INST_INSERTELT, vals)
        elif op == 'shufflevector':
            vals.append(inst['vec_type'])
            vals.append(self._rel(inst['v1_val'], next_value_id))
            vals.append(self._rel(inst['v2_val'], next_value_id))
            vals.append(self._rel(inst['mask_val'], next_value_id))
            self.B.unabbrev(FUNC_CODE_INST_SHUFFLEVEC, vals)
        elif op == 'extractvalue':
            vals.append(inst['agg_type'])
            vals.append(self._rel(inst['agg_val'], next_value_id))
            vals.extend(inst['indices'])
            self.B.unabbrev(FUNC_CODE_INST_EXTRACTVAL, vals)
        elif op == 'insertvalue':
            vals.append(inst['agg_type'])
            vals.append(self._rel(inst['agg_val'], next_value_id))
            vals.append(inst['val_type'])
            vals.append(self._rel(inst['val_val'], next_value_id))
            vals.extend(inst['indices'])
            self.B.unabbrev(FUNC_CODE_INST_INSERTVAL, vals)
        elif op == 'fneg':
            vals.append(inst['src_type'])
            vals.append(self._rel(inst['src_val'], next_value_id))
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
        self._const_llvm_map = {}  # constant py_idx -> LLVM ID (all scopes)

        local_const_indices = set()
        for f in self._functions:
            local_const_indices.update(f.local_consts)

        llvm_id = 0

        # 1. Module-level constants first (reader's parseConstants in parseModule)
        for vi, v in enumerate(self._values):
            if v.get('is_const') and vi not in local_const_indices:
                id_map[vi] = llvm_id
                self._const_llvm_map[vi] = llvm_id
                llvm_id += 1

        # 2. Globals
        for g in self._globals:
            id_map[g['value_idx']] = llvm_id
            llvm_id += 1

        # 3. Functions — NOT added to _llvm_id_map to avoid collisions with
        #    raw LLVM IDs (args/instruction-results aren't in _values but
        #    their IDs can equal _values indices of functions).
        #    Use _function_to_llvm_id for function lookups instead.
        self._function_to_llvm_id = {}
        for f in self._functions:
            self._function_to_llvm_id[f.value_idx] = llvm_id
            llvm_id += 1

        self._llvm_id_map = id_map
        self._module_value_count = llvm_id
        # Per-function local constant IDs are assigned in _write_function
        # (they come after args in the reader's ValueList ordering)

    # ── Metadata helpers ────────────────────────────────────────────
    def _setup_metadata_constants(self):
        """Create module-level constants needed for DXIL metadata operands.
        
        Populates self._md_const_map: value -> _values index (for i32 constants).
        Must be called before _compute_llvm_ids.
        """
        self._md_const_map = {}
        if not self._resources:
            return
        i32 = self._ensure_type('int', bits=32)
        needed = set()
        for res in self._resources:
            needed.add(res.res_class)
            needed.add(res.res_kind)
            needed.add(res.reg_num)
            needed.add(res.space)
            needed.add(res.elt_type)
        for v in sorted(needed):
            if v not in self._md_const_map:
                const_idx = self.add_constant_int(i32, v)
                self._md_const_map[v] = const_idx

    def _write_dxil_metadata(self):
        """Emit DXIL metadata (!dx.resources) inside a METADATA_BLOCK subblock.
        
        Uses Emscripten fork metadata codes:
          METADATA_STRINGS (35) blob for MDStrings
          METADATA_VALUE (2) to wrap LLVM values as metadata entries
          METADATA_NODE (3) for MDNodes (1-based metadata IDs)
          METADATA_NAME (4) + METADATA_NAMED_NODE (10) for named metadata
        """
        if not self._resources:
            return
        B = self.B
        B.enter(METADATA_BLOCK_ID, 4)

        # Define abbreviation for METADATA_STRINGS blob
        strs_abbrev = B.def_abbrev([
            ('lit', METADATA_STRINGS),
            ('vbr', 6),  # num strings
            ('vbr', 6),  # strings_offset (byte offset of char data in blob)
            ('blob',),   # [VBR6(lengths) bitstream][chars]
        ])

        # Collect unique resource name strings
        uniq_names = []
        seen = set()
        for res in self._resources:
            if res.name not in seen:
                seen.add(res.name)
                uniq_names.append(res.name)

        # Build blob: VBR(6) length bitstream + raw chars
        LB = BitWriter()
        for s in uniq_names:
            LB.vbr(len(s.encode('utf-8')), 6)
        LB.flush()
        lengths_bytes = bytes(LB.Out)

        chars_bytes = bytearray()
        for s in uniq_names:
            chars_bytes.extend(s.encode('utf-8'))

        strings_offset = len(lengths_bytes)
        blob_data = lengths_bytes + bytes(chars_bytes)
        str_index = {s: i for i, s in enumerate(uniq_names)}

        if uniq_names:
            B.abbrev_record(strs_abbrev, [len(uniq_names), strings_offset], blob_data)
            next_md_id = len(uniq_names)  # MDStrings get IDs 0..N-1
        else:
            next_md_id = 0

        # Get type indices for METADATA_VALUE records
        i32_ty = self.t_int(32)
        handle_ptr_ty = self.t_ptr(self.t_dx_handle())

        # Helper: emit METADATA_VALUE wrapping an LLVM value as metadata entry
        def emit_value(ty, val):
            nonlocal next_md_id
            nid = next_md_id
            B.unabbrev(METADATA_VALUE, [ty, val])
            next_md_id += 1
            return nid

        # Helper: emit METADATA_NODE with 1-based metadata IDs (0=null)
        def emit_node(md_ids):
            nonlocal next_md_id
            nid = next_md_id
            rec = [i + 1 for i in md_ids]
            B.unabbrev(METADATA_NODE, rec)
            next_md_id += 1
            return nid

        # Emit resource entry nodes grouped by class
        entries = {c: [] for c in range(4)}
        for res in self._resources:
            # Wrap each LLVM value as metadata via METADATA_VALUE
            class_id = emit_value(i32_ty, self._llvm_id_map[self._md_const_map[res.res_class]])
            kind_id = emit_value(i32_ty, self._llvm_id_map[self._md_const_map[res.res_kind]])
            reg_id = emit_value(i32_ty, self._llvm_id_map[self._md_const_map[res.reg_num]])
            space_id = emit_value(i32_ty, self._llvm_id_map[self._md_const_map[res.space]])
            handle_id = emit_value(handle_ptr_ty, self._llvm_id_map[res.value_idx])
            string_id = str_index[res.name]  # MDString's 0-based metadata ID
            elt_id = emit_value(i32_ty, self._llvm_id_map[self._md_const_map[res.elt_type]])

            # MDNode for this resource entry (mix of value-wrappers and MDStrings)
            nid = emit_node([class_id, kind_id, reg_id, space_id, handle_id, string_id, elt_id])
            entries[res.res_class].append(nid)

        # Per-class list nodes (METADATA_NODE format: 1-based IDs, 0=null)
        def list_node_or_null(ids):
            return emit_node(ids) if ids else None

        srv_id = list_node_or_null(entries[DXIL_RESOURCE_CLASS_SRV])
        uav_id = list_node_or_null(entries[DXIL_RESOURCE_CLASS_UAV])
        smp_id = list_node_or_null(entries[DXIL_RESOURCE_CLASS_SAMPLER])
        cbuf_id = list_node_or_null(entries[DXIL_RESOURCE_CLASS_CBUF])

        # Root node: METADATA_NODE with 1-based IDs (0=null)
        root_rec = []
        for nid in (srv_id, uav_id, smp_id, cbuf_id):
            root_rec.append(nid + 1 if nid is not None else 0)
        root_id = next_md_id
        B.unabbrev(METADATA_NODE, root_rec)
        next_md_id += 1

        # Named metadata: !dx.resources = !{!root}
        B.unabbrev(METADATA_NAME, [ord(c) for c in 'dx.resources'])
        B.unabbrev(METADATA_NAMED_NODE, [root_id])
        B.exit()

    # ── Write Module ────────────────────────────────────────────────
    def write(self):
        B = self.B
        B.magic()

        # Create metadata constants before LLVM ValueList ID computation
        self._setup_metadata_constants()

        # Compute LLVM ValueList IDs before writing anything
        self._compute_llvm_ids()

        # CFG validation
        for func in self._functions:
            errors = validate_cfg(func)
            if errors:
                raise ValueError(f"CFG validation failed for '{func.name}': {'; '.join(errors)}")

        # Register names in string table
        for func in self._functions:
            vid = self._function_to_llvm_id.get(func.value_idx, 0)
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

        # Globals (LLVM 13 version >= 2 with strtab):
        # [strtab_off, strtab_sz, value_type_idx,
        #  addrspace<<2 | explicitType<<1 | isconst,
        #  init, linkage, alignment, section, visibility, threadlocal,
        #  unnamed_addr, externally_initialized, dllstorageclass, ...]
        for g in self._globals:
            # explicitType=1 (type is value type, not pointer type)
            combined = 2 | (1 if g.get('constant') else 0)
            B.unabbrev(MODULE_CODE_GLOBALVAR, [
                0, 0,  # strtab offset/size (empty name from strtab)
                g['type_idx'],
                combined,
                g.get('init', 0),
                g.get('linkage', 0),
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
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

        # DXIL metadata (before function bodies per LLVM convention)
        self._write_dxil_metadata()

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
    Module-level const_42 at LLVM ID 0, main function at ID 1.
    Function: NextValueNo = 2.
    RET: stored = 2 - 0 = 2, reader: 2-2=0 → const_42
    """
    M = ModuleBuilder(triple='dxil-ms-dx')
    v = M.t_void()
    i32 = M.t_int(32)
    f_ty = M.t_func(i32, [])

    const_42 = M.add_constant_int(i32, 42)

    cfg = CFGFunction('main', f_ty)
    bb = cfg.new_block('entry')
    bb.term = ('ret', ('const', const_42))
    M.add_function(cfg)
    return M

def build_test_dx_resource():
    """DXIL resource: declare a Texture2D<f32> at register t0, space 0."""
    M = ModuleBuilder(triple='dxil-ms-dx')
    v = M.t_void()
    i32 = M.t_int(32)
    f_ty = M.t_func(v, [])
    cfg = CFGFunction('main', f_ty)
    bb = cfg.new_block('entry')
    bb.term = ('ret', None)
    M.add_function(cfg)

    M.add_dx_resource(DXILResource(
        name='tex0',
        res_class=DXIL_RESOURCE_CLASS_SRV,
        res_kind=DXIL_SRV_KIND_TEXTURE2D,
        reg_type='t',
        reg_num=0,
        space=0,
        elt_type=DXIL_ELEMENT_TYPE_F32,
    ))
    return M

def build_test_alloca():
    """
    define void @main() {
      %a = alloca i32
      store i32 42, i32* %a
      %b = load i32, i32* %a
      ret void
    }
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

    # LLVM IDs within function:
    #   const_one → 1, const_42 → 2
    #   3 = alloca result, 4 = load result (store is void)
    bb = cfg.new_block('entry')
    bb.body = [
        {'op': 'alloca', 'alloc_type': i32, 'align': 4, 'size_val': ('const', const_one), 'size_type': i32},
        {'op': 'store', 'ptr_type': i32p, 'ptr_val': 3, 'val_type': i32, 'val_val': ('const', const_42), 'align': 4},
        {'op': 'load', 'ptr_type': i32p, 'ptr_val': 3, 'res_type': i32, 'align': 4},
    ]
    bb.term = ('ret', None)

    M.add_function(cfg)
    return M

# ── br_cond test builders (data-driven) ───────────────────────────────

def build_test_diamond_const():
    """
    define void @main() {
    entry:
      br i1 true, label %A, label %B
    A:
      ret void
    B:
      ret void
    }

    LLVM value numbering:
      ID 0: main function
      ID 1: const_true (i1 1) — function-local constant
      next_value_id starts at 1 + 1 + 0 = 2
      br_cond: cond_rel = 2 - 1 = 1, true_bb=1, false_bb=2
    """
    M = ModuleBuilder()
    v = M.t_void()
    i1 = M.t_int(1)
    M.t_label()  # required for multi-BB functions
    f_ty = M.t_func(v, [])
    const_true = M.add_constant_int(i1, 1)

    cfg = CFGFunction('main', f_ty)
    cfg.local_consts = [const_true]

    bb = cfg.new_block('entry')
    bb.term = ('br_cond', ('const', const_true), 1, 2)

    cfg.new_block('A').term = ('ret', None)
    cfg.new_block('B').term = ('ret', None)

    M.add_function(cfg)
    return M


def build_test_diamond_arg():
    """
    define void @main(i32 %x) {
    entry:
      %c = icmp sgt i32 %x, 0
      br i1 %c, label %A, label %B
    A:
      ret void
    B:
      ret void
    }

    LLVM value numbering:
      ID 0: main function
      ID 1: const_zero (i32 0) — function-local constant
      ID 2: arg %x (incorporated by reader after local consts, bumps NextValueNo)
      next_value_id starts at 1 + 1 + 1 = 3
      icmp: rhs_rel = 3 - 1 = 2, lhs_rel = 3 - 2 = 1, pred=sgt → result at ID 3
             (LLVM reads CMP2 as [rhs, lhs, pred], RHS first)
      br_cond: cond_val = icmp result at ID 3, cond_rel = 4 - 3 = 1, true_bb=1, false_bb=2
    """
    M = ModuleBuilder()
    v = M.t_void()
    i32 = M.t_int(32)
    i1 = M.t_int(1)
    M.t_label()  # required for multi-BB functions
    f_ty = M.t_func(v, [i32])

    const_zero = M.add_constant_int(i32, 0)

    cfg = CFGFunction('main', f_ty)
    cfg.local_consts = [const_zero]

    bb = cfg.new_block('entry')
    # arg at LLVM ID = _module_value_count + arg_idx = 1 + 0 = 1
    # const_zero at LLVM ID = _module_value_count + nargs + 0 = 1 + 1 + 0 = 2
    bb.body = [
        {'op': 'icmp', 'lhs_val': 1, 'rhs_val': ('const', const_zero), 'pred': 'sgt'},
    ]
    # cond_val=3 = LLVM ID of icmp result
    bb.term = ('br_cond', 3, 1, 2)

    cfg.new_block('A').term = ('ret', None)
    cfg.new_block('B').term = ('ret', None)

    M.add_function(cfg)
    return M


def build_test_diamond_void():
    """
    define void @main() {
    entry:
      br i1 true, label %A, label %B
    A:
      ret void
    B:
      ret void
    }

    Like diamond_const but uses a plain i1 constant and verifies
    that both empty target blocks produce valid LLVM.
    """
    M = ModuleBuilder()
    v = M.t_void()
    i1 = M.t_int(1)
    M.t_label()
    f_ty = M.t_func(v, [])
    const_true = M.add_constant_int(i1, 1)

    cfg = CFGFunction('main', f_ty)
    cfg.local_consts = [const_true]

    bb = cfg.new_block('entry')
    bb.term = ('br_cond', ('const', const_true), 1, 2)

    cfg.new_block('A').term = ('ret', None)
    bbB = cfg.new_block('B')
    bbB.term = ('ret', None)

    M.add_function(cfg)
    return M


def build_test_diamond_phi():
    """
    define void @main(i32 %x) {
    entry:
      %cond = icmp sgt i32 %x, 0
      br i1 %cond, label %then, label %else
    then:
      br label %merge
    else:
      br label %merge
    merge:
      %r = phi i32 [ 1, %then ], [ 2, %else ]
      ret void
    }

    LLVM value numbering (reader order: args before local consts):
      ID 0: main function
      ID 1: arg %x
      ID 2: const_zero (i32 0)
      ID 3: const_one  (i32 1)
      ID 4: const_two  (i32 2)
      next_value_id starts at 1 + 1 = 2, +3 consts = 5
      ID 5: icmp %cond
      ID 6: phi %r
    entry: icmp vals=[1, 2, 38] → LHS=arg, RHS=const_zero, result at ID 5
           br_cond: cond=5, vals=[5, 2, 1], false_bb=2, true_bb=1
    merge: phi type=i32, incomings=[(1→3, 1), (2→4, 2)]
           _abs_val values: 3=const_one, 4=const_two
           record: [type_idx, 3, 1, 4, 2]
    """
    M = ModuleBuilder()
    v = M.t_void()
    i32 = M.t_int(32)
    i1 = M.t_int(1)
    M.t_label()
    f_ty = M.t_func(v, [i32])

    const_zero = M.add_constant_int(i32, 0)
    const_one = M.add_constant_int(i32, 1)
    const_two = M.add_constant_int(i32, 2)

    cfg = CFGFunction('main', f_ty)
    cfg.local_consts = [const_zero, const_one, const_two]

    # Args before consts: arg LLVM ID = 1, const_zero=2, const_one=3, const_two=4

    entry = cfg.new_block('entry')
    entry.body = [
        {'op': 'icmp', 'lhs_val': 1, 'rhs_val': ('const', const_zero), 'pred': 'sgt'},
    ]
    # icmp result at ID 5
    entry.term = ('br_cond', 5, 1, 2)

    cfg.new_block('then').term = ('br', 3)
    cfg.new_block('else').term = ('br', 3)

    merge = cfg.new_block('merge')
    merge.body = [
        {'op': 'phi', 'res_type': i32, 'incomings': [(('const', const_one), 1), (('const', const_two), 2)]},
    ]
    merge.term = ('ret', None)

    M.add_function(cfg)
    return M


# ── CFG Validation ──────────────────────────────────────────────────

def validate_cfg(cfg: CFGFunction) -> list[str]:
    errors = []
    n = len(cfg.blocks)
    if n == 0:
        errors.append("function has no blocks")
        return errors
    for i, bb in enumerate(cfg.blocks):
        if bb.term is None:
            errors.append(f"block {i} '{bb.label}' has no terminator")
            continue
        kind = bb.term[0]
        if kind == 'br':
            tgt = bb.term[1]
            if tgt < 0 or tgt >= n:
                errors.append(f"block {i} '{bb.label}': br target {tgt} out of range")
        elif kind == 'br_cond':
            _, _, true_bb, false_bb = bb.term
            for tgt in (true_bb, false_bb):
                if tgt < 0 or tgt >= n:
                    errors.append(f"block {i} '{bb.label}': br_cond target {tgt} out of range")
        for inst in bb.body:
            if inst['op'] == 'phi':
                for val_idx, pred_bb in inst['incomings']:
                    if pred_bb < 0 or pred_bb >= n:
                        errors.append(f"block {i} '{bb.label}': phi predecessor {pred_bb} out of range")
    return errors


# ── Data-driven test framework ───────────────────────────────────────

TEST_CASES = {
    'diamond_const': {
        'build': build_test_diamond_const,
        'checks': ['br i1 true', 'label %1', 'label %2'],
    },
    'diamond_void': {
        'build': build_test_diamond_void,
        'checks': ['br i1 true', 'label %1', 'label %2'],
    },
    'diamond_arg': {
        'build': build_test_diamond_arg,
        'checks': ['icmp sgt i32 %0, 0', 'br i1', 'label %3', 'label %4'],
    },
    'diamond_phi': {
        'build': build_test_diamond_phi,
        'checks': ['phi i32', '[ 1,', '[ 2,'],
    },
    'dx_resource': {
        'build': build_test_dx_resource,
        'checks': ['!dx.resources', '!\"tex0\"', 'i32 0, i32 1, i32 0, i32 0'],
    },
}


def run_all_tests():
    """Run data-driven test suite. Returns (pass_count, fail_count)."""
    passed = 0
    failed = 0
    for name, spec in TEST_CASES.items():
        try:
            M = spec['build']()
            data = M.write()
            r = _sp.run([LLVM_DIS, '-', '-o', 'nul'],
                        input=bytes(data), capture_output=True, timeout=5)
            if r.returncode != 0:
                print(f'  FAIL {name}: llvm-dis exit {r.returncode}')
                print(f'    stderr: {r.stderr.decode()[:300]}')
                failed += 1
                continue
            # Semantic checks on the IR text
            r2 = _sp.run([LLVM_DIS, '-'],
                         input=bytes(data), capture_output=True, timeout=5)
            text = r2.stdout.decode()
            missing = [c for c in spec.get('checks', []) if c not in text]
            if missing:
                print(f'  FAIL {name}: missing patterns: {missing}')
                failed += 1
                continue
            print(f'  PASS {name}  ({len(data)} bytes)')
            passed += 1
        except Exception as e:
            print(f'  FAIL {name}: exception: {e}')
            failed += 1
    return passed, failed


if __name__ == '__main__':
    import sys
    args = sys.argv[1:]

    if '--test' in args or '-t' in args:
        passed, failed = run_all_tests()
        print(f'\n{passed} passed, {failed} failed')
        sys.exit(1 if failed else 0)

    test_name = args[0] if args else 'ret_i32'
    builders = {
        'minimal': build_test_minimal,
        'ret_i32': build_test_ret_i32,
        'alloca': build_test_alloca,
        'diamond_const': build_test_diamond_const,
        'diamond_arg': build_test_diamond_arg,
        'diamond_void': build_test_diamond_void,
        'diamond_phi': build_test_diamond_phi,
        'dx_resource': build_test_dx_resource,
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
