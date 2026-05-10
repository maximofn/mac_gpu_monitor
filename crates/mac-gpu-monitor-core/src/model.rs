use serde::{Deserialize, Serialize};

// Schema mirrors gpu_monitor (Linux) verbatim so the same Home Assistant
// package and Swift frontend can decode either backend. Apple Silicon only
// has a single integrated GPU, so `gpus` always contains exactly one entry;
// on Linux it can have several NVIDIA devices.

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Snapshot {
    pub timestamp: String,
    pub host: String,
    pub driver_version: Option<String>,
    pub cuda_version: Option<String>,
    pub gpus: Vec<Gpu>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Gpu {
    pub index: u32,
    pub uuid: String,
    pub name: String,
    pub temperature_c: Option<u32>,
    pub fan_speed_percent: Option<u32>,
    pub power_draw_w: Option<f32>,
    pub power_limit_w: Option<f32>,
    pub utilization: Utilization,
    pub memory: Memory,
    pub processes: Vec<Process>,
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct Utilization {
    pub gpu_percent: u32,
    pub memory_percent: u32,
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct Memory {
    pub used_bytes: u64,
    pub free_bytes: u64,
    pub total_bytes: u64,
}

impl Memory {
    pub fn used_percent(&self) -> f32 {
        if self.total_bytes == 0 {
            0.0
        } else {
            (self.used_bytes as f32 / self.total_bytes as f32) * 100.0
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Process {
    pub pid: u32,
    pub name: String,
    pub used_memory_bytes: u64,
    #[serde(rename = "type")]
    pub kind: ProcessKind,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ProcessKind {
    Compute,
    Graphics,
    Mixed,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_roundtrips_through_json() {
        let snapshot = Snapshot {
            timestamp: "2026-05-10T18:00:00Z".to_string(),
            host: "mac".to_string(),
            driver_version: Some("Darwin 25.3.0".to_string()),
            cuda_version: None,
            gpus: vec![Gpu {
                index: 0,
                uuid: "apple-gpu-0".to_string(),
                name: "Apple M1 Pro GPU".to_string(),
                temperature_c: Some(45),
                fan_speed_percent: None,
                power_draw_w: Some(2.5),
                power_limit_w: None,
                utilization: Utilization {
                    gpu_percent: 25,
                    memory_percent: 60,
                },
                memory: Memory {
                    used_bytes: 10 * 1024 * 1024 * 1024,
                    free_bytes: 6 * 1024 * 1024 * 1024,
                    total_bytes: 16 * 1024 * 1024 * 1024,
                },
                processes: vec![],
            }],
        };
        let json = serde_json::to_string(&snapshot).unwrap();
        let back: Snapshot = serde_json::from_str(&json).unwrap();
        assert_eq!(snapshot, back);
    }

    #[test]
    fn used_percent_handles_zero_total() {
        let m = Memory::default();
        assert_eq!(m.used_percent(), 0.0);
    }

    #[test]
    fn used_percent_computes_correctly() {
        let m = Memory {
            used_bytes: 50,
            free_bytes: 50,
            total_bytes: 100,
        };
        assert!((m.used_percent() - 50.0).abs() < f32::EPSILON);
    }
}
