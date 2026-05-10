pub mod model;

pub use model::{Gpu, Memory, Process, ProcessKind, Snapshot, Utilization};

// Mac variants live in the 9133-9136 band (Linux band 9123-9126 + 10) so a
// single Mac can simultaneously run its own backends and SSH-tunnel the Linux
// siblings without port collisions. Mapping: gpu→9133, cpu→9134, ram→9135,
// disk→9136 — keep the same trailing digit as the matching Linux port.
pub const DEFAULT_PORT: u16 = 9133;
pub const DEFAULT_BIND: &str = "127.0.0.1";
pub const API_VERSION: &str = "v1";
