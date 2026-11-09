#!/usr/bin/env bash
# colab-rust setup v0.3.1
# https://github.com/xavierforge/colab-rust
#
# Installs Rust + evcxr_jupyter into a Colab session.
# Tries the prebuilt binary first (built weekly on ubuntu-22.04 / glibc 2.35
# and published to the prebuilt-latest release with a manifest that records
# the evcxr_jupyter version, the rustc it was built with and the tarball's
# sha256; the tarball is checked against it before it is installed), and
# falls back to a source compile.
# Self-bootstraps colab_rust.py so the user only needs one download.
# Idempotent: safe to re-run within the same session.
#
# Pin to a specific version:
#   COLAB_RUST_REF=v0.3.1 bash setup.sh
#
# COLAB_RUST_PREBUILT_BASE_URL overrides where the tarball and its manifest
# are fetched from (CI points it at a file:// directory holding a fresh build).

set -euo pipefail
trap 'echo "❌ setup.sh aborted at line $LINENO: $BASH_COMMAND (exit $?)" >&2' ERR

log() { echo "▶ $*"; }
ok() { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }

REPO="xavierforge/colab-rust"
REF="${COLAB_RUST_REF:-main}"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${REF}"

PREBUILT_UBUNTU="22.04"   # image the prebuilt is compiled on
MIN_GLIBC="2.35"          # what that binary needs; newer is fine
PREBUILT_NAME="evcxr_jupyter-ubuntu22.04-glibc2.35.tar.gz"
PREBUILT_BASE_URL="${COLAB_RUST_PREBUILT_BASE_URL:-https://github.com/${REPO}/releases/download/prebuilt-latest}"
PREBUILT_URL="${PREBUILT_BASE_URL}/${PREBUILT_NAME}"
MANIFEST_URL="${PREBUILT_BASE_URL}/${PREBUILT_NAME%.tar.gz}.manifest.json"

log "colab-rust setup (ref: ${REF})"

# ---------- 0. Sanity check: can the prebuilt run on this image? ----------
ACTUAL_UBUNTU=$(. /etc/os-release && echo "$VERSION_ID")
ACTUAL_GLIBC=$(ldd --version | awk 'NR==1{print $NF}')  # awk reads it all: head -1 can SIGPIPE ldd and trip pipefail
log "Ubuntu $ACTUAL_UBUNTU, glibc $ACTUAL_GLIBC (prebuilt: Ubuntu $PREBUILT_UBUNTU, needs glibc >= $MIN_GLIBC)"
# glibc is backwards compatible, so only an older glibc is a problem.
if [ "$(printf '%s\n' "$MIN_GLIBC" "$ACTUAL_GLIBC" | sort -V | head -1)" != "$MIN_GLIBC" ]; then
    warn "glibc $ACTUAL_GLIBC is older than the $MIN_GLIBC the prebuilt needs."
    warn "Prebuilt binary may fail; will fall back to source compile."
    warn "Please report this at https://github.com/${REPO}/issues"
fi

# ---------- 1. Rust toolchain ----------
# Ask the binary, not PATH: each Colab `!` line is a fresh shell without
# ~/.cargo/env, so `command -v cargo` misses an installed toolchain and a
# re-run would go through rustup-init again. Running `cargo --version` also
# catches a rustup that exists but has no default toolchain (for example one
# installed with `--default-toolchain none`), where the proxy binary is
# present but every cargo call fails.
if ! "$HOME/.cargo/bin/cargo" --version >/dev/null 2>&1; then
    log "Installing Rust (stable, minimal profile)..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs |
        sh -s -- -y --default-toolchain stable --profile minimal --no-modify-path \
            >/dev/null 2>&1
fi
# shellcheck disable=SC1091
source "$HOME/.cargo/env"
RUST_VERSION=$(rustc --version 2>/dev/null | awk '{print $2}')
if [ -z "$RUST_VERSION" ]; then
    echo "❌ rustc is not runnable after setup. Output of 'rustc --version':"
    rustc --version || true
    exit 1
fi
ok "Rust $RUST_VERSION"

# ---------- 2. evcxr_jupyter: try prebuilt, fall back to source ----------
# Check the tarball at $1 against the manifest at $2: schema, sha256 and
# size. Prints a one-line description of the build on success.
verify_prebuilt() {
    python3 - "$1" "$2" "$PREBUILT_NAME" <<'PY'
import hashlib, json, os, sys
tarball, manifest_path, name = sys.argv[1:]
try:
    m = json.load(open(manifest_path))
except Exception as e:
    print(f"manifest unreadable: {e}", file=sys.stderr); sys.exit(1)
problems = []
if m.get("schema_version") != 1: problems.append(f"schema_version {m.get('schema_version')!r} != 1")
entry = m.get("files", {}).get(name)
if not entry:
    problems.append(f"manifest has no entry for {name}")
else:
    if os.path.getsize(tarball) != entry.get("bytes"): problems.append("tarball size differs from manifest")
    digest = hashlib.sha256(open(tarball, "rb").read()).hexdigest()
    if digest != entry.get("sha256"): problems.append("tarball sha256 differs from manifest")
if problems:
    print("; ".join(problems), file=sys.stderr); sys.exit(1)
rustc = next((l.split(": ", 1)[1] for l in m.get("rustc_vV", "").splitlines() if l.startswith("release: ")), "?")
print(f"evcxr_jupyter {m.get('evcxr_jupyter_version', '?')}, built {m.get('created_at', '?')[:10]} on {m.get('built_on', '?')} with rustc {rustc}")
PY
}

if [ ! -x "$HOME/.cargo/bin/evcxr_jupyter" ]; then
    log "Attempting prebuilt evcxr_jupyter download..."
    rm -f /tmp/evcxr.tar.gz /tmp/evcxr.manifest.json
    if curl -fsSL "$PREBUILT_URL" -o /tmp/evcxr.tar.gz 2>/dev/null; then
        PREBUILT_OK=1
        if curl -fsSL "$MANIFEST_URL" -o /tmp/evcxr.manifest.json 2>/dev/null; then
            if BUILD_INFO=$(verify_prebuilt /tmp/evcxr.tar.gz /tmp/evcxr.manifest.json 2>/tmp/evcxr.verify.err); then
                ok "Prebuilt verified against its manifest: $BUILD_INFO"
            else
                warn "Prebuilt rejected: $(cat /tmp/evcxr.verify.err). Falling back to source compile."
                PREBUILT_OK=0
            fi
        else
            warn "No manifest next to the prebuilt; installing it unverified."
        fi
        if [ "$PREBUILT_OK" = 1 ]; then
            mkdir -p "$HOME/.cargo/bin"
            tar xzf /tmp/evcxr.tar.gz -C "$HOME/.cargo/bin"
            chmod +x "$HOME/.cargo/bin/evcxr_jupyter"
            # glibc compatibility check: --help should succeed quickly
            if "$HOME/.cargo/bin/evcxr_jupyter" --help >/dev/null 2>&1; then
                ok "Installed prebuilt evcxr_jupyter"
            else
                warn "Prebuilt binary failed to run, removing and falling back."
                rm -f "$HOME/.cargo/bin/evcxr_jupyter"
            fi
        fi
        rm -f /tmp/evcxr.tar.gz /tmp/evcxr.manifest.json /tmp/evcxr.verify.err
    else
        warn "Prebuilt unavailable, falling back to source compile."
    fi
fi

# Source compile fallback
if ! command -v evcxr_jupyter >/dev/null 2>&1; then
    log "Compiling evcxr_jupyter from source (~10 min, one-time cost)..."
    apt-get install -y -qq \
        cmake pkg-config libssl-dev libzmq3-dev \
        >/dev/null 2>&1
    cargo install --locked evcxr_jupyter >/dev/null 2>&1
fi
ok "evcxr_jupyter at $(which evcxr_jupyter)"

# ---------- 3. Register kernel with Jupyter ----------
evcxr_jupyter --install >/dev/null 2>&1
if jupyter kernelspec list 2>/dev/null | grep -q '^\s*rust\s'; then
    ok "Rust kernel registered with Jupyter"
else
    echo "❌ Rust kernel registration failed."
    echo "   Output of 'jupyter kernelspec list':"
    jupyter kernelspec list
    exit 1
fi

# ---------- 4. Install colab_rust.py magic module ----------
log "Installing colab_rust.py magic module..."
curl -fsSL -o /content/colab_rust.py "${BASE_URL}/colab_rust.py"
CR_VERSION=$(grep -m1 '^__version__' /content/colab_rust.py | cut -d'"' -f2 || true)
ok "colab_rust.py ${CR_VERSION:-unknown} ready at /content/colab_rust.py (ref: ${REF})"

# ---------- 5. Final hint ----------
cat <<'EOF'

🎉 Setup complete.

Next steps in your notebook:

    %load_ext colab_rust

    %%rust
    println!("Hello from Rust on Colab!");

For compile-heavy crates (candle, tch), prefer a Cargo project
with !cargo run over :dep. See examples/ for patterns.
EOF
