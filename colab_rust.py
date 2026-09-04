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
import re
import subprocess
import sys
import threading
import time
from typing import Optional

from IPython.core.magic import Magics, magics_class, cell_magic, line_magic
from IPython.display import Pretty, display
from jupyter_client import KernelManager

__version__ = "0.1.4"

_DEFAULT_TIMEOUT_S = 300  # generous for cold :dep that triggers compile
_INTERRUPT_IDLE_TIMEOUT_S = 5  # how long to let the kernel settle after an interrupt
_PROGRESS_AFTER_QUIET_S = 3  # cells that finish faster than this show no progress line

# evcxr forwards cargo's "Compiling <crate> <version>" lines (and only those)
# to its own stderr while a cell builds.
_CARGO_COMPILING = re.compile(r"^\s*Compiling\s+(\S+)\s+(v\S+)")


class _Progress:
    """One display line, updated in place, tracking a cell's cargo build."""

    def __init__(self, kernel_stderr: "queue.Queue[str]"):
        self._lines = kernel_stderr
        self._t0 = time.monotonic()
        self._crates = 0
        self._latest = ""
        self._handle = None
        self._rendered_at = 0.0

    def _elapsed(self) -> int:
        return int(time.monotonic() - self._t0)

    def poll(self, quiet_for: float):
        """Absorb new stderr lines; show or refresh the line if warranted."""
        while True:
            try:
                line = self._lines.get_nowait()
            except queue.Empty:
                break
            m = _CARGO_COMPILING.match(line)
            if m:
                self._crates += 1
                self._latest = f"{m.group(1)} {m.group(2)}"
        if self._handle is None and not self._crates and quiet_for < _PROGRESS_AFTER_QUIET_S:
            return
        if self._handle is not None and time.monotonic() - self._rendered_at < 1.0:
            return
        if self._latest:
            self._render(f"   Compiling {self._latest}  ({self._crates} crates, {self._elapsed()}s)")
        else:
            self._render(f"   Working ({self._elapsed()}s)")

    def finish(self):
        if self._handle is None:
            return
        if self._crates:
            self._render(f"   Compiled {self._crates} crates in {self._elapsed()}s")
        else:
            # Nothing worth keeping: Colab already shows the cell's run time.
            self._render("")

    def interrupted(self):
        if self._handle is not None:
            self._render(f"   Interrupted after {self._elapsed()}s")

    def _render(self, text: str):
        if self._handle is None:
            self._handle = display(Pretty(text), display_id=True)
        else:
            self._handle.update(Pretty(text))
        self._rendered_at = time.monotonic()


class _RustSession:
    def __init__(self):
        self.km: Optional[KernelManager] = None
        self.kc = None
        self._kernel_stderr: "queue.Queue[str]" = queue.Queue()

    def ensure_started(self):
        if self.km is not None:
            return
        km = KernelManager(kernel_name="rust")
        km.start_kernel(stderr=subprocess.PIPE)
        self._kernel_stderr = queue.Queue()
        threading.Thread(
            target=self._pump_stderr,
            args=(km.provisioner.process.stderr, self._kernel_stderr),
            daemon=True,
        ).start()
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

    @staticmethod
    def _pump_stderr(stream, lines: "queue.Queue[str]"):
        # Must keep draining for the kernel's whole life: once the pipe fills
        # up, evcxr blocks on its next stderr write and the cell hangs.
        try:
            for raw in iter(stream.readline, b""):
                lines.put(raw.decode("utf-8", "replace").rstrip("\n"))
        except (OSError, ValueError):
            pass  # pipe closed underneath us during kernel shutdown

    def execute(self, code: str, timeout: float = _DEFAULT_TIMEOUT_S) -> list:
        """Run one cell and return its outputs in arrival order.

        Each item is a tuple: ("stdout" | "stderr", text) for stream text
        (error tracebacks count as stderr), or ("rich", data, metadata) for
        a mime bundle.
        """
        self.ensure_started()
        msg_id = self.kc.execute(code)
        out: list = []
        progress = _Progress(self._kernel_stderr)
        last_msg_at = time.monotonic()
        try:
            while True:
                try:
                    msg = self.kc.get_iopub_msg(timeout=1.0)
                except queue.Empty:
                    quiet_for = time.monotonic() - last_msg_at
                    if quiet_for > timeout:
                        out.append(("stderr", "\n[colab_rust] timeout waiting for kernel output"))
                        break
                    progress.poll(quiet_for)
                    continue
                # Ignore anything left over from an earlier (e.g. interrupted)
                # cell so it can't leak into this one's output.
                if msg.get("parent_header", {}).get("msg_id") != msg_id:
                    continue
                last_msg_at = time.monotonic()
                progress.poll(0.0)
                mt, content = msg["msg_type"], msg["content"]
                if mt == "stream":
                    out.append((content["name"], content["text"]))
                elif mt in ("execute_result", "display_data"):
                    out.append(("rich", content["data"], content.get("metadata", {})))
                elif mt == "error":
                    out.append(("stderr", "\n".join(content["traceback"]) + "\n"))
                elif mt == "status" and content["execution_state"] == "idle":
                    break
        except KeyboardInterrupt:
            progress.interrupted()
            self._interrupt()
            raise
        progress.finish()
        return out

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


def _render(chunks: list):
    """Replay a cell's outputs in order: stdout and stderr on their own streams,
    rich mime bundles (html, png, ...) handed to the frontend."""
    buf: list = []
    buf_stream = "stdout"

    def flush():
        if buf:
            s = "".join(buf)
            buf.clear()
            target = sys.stdout if buf_stream == "stdout" else sys.stderr
            print(s, end="" if s.endswith("\n") else "\n", file=target, flush=True)

    def text(stream, s):
        nonlocal buf_stream
        if stream != buf_stream:
            flush()
            buf_stream = stream
        buf.append(s)

    for chunk in chunks:
        if chunk[0] != "rich":
            text(chunk[0], chunk[1])
            continue
        data, metadata = chunk[1], chunk[2]
        if set(data) <= {"text/plain"}:
            s = data.get("text/plain", "")
            text("stdout", s if s.endswith("\n") else s + "\n")
            continue
        flush()
        display(data, metadata=metadata, raw=True)
    flush()


@magics_class
class RustMagics(Magics):
    @cell_magic
    def rust(self, line, cell):
        """Execute a Rust cell in the persistent evcxr kernel."""
        _render(_session.execute(cell))

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
