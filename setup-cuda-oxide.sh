#!/usr/bin/env bash
# colab-rust: cuda-oxide on Google Colab T4
# https://github.com/xavierforge/colab-rust
#
# Installs everything needed to compile cuda-oxide GPU kernels inside %%rust
# cells: a minimal CUDA 13 toolkit, clang-21, the nightly cuda-oxide pins, an
# exact cuda-oxide checkout, a prebuilt (or source-built) codegen backend, and
# the colab-cuda-oxide loader crate. setup.sh (Rust, evcxr, the %%rust magic)
# runs first if it has not already.
#
# Nothing is written to /content. Files live under
#   ${XDG_CACHE_HOME:-$HOME/.cache}/colab-rust/cuda-oxide/<commit>/
# with a stable link at /opt/colab-rust/cuda-oxide.
#
# Usage:
#   bash setup-cuda-oxide.sh                 install (prebuilt backend when available)
#   bash setup-cuda-oxide.sh --from-source   always compile cargo-oxide and the backend
#   bash setup-cuda-oxide.sh --verify-only   run the checks and doctor, install nothing
#
# Environment:
#   COLAB_RUST_REF            colab-rust ref for setup.sh and the helper crate (default: main)
#   COLAB_CUDA_OXIDE_REF      full cuda-oxide commit SHA (default: the one validated on T4)
#   COLAB_CUDA_OXIDE_PREBUILT auto | never (default: auto)
#   COLAB_CUDA_SERIES         CUDA apt package series (default: 13-4)
#
# Supported: Google Colab, Ubuntu 24.04, Tesla T4 (sm_75). Anything else fails
# early with a clear message instead of guessing.

set -euo pipefail
# Under set -e a failing command exits silently; say where, so a bare `!` cell
# in Colab does not just fall through to the next line.
trap 'echo "❌ setup-cuda-oxide.sh aborted at line $LINENO: $BASH_COMMAND (exit $?)" >&2' ERR

log() { echo "▶ $*"; }
ok() { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
die() { echo "❌ $*" >&2; exit 1; }

REPO="xavierforge/colab-rust"
REF="${COLAB_RUST_REF:-main}"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${REF}"
OXIDE_REV="${COLAB_CUDA_OXIDE_REF:-6abfaa091e29a6275c1943895bfbc97efa306e98}"
PREBUILT="${COLAB_CUDA_OXIDE_PREBUILT:-auto}"
CUDA_SERIES="${COLAB_CUDA_SERIES:-13-4}"
CLANG_MAJOR=21
HOST_TRIPLE="x86_64-unknown-linux-gnu"
PREBUILT_GLIBC="2.35"

VERIFY_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --from-source) PREBUILT=never ;;
        --verify-only) VERIFY_ONLY=1 ;;
        --help|-h) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $arg (see --help)" ;;
    esac
done
[[ "$OXIDE_REV" =~ ^[0-9a-f]{40}$ ]] || die "COLAB_CUDA_OXIDE_REF must be a full 40-character commit SHA"

CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/colab-rust/cuda-oxide"
INSTALL="${CACHE_ROOT}/${OXIDE_REV}"
LINK="/opt/colab-rust/cuda-oxide"
SRC="${INSTALL}/src"
CUDA_HOME_DIR="/usr/local/cuda-13"
CUDA_PKGS=(cuda-nvcc-${CUDA_SERIES} libnvjitlink-${CUDA_SERIES} libnvjitlink-dev-${CUDA_SERIES} libcurand-dev-${CUDA_SERIES})
CLANG_PKGS=(clang-${CLANG_MAJOR} libclang-common-${CLANG_MAJOR}-dev)
T_START=$SECONDS
elapsed() { echo "$(( SECONDS - T_START ))s"; }

# ---------- 0. Preflight: refuse anything we have not validated ----------
log "cuda-oxide for Google Colab T4 (cuda-oxide ${OXIDE_REV:0:12}, colab-rust ref ${REF})"
[ "$(id -u)" = 0 ] || die "must run as root (Colab runtimes do); the /opt link needs it"
command -v nvidia-smi >/dev/null || die "nvidia-smi not found. Select a GPU runtime: Runtime > Change runtime type > T4 GPU"
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | awk 'NR==1')
DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | awk 'NR==1')
case "$GPU_NAME" in
    *T4*) ok "$GPU_NAME, driver $DRIVER, target sm_75" ;;
    *) die "GPU is '$GPU_NAME'. Only Tesla T4 (sm_75) is validated; other GPUs need their own CUDA_OXIDE_TARGET and testing" ;;
esac
# shellcheck disable=SC1091
OS_ID=$(. /etc/os-release && echo "$VERSION_ID"); OS_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
GLIBC=$(ldd --version | awk 'NR==1{print $NF}')
[ "$OS_ID" = "24.04" ] || die "Ubuntu $OS_ID is not validated (expected 24.04; the NVIDIA apt repo path and package names depend on it)"
ok "Ubuntu $OS_ID, glibc $GLIBC"
grep -rqs developer.download.nvidia.com /etc/apt/sources.list /etc/apt/sources.list.d/ \
    || die "no NVIDIA apt repository configured; the Colab GPU image ships one, this does not look like it"
FREE_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
[ "$FREE_GB" -ge 10 ] || die "only ${FREE_GB} GB free on /; need about 10 GB"

# ---------- 1. Base install: Rust stable + evcxr + %%rust (setup.sh is idempotent, ~2s when present) ----------
if [ "$VERIFY_ONLY" = 0 ]; then
    log "Rust, evcxr and the %%rust magic (setup.sh, ref ${REF})"
    curl -fsSL -o /tmp/colab-rust-setup.sh "${BASE_URL}/setup.sh"
    COLAB_RUST_REF="$REF" bash /tmp/colab-rust-setup.sh | grep -E '^(✅|❌|⚠️)' || die "setup.sh failed"
fi
export PATH="$HOME/.cargo/bin:$PATH"
"$HOME/.cargo/bin/cargo" --version >/dev/null 2>&1 || die "stable cargo is not runnable; run setup.sh first"

mkdir -p "$INSTALL/bin" "$INSTALL/lib" "$INSTALL/helper/src" "$INSTALL/logs"

# ---------- 2. Two jobs in parallel: apt (CUDA + clang) and toolchain (checkout + nightly + prebuilt) ----------
apt_job() {
    local missing=()
    for p in "${CUDA_PKGS[@]}" "${CLANG_PKGS[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
    if [ ${#missing[@]} -eq 0 ]; then echo "all packages already installed"; return 0; fi
    export DEBIAN_FRONTEND=noninteractive
    if [ ! -f /etc/apt/sources.list.d/llvm-${CLANG_MAJOR}.list ]; then
        curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor -o /usr/share/keyrings/llvm-snapshot.gpg
        echo "deb [signed-by=/usr/share/keyrings/llvm-snapshot.gpg] http://apt.llvm.org/${OS_CODENAME}/ llvm-toolchain-${OS_CODENAME}-${CLANG_MAJOR} main" \
            > /etc/apt/sources.list.d/llvm-${CLANG_MAJOR}.list
    fi
    apt-get update -qq
    for p in "${CUDA_PKGS[@]}"; do
        apt-cache show "$p" >/dev/null 2>&1 || { echo "package $p is not in the configured repositories"; return 1; }
    done
    apt-get install -y -qq --no-install-recommends "${missing[@]}"
    echo "installed: ${missing[*]}"
}

toolchain_job() {
    if [ ! -f "$SRC/rust-toolchain.toml" ]; then
        rm -rf "$SRC"; git init -q "$SRC"
        git -C "$SRC" remote add origin https://github.com/NVlabs/cuda-oxide.git
        git -C "$SRC" fetch -q --depth 1 origin "$OXIDE_REV"
        git -C "$SRC" checkout -q FETCH_HEAD
    fi
    echo "cuda-oxide $(git -C "$SRC" rev-parse --short=12 HEAD) $(git -C "$SRC" log -1 --format=%cd --date=short)"
    local channel args=()
    channel=$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$SRC/rust-toolchain.toml")
    for c in $(sed -n '/^components *= *\[/,/\]/p' "$SRC/rust-toolchain.toml" | grep -o '"[^"]*"' | tr -d '"'); do args+=(--component "$c"); done
    rustup toolchain install "$channel" --profile minimal "${args[@]}" >/dev/null 2>&1 \
        || rustup toolchain install "$channel" --profile minimal "${args[@]}"
    echo "$channel" > "$INSTALL/toolchain.txt"
    echo "nightly: $channel"

    if [ "$PREBUILT" = never ]; then echo "prebuilt: skipped (--from-source)"; return 0; fi
    if [ -f "$INSTALL/manifest.json" ]; then echo "prebuilt: already installed"; return 0; fi
    local name="cuda-oxide-${OXIDE_REV:0:12}-${channel}-${HOST_TRIPLE}-glibc${PREBUILT_GLIBC}"
    local url="https://github.com/${REPO}/releases/download/${name}/${name}.tar.gz"
    if ! curl -fsSL -o "$INSTALL/prebuilt.tar.gz" "$url"; then echo "prebuilt: not available at $url"; return 0; fi
    tar -xzf "$INSTALL/prebuilt.tar.gz" -C "$INSTALL" --strip-components=1 "$name/bin" "$name/lib" "$name/manifest.json"
    rm -f "$INSTALL/prebuilt.tar.gz"
    python3 - "$INSTALL" "$OXIDE_REV" "$channel" "$HOST_TRIPLE" "$(rustup run "$channel" rustc -vV)" <<'PY' || { rm -rf "$INSTALL/bin"/* "$INSTALL/lib"/* "$INSTALL/manifest.json"; echo "prebuilt: rejected"; exit 0; }
import hashlib, json, sys
install, rev, channel, host, rustc_vv = sys.argv[1:]
m = json.load(open(f"{install}/manifest.json"))
problems = []
if m.get("cuda_oxide_rev") != rev: problems.append(f"commit {m.get('cuda_oxide_rev')} != {rev}")
if m.get("rust_toolchain") != channel: problems.append(f"toolchain {m.get('rust_toolchain')} != {channel}")
if m.get("host_triple") != host: problems.append(f"host {m.get('host_triple')} != {host}")
if m.get("rustc_vV", "").strip() != rustc_vv.strip(): problems.append("rustc -vV differs from the installed nightly")
for rel, info in m.get("files", {}).items():
    h = hashlib.sha256(open(f"{install}/{rel}", "rb").read()).hexdigest()
    if h != info["sha256"]: problems.append(f"sha256 mismatch for {rel}")
if problems:
    print("prebuilt manifest rejected: " + "; ".join(problems)); sys.exit(1)
print("prebuilt: verified " + ", ".join(m["files"]))
PY
}

if [ "$VERIFY_ONLY" = 0 ]; then
    log "Installing CUDA ${CUDA_SERIES} (minimal), clang-${CLANG_MAJOR}, the pinned nightly, cuda-oxide, and the backend..."
    apt_job >"$INSTALL/logs/apt.log" 2>&1 & APT_PID=$!
    toolchain_job >"$INSTALL/logs/toolchain.log" 2>&1 & TC_PID=$!
    APT_ST=running; TC_ST=running
    while [ "$APT_ST" = running ] || [ "$TC_ST" = running ]; do
        [ "$APT_ST" = running ] && ! kill -0 "$APT_PID" 2>/dev/null && { wait "$APT_PID" && APT_ST=done || APT_ST=failed; }
        [ "$TC_ST" = running ] && ! kill -0 "$TC_PID" 2>/dev/null && { wait "$TC_PID" && TC_ST=done || TC_ST=failed; }
        printf '\r   %s  apt: %s  toolchain: %s   ' "$(elapsed)" "$APT_ST" "$TC_ST"
        sleep 2
    done
    printf '\r%*s\r' 60 ''
    [ "$APT_ST" = done ] || { tail -20 "$INSTALL/logs/apt.log"; die "package installation failed (full log: $INSTALL/logs/apt.log)"; }
    [ "$TC_ST" = done ] || { tail -20 "$INSTALL/logs/toolchain.log"; die "toolchain step failed (full log: $INSTALL/logs/toolchain.log)"; }
    ok "packages: $(tail -1 "$INSTALL/logs/apt.log")"
    grep -E '^(cuda-oxide|nightly|prebuilt)' "$INSTALL/logs/toolchain.log" | sed 's/^/   /'
fi

CHANNEL=$(cat "$INSTALL/toolchain.txt" 2>/dev/null || true)
[ -n "$CHANNEL" ] || die "no toolchain recorded at $INSTALL/toolchain.txt; run without --verify-only first"
ln -sfn "$(ls -d /usr/local/cuda-13.* | sort -V | tail -1)" "$CUDA_HOME_DIR"
export CUDA_HOME="$CUDA_HOME_DIR" CUDA_TOOLKIT_PATH="$CUDA_HOME_DIR" CUDA_OXIDE_TARGET=sm_75

# ---------- 3. Backend: prebuilt already in place, else build from the checkout ----------
if [ "$VERIFY_ONLY" = 0 ] && [ ! -x "$INSTALL/bin/cargo-oxide" ]; then
    log "Building cargo-oxide and the codegen backend from source (about 5 minutes)..."
    (cd "$SRC" && cargo oxide setup 2>&1 | grep -E 'Finished|Backend built' | sed 's/^/   /')
    cp "$SRC/target/debug/cargo-oxide" "$INSTALL/bin/cargo-oxide"
    cp "$SRC"/crates/rustc-codegen-cuda/target/*/debug/librustc_codegen_cuda.so "$INSTALL/lib/librustc_codegen_cuda.so"
    echo '{"source": "built on this runtime by cargo oxide setup"}' > "$INSTALL/manifest.json"
fi

# ---------- 4. Helper crate and stable link ----------
if [ "$VERIFY_ONLY" = 0 ]; then
    curl -fsSL -o "$INSTALL/helper/Cargo.toml" "${BASE_URL}/crates/colab-cuda-oxide/Cargo.toml"
    curl -fsSL -o "$INSTALL/helper/src/lib.rs" "${BASE_URL}/crates/colab-cuda-oxide/src/lib.rs"
    mkdir -p "$(dirname "$LINK")" && ln -sfn "$INSTALL" "$LINK"
fi

# ---------- 5. Verify: files, clang, doctor ----------
BACKEND="$LINK/lib/librustc_codegen_cuda.so"
for f in include/cuda.h include/curand.h bin/nvcc nvvm/lib64/libnvvm.so lib64/libnvJitLink.so nvvm/libdevice/libdevice.10.bc; do
    [ -e "$CUDA_HOME_DIR/$f" ] || die "missing $CUDA_HOME_DIR/$f"
done
ok "CUDA $("$CUDA_HOME_DIR/bin/nvcc" --version | sed -n 's/.*release \([0-9.]*\),.*/\1/p'): cuda.h, curand.h, nvcc, libNVVM, nvJitLink, libdevice"
[ -r "$(clang-${CLANG_MAJOR} -print-resource-dir)/include/stddef.h" ] || die "clang-${CLANG_MAJOR} resource headers missing (libclang-common-${CLANG_MAJOR}-dev)"
update-alternatives --install /usr/bin/clang clang /usr/bin/clang-${CLANG_MAJOR} 100 >/dev/null
update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-${CLANG_MAJOR} 100 >/dev/null
ok "clang-${CLANG_MAJOR} $(clang-${CLANG_MAJOR} --version | sed -n '1s/.*version \([0-9.]*\).*/\1/p')"
[ -x "$LINK/bin/cargo-oxide" ] && [ -f "$BACKEND" ] || die "backend not installed under $LINK"
# The backend shells out to `rustc --print sysroot` to find llvm-tools' llc.
# evcxr calls the nightly's rustc by absolute path, so that lookup hits the
# stable proxy on PATH and misses. Pin llc explicitly through a stable link.
NIGHTLY_LLC="$(rustup run "$CHANNEL" rustc --print sysroot)/lib/rustlib/${HOST_TRIPLE}/bin/llc"
[ -x "$NIGHTLY_LLC" ] || die "llc missing from the nightly's llvm-tools component: $NIGHTLY_LLC"
ln -sfn "$NIGHTLY_LLC" "$INSTALL/bin/llc"
ok "llc: $("$INSTALL/bin/llc" --version | sed -n 's/^ *LLVM version //p' | awk 'NR==1') (nightly llvm-tools)"
[ -f "$LINK/helper/src/lib.rs" ] || die "helper crate missing under $LINK/helper"
# Run doctor from the checkout (it wants rust-toolchain.toml there) but call
# the installed binary directly: inside the checkout `cargo oxide` is a
# workspace alias that would rebuild cargo-oxide from source.
( cd "$SRC" && CUDA_OXIDE_BACKEND="$BACKEND" "$LINK/bin/cargo-oxide" doctor >"$INSTALL/logs/doctor.log" 2>&1 ) \
    || { cat "$INSTALL/logs/doctor.log"; die "cargo oxide doctor failed"; }
ok "cargo oxide doctor: $(grep -c '✓' "$INSTALL/logs/doctor.log") checks passed"
ok "cuda-oxide ready in $(elapsed) at $LINK"

cat <<EOT

Next: run the notebook's "Configure %%rust" cell. It needs these values:

    :toolchain ${CHANNEL}
    :build_env RUSTFLAGS=-Cprefer-dynamic -Zcodegen-backend=${BACKEND} -Zalways-encode-mir -Csymbol-mangling-version=v0
    :build_env CUDA_OXIDE_LLC=${LINK}/bin/llc
    :dep cuda-device = { path = "${LINK}/src/crates/cuda-device" }
    :dep cuda-host = { path = "${LINK}/src/crates/cuda-host" }
    :dep colab-cuda-oxide = { path = "${LINK}/helper" }
EOT
