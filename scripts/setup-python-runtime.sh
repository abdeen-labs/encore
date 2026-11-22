#!/bin/bash
# Sets up the Python runtime the Encore helper runs in, at PythonHelper/.runtime/python (git-ignored):
# a pinned, checksum-verified python-build-standalone CPython plus the latest packages that satisfy
# PythonHelper/requirements.txt. Run once after cloning; run again to pick up newer packages.
set -euo pipefail

PBS_TAG="20261110"
PY_VERSION="3.13.18"
PBS_ASSET="cpython-${PY_VERSION}+${PBS_TAG}-aarch64-apple-darwin-install_only_stripped.tar.gz"
PBS_SHA256="7a2384641584ab9984221fcb0fc9265df465922af71be71410529e2a9c3f0540"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${PBS_ASSET//+/%2B}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/PythonHelper"
RUNTIME_DIR="$HELPER/.runtime"
PYTHON_HOME="$RUNTIME_DIR/python"
PY="$PYTHON_HOME/bin/python3"
REQUIREMENTS="$HELPER/requirements.txt"

[[ "$(uname -m)" == "arm64" ]] || { echo "Encore needs Apple Silicon (arm64)." >&2; exit 1; }

# Never let a contributor's own Python configuration leak into the runtime.
unset PYTHONPATH PYTHONHOME PYTHONSTARTUP PIP_INDEX_URL PIP_EXTRA_INDEX_URL PIP_REQUIRE_VIRTUALENV PIP_CONFIG_FILE
export PIP_DISABLE_PIP_VERSION_CHECK=1 PYTHONNOUSERSITE=1

install_python() {
    mkdir -p "$RUNTIME_DIR/downloads"
    local archive="$RUNTIME_DIR/downloads/$PBS_ASSET"
    if [[ ! -f "$archive" ]] || ! echo "$PBS_SHA256  $archive" | shasum -a 256 -c --status; then
        echo "Downloading $PBS_ASSET…"
        curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error -o "$archive.part" "$PBS_URL"
        mv "$archive.part" "$archive"
    fi
    echo "$PBS_SHA256  $archive" | shasum -a 256 -c --status \
        || { echo "Checksum mismatch for $archive — refusing to use it." >&2; rm -f "$archive"; exit 1; }
    local tmp; tmp="$(mktemp -d "$RUNTIME_DIR/extract.XXXXXX")"
    tar -xzf "$archive" -C "$tmp"
    rm -rf "$PYTHON_HOME"
    mv "$tmp/python" "$PYTHON_HOME"
    rmdir "$tmp"
    # Not needed at runtime; keeps the bundle lean.
    rm -rf "$PYTHON_HOME"/lib/python3.13/{idlelib,tkinter,turtledemo,turtle.py} \
           "$PYTHON_HOME"/lib/{tcl,tk,itcl,thread}* "$PYTHON_HOME"/lib/libtcl* "$PYTHON_HOME"/lib/libtk* \
           "$PYTHON_HOME"/lib/python3.13/lib-dynload/_tkinter* 2>/dev/null || true
}

if [[ ! -x "$PY" ]] || [[ "$("$PY" -c 'import platform; print(platform.python_version())')" != "$PY_VERSION" ]]; then
    install_python
fi

echo "Installing helper dependencies (latest versions satisfying requirements.txt)…"
"$PY" -I -m pip install --quiet --no-cache-dir --upgrade --upgrade-strategy eager --only-binary=:all: -r "$REQUIREMENTS"
"$PY" -I -m pip check
if "$PY" -I -c 'import importlib.util, sys; sys.exit(importlib.util.find_spec("torch") is None)'; then
    echo "warning: torch got installed into the helper runtime; something in requirements.txt pulled it in." >&2
fi
# Record what was installed (the release script prints it; handy when a user reports a problem).
"$PY" -I -m pip freeze --all > "$PYTHON_HOME/encore-installed.txt"
du -sh "$PYTHON_HOME" | awk '{print "Python runtime ready (" $1 "): " $2}'
