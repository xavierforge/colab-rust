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

__version__ = "0.1.2"

_DEFAULT_TIMEOUT_S = 300  # generous for cold :dep that triggers compile
_INTERRUPT_IDLE_TIMEOUT_S = 5  # how long to let the kernel settle after an interrupt


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
        try:
            kc.start_channels()
            kc.wait_for_ready(timeout=60)
        except BaseException as exc:
            # The kernel process is already alive at this point; shut it
            # down so an interrupted startup doesn't leak an orphan kernel.
            try:
                kc.stop_channels()
            except Exception:
                pass
            try:
                km.shutdown_kernel(now=True)
            except Exception:
                pass
            if isinstance(exc, KeyboardInterrupt):
                print(
                    "[colab_rust] interrupted during Rust kernel startup; "
                    "nothing ran. Just run the cell again."
                )
            raise
        self.km, self.kc = km, kc

    def execute(self, code: str, timeout: float = _DEFAULT_TIMEOUT_S) -> str:
        self.ensure_started()
        msg_id = self.kc.execute(code)
        out = []
        try:
            while True:
                try:
                    msg = self.kc.get_iopub_msg(timeout=timeout)
                except queue.Empty:
                    out.append("\n[colab_rust] timeout waiting for kernel output")
                    break
                # Ignore anything left over from an earlier (e.g. interrupted)
                # cell so it can't leak into this one's output.
                if msg.get("parent_header", {}).get("msg_id") != msg_id:
                    continue
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
        except KeyboardInterrupt:
            self._interrupt()
            raise
        return "".join(out)

    def _interrupt(self):
        """Stop the code the Rust kernel is currently running.

        The evcxr kernel spec declares interrupt_mode="message", so this sends
        an interrupt_request on the control channel; evcxr answers it by
        killing the runtime subprocess executing the cell.
        """
        print("[colab_rust] interrupt requested; stopping the Rust kernel...")
        try:
            self.km.interrupt_kernel()
        except Exception as exc:  # kernel already gone, control channel dead, ...
            print(f"[colab_rust] could not interrupt the Rust kernel: {exc}")
            return
        try:
            if not self._wait_for_idle():
                print(
                    "[colab_rust] interrupt sent, but the kernel did not report "
                    "idle (likely mid-compile; the compile finishes in the "
                    "background and the next cell may wait for it)"
                )
        except KeyboardInterrupt:
            # A second stop press while we were waiting for idle; the
            # interrupt was already delivered, so just finish the notice.
            pass
        print(
            "[colab_rust] Interrupted. Variables were reset; "
            "items (fn/struct/:dep) are kept."
        )

    def _wait_for_idle(self, timeout: float = _INTERRUPT_IDLE_TIMEOUT_S) -> bool:
        """Drain iopub until the kernel says idle. Returns False on timeout.

        Deliberately unfiltered by msg_id: the idle that follows an interrupt
        may be parented to the interrupt_request rather than to our
        execute_request.
        """
        while True:
            try:
                msg = self.kc.get_iopub_msg(timeout=timeout)
            except queue.Empty:
                return False
            if (
                msg["msg_type"] == "status"
                and msg["content"]["execution_state"] == "idle"
            ):
                return True

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
    print(f"✅ colab_rust {__version__} loaded — use %%rust in any cell")


def unload_ipython_extension(ipython):
    _session.reset()
