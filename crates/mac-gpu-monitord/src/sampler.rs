use std::time::{Duration, Instant};

use chrono::Utc;
use mac_gpu_monitor_core::Snapshot;
use tokio::sync::watch;

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
use crate::source::MacmonGpuAdapter;

pub fn empty_snapshot(host: &str, driver: Option<String>) -> Snapshot {
    Snapshot {
        timestamp: Utc::now().to_rfc3339(),
        host: host.to_string(),
        driver_version: driver,
        cuda_version: None,
        gpus: Vec::new(),
    }
}

/// Spawn a dedicated OS thread that drives the macmon sampler on a fixed
/// cadence and pushes snapshots through a `watch` channel.
///
/// Uses `std::thread` rather than `tokio::spawn` because:
///   1. `macmon::Sampler::get_metrics` blocks for ~`sample_interval_ms` on its
///      IOReport channel — splitting into 4 sub-samples internally.
///   2. `macmon::Sampler` is not `Send` (it holds a raw `*const __CFDictionary`
///      inside `IOHIDSensors`). Building and using it on a single OS thread
///      keeps the borrow checker — and the runtime — happy.
pub fn spawn_sampler(
    host: String,
    driver_version: Option<String>,
    interval_ms: u64,
    tx: watch::Sender<Snapshot>,
) {
    std::thread::Builder::new()
        .name("gpu-sampler".to_string())
        .spawn(move || {
            #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
            let mut sampler_pair = MacmonGpuAdapter::try_init(interval_ms);

            #[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
            let sampler_pair: Option<()> = None;

            let target = Duration::from_millis(interval_ms.max(200));
            loop {
                let started = Instant::now();

                let snap: Snapshot;
                #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
                {
                    snap = match sampler_pair.as_mut() {
                        Some((adapter, meta)) => {
                            let sample = adapter.sample();
                            Snapshot {
                                timestamp: Utc::now().to_rfc3339(),
                                host: host.clone(),
                                driver_version: driver_version.clone(),
                                cuda_version: None,
                                gpus: vec![sample.into_gpu(meta)],
                            }
                        }
                        None => empty_snapshot(&host, driver_version.clone()),
                    };
                }
                #[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
                {
                    let _ = &sampler_pair;
                    snap = empty_snapshot(&host, driver_version.clone());
                }

                if tx.send(snap).is_err() {
                    tracing::info!("snapshot channel closed; sampler exiting");
                    break;
                }

                // macmon already burned ~interval_ms inside get_metrics; on the
                // fallback path (Intel) we sleep the whole interval ourselves.
                let elapsed = started.elapsed();
                if elapsed < target {
                    std::thread::sleep(target - elapsed);
                }
            }
        })
        .expect("failed to spawn GPU sampler thread");
}
