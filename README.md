# colab-rust

> Run Rust on Google Colab in ~60 seconds, with prebuilt binaries auto-updated by CI.

[![Build prebuilts](https://github.com/xavierforge/colab-rust/actions/workflows/build-prebuilts.yml/badge.svg)](https://github.com/xavierforge/colab-rust/actions/workflows/build-prebuilts.yml)
[![Open in Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/xavierforge/colab-rust/blob/main/examples/01_hello.ipynb)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

```python
!curl -fsSL -o setup.sh https://raw.githubusercontent.com/xavierforge/colab-rust/main/setup.sh
!bash setup.sh
%load_ext colab_rust
```

```rust
%%rust
println!("Hello from Rust on Colab!");
let sum: i32 = (1..=100).sum();
println!("Sum 1..100 = {sum}");
```

That's the entire setup. State persists across `%%rust` cells, you can mix
freely with Python, and crates work via `:dep`:

```rust
%%rust
:dep rand = "0.8"
use rand::Rng;
rand::thread_rng().gen_range(1..=100)
```

## Why this exists

In [evcxr/evcxr#147](https://github.com/evcxr/evcxr/issues/147) (2024),
the evcxr maintainer wrote:

> "I'd been meaning to try to figure out if the process could be
> streamlined somewhat. e.g. do automatic builds pushed to Google Drive."

This repo implements that idea, with GitHub Actions + GitHub Releases
instead of Google Drive. Stable URLs, no auth, version history,
automatic weekly refresh.

The result: **~11 minute cold setup → ~60 second cold setup**.

## What's different from existing approaches

Most prior approaches (e.g.
[wiseaidev's gist](https://gist.github.com/wiseaidev/2af6bef753d48565d11bcd478728c979),
[korakot's gist](https://gist.github.com/korakot/ae95315ea6a3a3b33ee26203998a59a3))
take one of two paths:

1. **Switch Colab runtime to a "Rust kernel"** via an IPC proxy.
   This is fragile — Colab's IPC proxy for non-Python kernels gets
   stuck on connect more often than it works.

2. **`cargo install evcxr_jupyter` every session.**
   Reliable but slow (~10-11 minutes on Colab's 2-vCPU runners).

`colab-rust` takes a third path:

- **Stay on the Python runtime.** Spin up evcxr as a subprocess via
  `jupyter_client`. A `%%rust` cell magic dispatches code to it.
- **Don't compile on the user's machine.** GitHub Actions builds the
  evcxr_jupyter binary on `ubuntu-22.04` (matching Colab's glibc 2.35)
  and publishes it as a GitHub Release asset.

Benefits:

- **Mix languages** — Python loads data, Rust crunches, Python plots.
- **State persists** across `%%rust` cells, just like a real REPL.
- **Errors are visible** — no IPC layer swallowing stderr.
- **Free Colab works** — no GPU runtime required for CPU-only Rust.

Trade-off: no Rust syntax highlighting in Colab cells, since the
editor sees `%%rust` as a magic line in a Python cell. For full IDE
experience, write a Cargo project in `/content/` and use `!cargo run`.

## How it works

```
┌─────────────────────────────────────────────────────────────┐
│  Google Colab (Python runtime, Ubuntu 22.04, glibc 2.35)    │
│                                                             │
│  ┌────────────────┐         ┌──────────────────────┐        │
│  │ Python kernel  │ ───────▶│ evcxr_jupyter (rust) │        │
│  │ (your cells)   │ ZMQ msg │ subprocess           │        │
│  └────────────────┘ via JC  └──────────────────────┘        │
│         ▲                            │                      │
│         │                            │ compiles & runs      │
│         │                            ▼                      │
│         │                   ┌────────────────┐              │
│         └─── %%rust ──────  │  rustc / cargo │              │
│              cell magic     │  (stable)      │              │
│                             └────────────────┘              │
└─────────────────────────────────────────────────────────────┘
                              ▲
                              │ wget tarball
                              │
              ┌───────────────┴───────────────┐
              │  GitHub Releases              │
              │  prebuilt-latest tag          │
              │  evcxr_jupyter-ubuntu22.04-   │
              │     glibc2.35.tar.gz          │
              └───────────────────────────────┘
                              ▲
                              │ weekly auto-build
                              │
              ┌───────────────┴───────────────┐
              │  GitHub Actions (ubuntu-22.04)│
              │  cargo install --locked       │
              │     evcxr_jupyter             │
              └───────────────────────────────┘
```

## GPU / heavy crates

For crates with large build steps (candle, tch — anything pulling NVCC),
**prefer a Cargo project + `!cargo run` over `:dep`**. evcxr recompiles
the whole sketch on every `:dep` change, which is fine for small libs but
painful for candle (~11 min cold).

Approximate cold-build times on Colab T4:

| Crate                            | Cold build | Notes                                  |
| -------------------------------- | ---------- | -------------------------------------- |
| `cudarc`                         | ~30s       | Pure FFI binding, no CUDA compile      |
| `candle-core` (minimal cuda)     | ~8min      | Compiles essential kernels             |
| `candle-core` (default features) | ~11min     | Compiles GGUF / flash-attn kernels too |
| `tch-rs` (libtorch)              | ~3min      | Downloads prebuilt libtorch            |

Cache your `target/` directory to Google Drive to skip rebuilds on
cold-start sessions:

```python
from google.colab import drive
drive.mount('/content/drive')

# Backup after a clean build
!tar czf /content/drive/MyDrive/colab-rust-cache/target.tar.gz \
    -C /content/myproject target/

# Restore in a fresh session
!tar xzf /content/drive/MyDrive/colab-rust-cache/target.tar.gz \
    -C /content/myproject
```

See [examples/02_candle_gpu.ipynb](examples/02_candle_gpu.ipynb)
(coming in v0.2) for a worked example.

## Tested on

- Colab free tier (Python 3.12, Ubuntu 22.04.5 LTS, glibc 2.35)
- Colab T4 GPU runtime (verified candle CUDA matmul works)
- evcxr_jupyter 0.21.1
- Rust stable (1.80+)

If you encounter `GLIBC_X.YZ not found` errors, your Colab base image has
probably been upgraded — please open an issue. Setup will automatically
fall back to source compilation in that case.

## Roadmap

- [x] v0.1.0 — Prebuilt evcxr_jupyter, `%%rust` magic, weekly auto-build
- [ ] v0.2 — `cudarc` GPU quickstart, `target/` Drive cache helper
- [ ] v0.3 — Ubuntu version auto-detection + matrix build (24.04 readiness)
- [ ] v1.0 — Experimental `cuda-oxide` support (depends on LLVM 21+
      becoming installable in Colab without breaking the kernel)

See [open issues](https://github.com/xavierforge/colab-rust/issues) for
detail.

## Contributing

PRs welcome. The most useful contributions right now:

- Test on Colab Pro / Pro+ runtimes (A100, V100, L4) and report any
  glibc / kernel registration issues.
- Add a Windows / WSL setup guide.
- Examples in your own language — README is currently English-only.

## Credits

- [wiseaidev's evcxr Colab gist](https://gist.github.com/wiseaidev/2af6bef753d48565d11bcd478728c979)
  — the inspiration that demonstrated this could work at all.
- [korakot's gist](https://gist.github.com/korakot/ae95315ea6a3a3b33ee26203998a59a3)
  — the alternative kernel-switching approach.
- [David Lattimore](https://github.com/davidlattimore) and the evcxr
  maintainers — for building the foundational REPL that everything here
  depends on, and for suggesting the auto-build approach in
  [evcxr#147](https://github.com/evcxr/evcxr/issues/147).

## License

MIT — see [LICENSE](LICENSE).
