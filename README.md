# colab-rust

> Write Rust in Google Colab with a `%%rust` cell magic: setup in **~17 seconds**, works on GPU runtimes. Prebuilt binaries, auto-updated weekly.

_Measured on Colab free tier after the `prebuilt-latest` release is published; last verified 2026-09-01 (16-18s across CPU and T4 runtimes). Source-fallback (if prebuilt is unavailable) takes ~10 minutes._

[![Build prebuilts](https://github.com/xavierforge/colab-rust/actions/workflows/build-prebuilts.yml/badge.svg)](https://github.com/xavierforge/colab-rust/actions/workflows/build-prebuilts.yml)
[![Open in Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/xavierforge/colab-rust/blob/main/examples/01_hello.ipynb)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## Quick Start

```python
!curl -fsSL -o setup.sh https://raw.githubusercontent.com/xavierforge/colab-rust/main/setup.sh
!bash setup.sh
%load_ext colab_rust
```

![Setup completes in ~17 seconds](docs/screenshots/setup.png)

```rust
%%rust
println!("Hello from Rust on Colab!");
let sum: i32 = (1..=100).sum();
println!("Sum 1..100 = {sum}");
```

![%%rust cell magic in action](docs/screenshots/hello.png)

State persists across `%%rust` cells, you can mix freely with Python in the
same notebook, and crates work via `:dep`:

```rust
%%rust
:dep rand = "0.8"
use rand::Rng;
rand::thread_rng().gen_range(1..=100)
```

## How it compares

Two earlier approaches exist:

- **[wiseaidev's gist](https://gist.github.com/wiseaidev/2af6bef753d48565d11bcd478728c979)**
  installs evcxr via Nix and switches the Colab runtime to a Rust kernel.
  Setup takes 1-3 minutes, and the script as published fails on GPU
  runtimes (its `/opt/bin` symlink collides with a directory that exists
  on Colab's GPU image). With that patched, a plain Rust kernel does
  connect on a T4, but the workflow is fragile: the setup cell has to be
  run from the Python runtime, and run twice before the kernel shows up;
  the IPC-proxy "Rust-TCP" variant did not finish connecting in our
  tests; and picking the wrong kernel means starting over. On the plus
  side, a real Rust kernel gets proper Rust syntax highlighting and
  evcxr's native rich output, which a `%%rust` cell magic has to
  reimplement. Because it replaces the Python kernel, you also can't mix
  Python and Rust in one notebook.
- **[korakot's gist](https://gist.github.com/korakot/ae95315ea6a3a3b33ee26203998a59a3)**
  is a kernel-switch variant that's reportedly no longer working on
  current Colab.

`colab-rust` takes a different route:

- **Prebuilt via GitHub Releases, not Nix.** GitHub Actions compiles
  `evcxr_jupyter` once a week on `ubuntu-22.04` (matching Colab's glibc
  2.35) and publishes it as a Release asset; `setup.sh` just downloads it
  (~17s). Compiling from source takes ~11 minutes — that's the cost we
  pre-pay so you don't have to. If the download fails, setup falls back to
  source compilation automatically.
- **A subprocess, not a kernel switch.** You stay on the Python runtime;
  evcxr runs as a subprocess via `jupyter_client`, exposed through a
  `%%rust` magic. You never touch Colab's runtime settings, and if the
  Rust side wedges, `%rust_reset` restarts it in seconds instead of a
  reinstall. You can mix Python and Rust in the same notebook with errors
  staying visible, and it works on **GPU runtimes** the same way.

Benefits in short:

- **Mix languages** — Python loads data, Rust crunches, Python plots.
- **State persists** across `%%rust` cells, like a real REPL.
- **GPU runtimes work** — verified Rust → CUDA execution on Colab's T4
  (a candle matmul lands on `cuda:0`).

Limitations:

- **Output is buffered, not streamed.** evcxr compiles each cell into a
  binary and flushes stdout when it finishes, so a loop like
  `for i in 0..1000 { println!("{i}"); }` prints all at once at the end,
  not line by line.
- **Interrupting costs your variables.** Pressing stop sends a real
  interrupt to the evcxr kernel, which kills the code that is running, so
  the cell actually stops. The price is that evcxr restarts its runtime
  subprocess: everything you defined with `fn`, `struct`, `mod` or `:dep`
  survives, but all variable bindings are gone and have to be re-run.
  Requires an evcxr 0.22.0 prebuilt (anything installed from 2026-09-01
  onwards).
- **Python-based highlighting only.** Colab colors strings and numbers in
  `%%rust` cells but doesn't recognize Rust keywords (`fn`, `let`,
  `match`). For full IDE support, write a Cargo project in `/content/`
  and run it with `!cargo run`.

## Why this exists

In [evcxr/evcxr#147](https://github.com/evcxr/evcxr/issues/147) (2024),
the evcxr maintainer wrote:

> "I'd been meaning to try to figure out if the process could be
> streamlined somewhat. e.g. do automatic builds pushed to Google Drive."

This repo implements that idea, with GitHub Actions + GitHub Releases
instead of Google Drive: stable URLs, no auth, version history, and an
automatic weekly refresh.

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

A worked candle GPU example is coming in v0.2 (see roadmap).

## Tested on

- Colab free tier (Python 3.12, Ubuntu 22.04.5 LTS, glibc 2.35)
- Colab T4 GPU runtime (verified candle CUDA matmul works)
- evcxr_jupyter 0.22.0
- Rust stable (1.98 at last verification; the source fallback needs ≥ 1.95, evcxr's MSRV)

If you hit `GLIBC_X.YZ not found`, your Colab base image has probably been
upgraded — please open an issue. Setup falls back to source compilation in
that case.

## Roadmap

- [x] v0.1.0 — Prebuilt evcxr_jupyter, `%%rust` magic, weekly auto-build
- [ ] v0.2 — `cudarc` GPU quickstart, `target/` Drive cache helper
- [ ] v0.3 — Ubuntu version auto-detection + matrix build (24.04 readiness)
- [ ] v1.0 — Experimental `cuda-oxide` support (depends on LLVM 21+
      becoming installable in Colab without breaking the kernel)

See [open issues](https://github.com/xavierforge/colab-rust/issues) for
detail.

## Contributing

PRs welcome. Most useful right now:

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
- Background: the author's numba CUDA teaching series
  ([part 1](https://xavierforge.dev/posts/numba-cuda-puzzles-1/),
  [part 2](https://xavierforge.dev/posts/numba-cuda-puzzles-2/)), the
  Python-side CUDA material that led to this project.

## License

MIT — see [LICENSE](LICENSE).
