use mac_gpu_monitor_core::{Gpu, Memory, Utilization};

/// Static metadata read once at startup (chip name + GPU core count). On
/// Apple Silicon we can pull this from macmon's `SocInfo`; on Intel Macs we
/// only have placeholder strings.
#[derive(Clone, Default)]
pub struct GpuStatic {
    pub uuid: String,
    pub name: String,
    pub power_limit_w: Option<f32>,
}

/// One macmon reading reshaped into the shared schema. Only the GPU-relevant
/// fields of `macmon::Metrics` are kept; CPU/ANE numbers are ignored here.
#[derive(Default, Debug, Clone)]
pub struct GpuSample {
    pub temperature_c: Option<u32>,
    pub power_draw_w: Option<f32>,
    pub gpu_percent: u32,
    pub memory_used_bytes: u64,
    pub memory_total_bytes: u64,
}

impl GpuSample {
    pub fn into_gpu(self, meta: &GpuStatic) -> Gpu {
        // Apple Silicon GPUs share memory with the system. We report the
        // unified ram_total/ram_usage from macmon — same number you'd see in
        // Activity Monitor's Memory tab — so memory_percent reflects overall
        // RAM pressure, not a dedicated VRAM footprint (there is none).
        let total = self.memory_total_bytes;
        let used = self.memory_used_bytes.min(total);
        let free = total.saturating_sub(used);
        let memory_percent = if total == 0 {
            0
        } else {
            ((used as f64 / total as f64) * 100.0).round() as u32
        };

        Gpu {
            index: 0,
            uuid: meta.uuid.clone(),
            name: meta.name.clone(),
            temperature_c: self.temperature_c,
            fan_speed_percent: None,
            power_draw_w: self.power_draw_w,
            power_limit_w: meta.power_limit_w,
            utilization: Utilization {
                gpu_percent: self.gpu_percent,
                memory_percent,
            },
            memory: Memory {
                used_bytes: used,
                free_bytes: free,
                total_bytes: total,
            },
            // macOS exposes per-process IOAccelerator residency only through
            // private SPI (powermetrics uses it under sudo). We leave the list
            // empty so the schema stays honest; HA and the Swift tray already
            // tolerate `processes: []`.
            processes: Vec::new(),
        }
    }
}

/// Build a `kernel`-style string used as `driver_version` in the snapshot.
/// On macOS this is the closest analogue to NVIDIA's driver string on Linux
/// — both identify the userland that exposes the GPU to applications.
pub fn read_driver_version() -> Option<String> {
    let kind = sysinfo::System::kernel_version();
    let osname = sysinfo::System::name();
    match (osname, kind) {
        (Some(n), Some(v)) => Some(format!("{n} {v}")),
        (None, Some(v)) => Some(v),
        _ => None,
    }
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
pub struct MacmonGpuAdapter {
    sampler: macmon::Sampler,
    duration_ms: u32,
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
impl MacmonGpuAdapter {
    pub fn try_init(sample_interval_ms: u64) -> Option<(Self, GpuStatic)> {
        match macmon::Sampler::new() {
            Ok(sampler) => {
                let soc = sampler.get_soc_info();
                let chip = if soc.chip_name.is_empty() {
                    "Apple GPU".to_string()
                } else {
                    format!("{} GPU", soc.chip_name)
                };
                let uuid = if soc.gpu_cores > 0 {
                    format!("apple-{}-{}c", soc.chip_name.replace(' ', "-"), soc.gpu_cores)
                } else {
                    "apple-gpu-0".to_string()
                };
                let meta = GpuStatic {
                    uuid,
                    name: chip,
                    power_limit_w: None,
                };
                let duration_ms = sample_interval_ms.clamp(400, 2_000) as u32;
                Some((Self { sampler, duration_ms }, meta))
            }
            Err(err) => {
                tracing::warn!(error = %err, "macmon init failed; GPU metrics will be empty");
                None
            }
        }
    }

    pub fn sample(&mut self) -> GpuSample {
        match self.sampler.get_metrics(self.duration_ms) {
            Ok(m) => GpuSample {
                // Prefer the dedicated GPU sensor when present (Pro/Max/Ultra
                // dies expose it). Plain M1/M2 report `gpu_temp_avg == 0`, so
                // fall back to the CPU thermal sensor: it lives on the same
                // unified SoC die and is the closest physical proxy.
                temperature_c: if m.temp.gpu_temp_avg > 0.0 {
                    Some(m.temp.gpu_temp_avg.round() as u32)
                } else if m.temp.cpu_temp_avg > 0.0 {
                    Some(m.temp.cpu_temp_avg.round() as u32)
                } else {
                    None
                },
                power_draw_w: Some(m.gpu_power),
                // macmon's gpu_usage.1 is a 0..1 ratio already weighted by
                // residency; multiply by 100 to get a percent.
                gpu_percent: (m.gpu_usage.1 * 100.0).clamp(0.0, 100.0).round() as u32,
                memory_used_bytes: m.memory.ram_usage,
                memory_total_bytes: m.memory.ram_total,
            },
            Err(err) => {
                tracing::debug!(error = %err, "macmon sample failed");
                GpuSample::default()
            }
        }
    }
}
