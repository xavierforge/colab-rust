#!/usr/bin/env bash
# colab-rust setup v0.1.0
# https://github.com/xavierforge/colab-rust
#
# Installs Rust + evcxr_jupyter into a Colab session.
# Tries prebuilt binary first, falls back to source compile.
# Idempotent: safe to re-run within the same session.

set -euo pipefail

log() { echo "▶ $*"; }
ok() { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }

REPO="xavierforge/colab-rust"
EXPECTED_UBUNTU="22.04"
PREBUILT_NAME="evcxr_jupyter-ubuntu22.04-glibc2.35.tar.gz"
PREBUILT_URL="https://github.com/${REPO}/releases/download/prebuilt-latest/${PREBUILT_NAME}"

# ---------- 0. Sanity check: are we on the expected Colab base image? ----------
ACTUAL_UBUNTU=$(. /etc/os-release && echo "$VERSION_ID")
if [ "$ACTUAL_UBUNTU" != "$EXPECTED_UBUNTU" ]; then
    warn "Detected Ubuntu $ACTUAL_UBUNTU (expected $EXPECTED_UBUNTU)."
    warn "Prebuilt binary may fail; will fall back to source compile."
    warn "Please report this at https://github.com/${REPO}/issues"
fi

# ---------- 1. Rust toolchain ----------
if ! command -v cargo >/dev/null 2>&1; then
    log "Installing Rust (stable, minimal profile)..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs |
        sh -s -- -y --default-toolchain stable --profile minimal --no-modify-path \
            >/dev/null 2>&1
fi
# shellcheck disable=SC1091
source "$HOME/.cargo/env"
ok "Rust $(rustc --version | awk '{print $2}')"

# ---------- 2. evcxr_jupyter: try prebuilt, fall back to source ----------
if [ ! -x "$HOME/.cargo/bin/evcxr_jupyter" ]; then
    log "Attempting prebuilt evcxr_jupyter download..."
    if curl -fsSL "$PREBUILT_URL" -o /tmp/evcxr.tar.gz 2>/dev/null; then
        mkdir -p "$HOME/.cargo/bin"
        tar xzf /tmp/evcxr.tar.gz -C "$HOME/.cargo/bin"
        chmod +x "$HOME/.cargo/bin/evcxr_jupyter"
        rm /tmp/evcxr.tar.gz

        # glibc compatibility check: --help should succeed quickly
        if "$HOME/.cargo/bin/evcxr_jupyter" --help >/dev/null 2>&1; then
            ok "Installed prebuilt evcxr_jupyter (~60s total)"
        else
            warn "Prebuilt binary failed to run, removing and falling back."
            rm -f "$HOME/.cargo/bin/evcxr_jupyter"
        fi
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

# ---------- 4. Final hint ----------
cat <<'EOF'

🎉 Setup complete.

Next steps in your notebook:

    %load_ext colab_rust

    %%rust
    println!("Hello from Rust on Colab!");

For compile-heavy crates (candle, tch), prefer a Cargo project
with !cargo run over :dep. See examples/ for patterns.
EOF
