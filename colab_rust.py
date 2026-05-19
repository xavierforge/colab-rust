"""
colab_rust — IPython extension giving Colab notebooks a %%rust cell magic
backed by a persistent evcxr_jupyter kernel.

Usage:
    %load_ext colab_rust

    %%rust
    let x: i32 = (1..=100).sum();
    println!("{}", x);

    %%rust
    // state persists across cells
    let v = vec![1, 2, 3];
    v.iter().sum::<i32>()

The Rust kernel runs as a subprocess via jupyter_client. Variables and
:dep declarations persist for the lifetime of the Colab session (or
until you call %rust_reset).

Repository: https://github.com/xavierforge/colab-rust
"""

from __future__ import annotations

import queue
import atexit
from typing import Optional

from IPython.core.magic import Magics, magics_class, cell_magic, line_magic
from jupyter_client import KernelManager


_DEFAULT_TIMEOUT_S = 300  # generous for cold :dep that triggers compile


class _RustSession:
    def __init__(self):
        self.km: Optional[KernelManager] = None
        self.kc = None

    def ensure_started(self):
        if self.km is not None:
            return
        km = KernelManager(kernel_name="rust")
        km.start_kernel()
        kc = km.client()
        kc.start_channels()
        kc.wait_for_ready(timeout=60)
        self.km, self.kc = km, kc

    def execute(self, code: str, timeout: float = _DEFAULT_TIMEOUT_S) -> str:
        self.ensure_started()
        self.kc.execute(code)
        out = []
        while True:
            try:
                msg = self.kc.get_iopub_msg(timeout=timeout)
            except queue.Empty:
                out.append("\n[colab_rust] timeout waiting for kernel output")
                break
            mt, content = msg["msg_type"], msg["content"]
            if mt == "stream":
                out.append(content["text"])
            elif mt in ("execute_result", "display_data"):
                out.append(content["data"].get("text/plain", ""))
                if not out[-1].endswith("\n"):
                    out.append("\n")
            elif mt == "error":
                out.append("\n".join(content["traceback"]) + "\n")
            elif mt == "status" and content["execution_state"] == "idle":
                break
        return "".join(out)

    def reset(self):
        if self.km is not None:
            try:
                self.kc.stop_channels()
                self.km.shutdown_kernel(now=True)
            except Exception:
                pass
        self.km = self.kc = None


_session = _RustSession()
atexit.register(_session.reset)


@magics_class
class RustMagics(Magics):
    @cell_magic
    def rust(self, line, cell):
        """Execute a Rust cell in the persistent evcxr kernel."""
        output = _session.execute(cell)
        if output:
            print(output, end="" if output.endswith("\n") else "\n")

    @line_magic
    def rust_reset(self, line):
        """Tear down the Rust kernel; next %%rust call will spin up fresh."""
        _session.reset()
        print("✅ Rust kernel reset")


def load_ipython_extension(ipython):
    ipython.register_magics(RustMagics)
    print("✅ colab_rust loaded — use %%rust in any cell")


def unload_ipython_extension(ipython):
    _session.reset()
