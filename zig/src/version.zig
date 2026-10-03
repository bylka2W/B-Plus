pub const version = "0.4.0";
pub const name = "bpc";

/// Bumped whenever the shape of `bpc capabilities` JSON changes in a way
/// that clients must notice. Clients should refuse unknown major versions.
pub const capabilities_schema = 1;

/// Bumped whenever the shape of `bpc diagnose --format json` changes.
pub const diagnostics_schema = 1;