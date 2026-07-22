pub const types = @import("types.zig");
pub const node = @import("node.zig");
pub const lower = @import("lower.zig");

pub const TypeId = types.TypeId;
pub const FuncParam = types.FuncParam;
pub const InferredType = types.InferredType;

pub const Expr = node.Expr;
pub const BinOp = node.BinOp;
pub const UnaryOp = node.UnaryOp;
pub const Stmt = node.Stmt;
pub const HirBlock = node.HirBlock;
pub const HirFunction = node.HirFunction;
pub const HirState = node.HirState;
pub const HirModule = node.HirModule;

pub const SemaContext = lower.SemaContext;
pub const lowerProgram = lower.lowerProgram;
