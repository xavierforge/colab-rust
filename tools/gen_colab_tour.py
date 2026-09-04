#!/usr/bin/env python3
"""Generate the Colab edition of evcxr's tour notebook from the upstream one.

Usage: gen_colab_tour.py <evcxr_jupyter_tour.ipynb> <evcxr_jupyter_tour_colab.ipynb>

The upstream tour is kept verbatim except for what Colab needs: its Colab
setup cells are replaced by colab-rust's install, every Rust cell gets a
%%rust line, and the netcat step becomes a Python listener. Outputs are
cleared; run the result on Colab and commit that.
"""
import copy
import json
import sys

COLAB_RUST_REF = "v0.1.4"
REPO = "https://github.com/xavierforge/colab-rust"
SETUP_SH = f"https://raw.githubusercontent.com/xavierforge/colab-rust/{COLAB_RUST_REF}/setup.sh"
BADGE_IMG = "https://colab.research.google.com/assets/colab-badge.svg"
BADGE_URL = ("https://colab.research.google.com/github/evcxr/evcxr/blob/main/"
             "evcxr_jupyter/samples/evcxr_jupyter_tour_colab.ipynb")

SETUP_MD = f"""# Google Colab Rust Setup

[![Open In Colab]({BADGE_IMG})]({BADGE_URL})

This is the Colab edition of the tour. Rather than switching Colab over to a Rust kernel, it stays on the Python kernel and runs evcxr through the `%%rust` cell magic from [colab-rust]({REPO}), a community maintained project. That works on GPU runtimes too, and you can mix Python and Rust cells.

Run the following two cells first. They install Rust and evcxr_jupyter into the runtime, usually well under a minute; if no prebuilt binary matches the runtime, evcxr is compiled from source instead, which takes about ten minutes. This notebook is meant for Google Colab only: don't run the setup cell on a local Jupyter.

Note, Colab highlights `%%rust` cells as Python, so Rust keywords won't be coloured.
"""
SETUP_CODE = f"!curl -fsSL -o setup.sh {SETUP_SH}\n!COLAB_RUST_REF={COLAB_RUST_REF} bash setup.sh\n"
LOAD_CODE = "%load_ext colab_rust\n"
INTRO_ANCHOR = "persist between cells."
INTRO_EXTRA = " Here, each Rust cell starts with `%%rust`. Everything after that line gets sent to evcxr."
DEP_NOTE = (
    "Note, adding a dependency causes everything to be recompiled. Variables whose "
    "types were defined in earlier cells, such as `m` above, can't be kept across "
    "the recompile, so evcxr drops them and tells you. If you want to keep such "
    "variables, add your dependencies first.\n"
)
TOKIO_TAIL = (
    "\n\nNow let's try again with a valid port number. First, make something listen "
    "on port 6543. Since we're still on the Python kernel, we can do that from a "
    "Python cell.\n"
)
LISTENER = """# Listen on port 6543 and hand the one expected connection to a thread.
import socket
import threading

received = []
server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 6543))
server.listen(1)

def accept_one():
    conn, _ = server.accept()
    received.append(conn.recv(1024).decode())
    conn.close()
    server.close()

listener = threading.Thread(target=accept_one, daemon=True)
listener.start()
print("listening on 127.0.0.1:6543")
"""
RECEIVED_MD = "At this point, our listener should have received \"Hello, world!\". Let's check.\n"
RECEIVED_CODE = "listener.join(timeout=5)\nprint(received)\n"


def md(text):
    return {"cell_type": "markdown", "metadata": {}, "source": text}


def code(text):
    return {"cell_type": "code", "metadata": {}, "execution_count": None, "outputs": [], "source": text}


def source(cell):
    return cell["source"] if isinstance(cell["source"], str) else "".join(cell["source"])


def rust(cell):
    c = copy.deepcopy(cell)
    c["source"] = "%%rust\n" + source(cell)
    c["outputs"], c["execution_count"], c["metadata"] = [], None, {}
    return c


def convert(src_cells):
    start = next(i for i, c in enumerate(src_cells)
                 if c["cell_type"] == "markdown" and source(c).startswith("# Tour of the EvCxR Jupyter Kernel"))
    out = [md(SETUP_MD), code(SETUP_CODE), code(LOAD_CODE)]
    for cell in src_cells[start:]:
        text = source(cell)
        if cell["cell_type"] == "code":
            if not text.strip():
                continue
            if text.startswith(":dep image") and "causes everything to be recompiled" not in source(out[-1]):
                out.append(md(DEP_NOTE))
            out.append(rust(cell))
            continue
        if text.startswith("# Tour of the EvCxR Jupyter Kernel"):
            out.append(md(text.replace(INTRO_ANCHOR, INTRO_ANCHOR + INTRO_EXTRA, 1)))
        elif "You might be able to use netcat" in text:
            out.append(md(text.split("\n\nNow let's try again")[0] + TOKIO_TAIL))
            out.append(code(LISTENER))
        elif text.startswith("At this point, netcat"):
            out.append(md(RECEIVED_MD))
            out.append(code(RECEIVED_CODE))
        else:
            out.append(copy.deepcopy(cell))
    return out


def main(src_path, dst_path):
    src = json.load(open(src_path))
    nb = {
        "cells": convert(src["cells"]),
        "metadata": {
            "kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"},
            "language_info": {"name": "python"},
        },
        "nbformat": 4,
        "nbformat_minor": 4,
    }
    with open(dst_path, "w") as f:
        f.write(json.dumps(nb, indent=1, ensure_ascii=False) + "\n")
    kinds = [c["cell_type"] for c in nb["cells"]]
    print(f"wrote {dst_path}: {len(kinds)} cells ({kinds.count('code')} code, {kinds.count('markdown')} markdown)")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
