# Mac GPU Monitor

Real-time Apple Silicon GPU monitor for macOS. Mirrors the architecture and
JSON schema of [`gpu_monitor`](../gpu_monitor) (Linux/NVIDIA) so the same
Home Assistant package, dashboards, and Swift frontend can decode either
backend.

```
+--------------------+       HTTP/SSE        +-----------------------+
|  mac-gpu-monitord  | <-------------------- |  Mac GPU Monitor.app  |
|  (macmon sampler)  |   /v1/stream JSON     |   (NSStatusItem)      |
+--------------------+                       +-----------------------+
         ^                                            ^
         | IOReport (no sudo)                         | AppKit / CoreGraphics
         v                                            v
    Apple Silicon GPU                          macOS menu bar
```

## Crates

- `mac-gpu-monitor-core` — shared `Snapshot` / `Gpu` / `Memory` / `Process`
  types, serialised with `serde`. Identical wire format to the Linux sibling.
- `mac-gpu-monitord` — backend daemon. Samples Apple Silicon GPU usage,
  power, temperature (when reported by IOReport) and unified-memory pressure
  via [`macmon`](https://crates.io/crates/macmon); holds the latest snapshot
  in a `tokio::sync::watch` channel; serves REST + Server-Sent Events on
  `127.0.0.1:9133`.
- `front-mac/` — Swift Package (Swift + AppKit + CoreGraphics, zero
  third-party deps). Subscribes to `/v1/stream`, renders a per-GPU icon
  (base PNG + side label + donut) into `NSStatusItem`. Per-GPU submenu with
  utilization / power / memory.

## Port assignment

The Mac suite uses the **9133–9136** band, ten above the Linux suite:

| Resource | Linux | Mac  |
|----------|-------|------|
| GPU      | 9123  | 9133 |
| CPU      | 9124  | 9134 |
| RAM      | 9125  | 9135 |
| Disk     | 9126  | 9136 |

A single Mac can therefore run its own backends and SSH-tunnel the Linux
siblings without port collisions.

## Requirements

- macOS 13 or later (Apple Silicon recommended; Intel builds compile but
  report all metrics as `null` — macmon is `aarch64-apple-darwin` only).
- Rust toolchain `stable` ≥ 1.95 (picked up automatically from
  `rust-toolchain.toml`).
- Xcode command-line tools (`swift --version` should print 5.9+).

## Build

```bash
cargo build --release --workspace
cd front-mac && ./scripts/build-app.sh
```

Produces:

- `target/release/mac-gpu-monitord`
- `front-mac/build/Mac GPU Monitor.app`

## Run

```bash
./target/release/mac-gpu-monitord --bind 127.0.0.1 --port 9133
open "front-mac/build/Mac GPU Monitor.app" --args --backend-url http://127.0.0.1:9133
```

### Smoke test

```bash
curl -s http://127.0.0.1:9133/v1/snapshot   # full JSON
curl -N http://127.0.0.1:9133/v1/stream     # SSE — one event per second
"front-mac/build/Mac GPU Monitor.app/Contents/MacOS/mac-gpu-monitor-tray" \
    --dump-icon /tmp/gpu.png                # render one icon to PNG and exit
```

## API

Same schema as [`gpu_monitor`](../gpu_monitor/docs/api.md). On Apple Silicon
the `gpus` array always contains exactly one entry (integrated GPU); on
chips that don't expose a GPU thermal sensor (M1 / M2) `temperature_c` is
`null`.

| Endpoint                          | Purpose                         |
|-----------------------------------|---------------------------------|
| `GET /healthz`                    | liveness                        |
| `GET /v1/info`                    | backend / driver metadata       |
| `GET /v1/snapshot`                | full latest snapshot            |
| `GET /v1/gpus`                    | per-GPU metadata only           |
| `GET /v1/gpus/{idx}`              | one GPU                         |
| `GET /v1/gpus/{idx}/processes`    | process list (empty on macOS)   |
| `GET /v1/stream`                  | SSE — one snapshot per event    |

### Memory model

Apple Silicon uses unified memory: GPU and CPU share the same physical RAM.
The reported `memory.used_bytes` / `memory.total_bytes` therefore reflect
**system-wide RAM pressure**, not a dedicated VRAM footprint (there is
none). The Linux sibling reports dedicated NVIDIA VRAM in the same fields,
so a dashboard built on this schema renders both consistently — just be
aware of the semantic difference when comparing values.

### Per-process GPU usage

Empty on macOS (`processes: []`). Per-process IOAccelerator residency is
only exposed through private SPI that `powermetrics` uses under sudo. Until
that surface is wrapped, the field is honest about being empty rather than
faking it.

## Install autostart

```bash
cd front-mac
./scripts/install-daemon.sh          # backend LaunchAgent (RunAtLoad + KeepAlive)
./scripts/install-launchagent.sh     # tray LaunchAgent
```

Logs land in `~/Library/Logs/mac-gpu-monitord.{out,err}.log` and
`~/Library/Logs/mac-gpu-monitor-tray.{out,err}.log`. Both scripts accept
`uninstall` as a sub-command.

## License

MIT. See [LICENSE](LICENSE).
