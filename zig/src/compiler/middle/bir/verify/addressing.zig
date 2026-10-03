const std = @import("std");
const bir = @import("../bir.zig");
const FunctionId = bir.FunctionId;
const BlockId = bir.BlockId;
const ValueId = bir.ValueId;
const TypeId = bir.TypeId;

                                                                                
                                                                          
                                                                       
pub const max_address_depth: u32 = 4;

                                                                         
               
   
                                                                              
                                                                                
pub fn getTypeOfValue(module: *bir.Module, func: *const bir.Function, val: ValueId) ?TypeId {
    if (val == bir.NO_VALUE) return null;
    if (val == 0 or val > func.value_info.items.len) return null;
    const vi = &func.value_info.items[val - 1];
    if (vi.def.block == bir.INVALID_ID) return null;
    if (vi.def.block >= func.blocks.items.len) return null;
    const blk = &func.blocks.items[vi.def.block];
    if (vi.def.idx >= blk.instrs.items.len) return null;
    const inst = &blk.instrs.items[vi.def.idx];
    if (inst.op == .alloca) {
        return module.types.pointerType(inst.ty, .generic) catch null;
    }
    return inst.ty;
}

pub fn isIntType(module: *const bir.Module, tid: TypeId) bool {
    const t = module.types.get(tid);
    return switch (t.kind) {
        .scalar => |sk| switch (sk) {
            .i1, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => true,
            else => false,
        },
        else => false,
    };
}

pub fn isFloatType(module: *const bir.Module, tid: TypeId) bool {
    const t = module.types.get(tid);
    return switch (t.kind) {
        .scalar => |sk| switch (sk) {
            .f16, .bf16, .f32, .f64 => true,
            else => false,
        },
        else => false,
    };
}

pub fn isBoolType(module: *const bir.Module, tid: TypeId) bool {
    const t = module.types.get(tid);
    return switch (t.kind) {
        .scalar => |sk| sk == .i1,
        else => false,
    };
}

pub fn isPtrType(module: *const bir.Module, tid: TypeId) bool {
    if (tid == bir.types.INVALID_TYPE) return false;
    const t = module.types.get(tid);
    return t.kind == .pointer;
}

pub fn isVoidType(module: *const bir.Module, tid: TypeId) bool {
    if (tid == bir.types.INVALID_TYPE) return false;
    const t = module.types.get(tid);
    return t.kind == .void;
}

                                                                              
                                                                  
pub fn getPointeeType(module: *const bir.Module, tid: TypeId) ?TypeId {
    const t = module.types.get(tid);
    return switch (t.kind) {
        .pointer => |p| if (isVoidType(module, p.elem)) null else p.elem,
        else => null,
    };
}

                      
                      
   
                                                                          
                                                                          
                                                                            
                                                                             
                                                                            
                                                
   
                                                       
                                                                         
                                                                               
                                                                              
                                                                         
                                         
                                                                        
                                                                              
   
                                                                      
                                                                       
                                                                             
                                                                    
pub fn isAddressValue(module: *bir.Module, func: *const bir.Function, val: ValueId, depth: u32) bool {
    if (val == bir.NO_VALUE) return false;
    if (val > func.value_info.items.len) return false;
    if (depth > max_address_depth) return true;
    const vi = &func.value_info.items[val - 1];
    if (vi.def.block == bir.INVALID_ID) return true;
    if (vi.def.block >= func.blocks.items.len) return false;
    const blk = &func.blocks.items[vi.def.block];
    if (vi.def.idx >= blk.instrs.items.len) return false;
    const inst = &blk.instrs.items[vi.def.idx];
    switch (inst.op) {
        .alloca, .getelementptr, .ptr_offset, .int_to_ptr, .phi, .select => return true,
        .call, .load => {
            return isPtrType(module, inst.ty);
        },
        .add, .sub => {
            if (inst.operands.len < 2) return false;
            const a_addr = isAddressValue(module, func, inst.operands[0], depth + 1);
            const b_addr = isAddressValue(module, func, inst.operands[1], depth + 1);
            if (a_addr == b_addr) return false;
            const other = if (a_addr) inst.operands[1] else inst.operands[0];
            const other_ty = getTypeOfValue(module, func, other);
            return if (other_ty) |ot| isIntType(module, ot) else true;
        },
        else => return false,
    }
}