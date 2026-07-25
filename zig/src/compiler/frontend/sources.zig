pub const source_manager = @import("source/source_manager.zig");
pub const location = @import("source/location/span.zig");

pub const SourceManager = source_manager.SourceManager;
pub const SourceFile = source_manager.SourceFile;
pub const SourceSpan = location.SourceSpan;
pub const SourceLocation = location.Position;
pub const FileId = location.FileId;
