#!/bin/bash
# Puts the Python runtime and encore_helper into Encore.app/Contents/Resources/{python,PythonHelper},
# pruned, precompiled and (given an identity) signed with the hardened runtime.
#
#   Scripts/embed-python-runtime.sh <path/to/Encore.app> [<signing identity>]
#
# Scripts/release.sh calls it. Debug builds don't need it: they run the repo-local runtime directly
# (PythonRuntime.locate finds it), so incremental Debug builds don't copy anything.
#
# It also works as an Xcode Run Script phase (no arguments; it reads Xcode's environment and skips
# Debug unless ENCORE_EMBED_PYTHON=1), but only with ENABLE_USER_SCRIPT_SANDBOXING=NO on the target:
# the script sandbox allows writing just the declared output paths themselves, not a directory tree.
set -euo pipefail

if [[ $# -ge 1 ]]; then
    ROOT="$(cd "$(dirname "$0")/.." && pwd)"
    RESOURCES="$1/Contents/Resources"
    [[ -d "$RESOURCES" ]] || { echo "error: $1 isn't an app bundle." >&2; exit 1; }
    IDENTITY="${2:-}"
else
    if [[ "${CONFIGURATION:-}" == "Debug" && "${ENCORE_EMBED_PYTHON:-0}" != "1" ]]; then
        echo "Debug build: the app uses PythonHelper/.runtime directly; not embedding."
        exit 0
    fi
    ROOT="$SRCROOT"
    RESOURCES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
    IDENTITY=""
    [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" ]] && IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
fi
SRC_RUNTIME="$ROOT/PythonHelper/.runtime/python"
SRC_HELPER="$ROOT/PythonHelper/encore_helper"

if [[ ! -x "$SRC_RUNTIME/bin/python3" ]]; then
    echo "error: The Python runtime isn't set up. Run Scripts/setup-python-runtime.sh, then build again."
    exit 1
fi

mkdir -p "$RESOURCES/python" "$RESOURCES/PythonHelper/encore_helper"
# Only what runs: no pip, headers, console-script shims (their shebangs point into the repo) or caches.
# Excluded paths are never deleted from the destination, so precompiled __pycache__ survives between builds.
rsync -a --delete --filter='. -' "$SRC_RUNTIME/" "$RESOURCES/python/" <<'EOF'
+ /bin/
+ /bin/python
+ /bin/python3
+ /bin/python3.13
- /bin/*
- /include/
- /share/
- /lib/pkgconfig/
- /lib/python3.13/config-3.13-darwin/
- /lib/python3.13/ensurepip/
- /lib/python3.13/site-packages/pip/
- /lib/python3.13/site-packages/pip-*.dist-info/
- /lib/python3.13/site-packages/**/tests/
- __pycache__/
- *.pyc
EOF
rsync -a --delete --exclude='__pycache__/' --exclude='*.pyc' "$SRC_HELPER/" "$RESOURCES/PythonHelper/encore_helper/"

# The app runs Python with -B and the bundle is read-only, so ship bytecode. Hash-based .pyc files stay
# valid whatever the file dates are after copying, signing and notarising.
"$RESOURCES/python/bin/python3" -I -W ignore -m compileall -q -j 0 --invalidation-mode unchecked-hash \
    "$RESOURCES/python/lib/python3.13" "$RESOURCES/PythonHelper" >/dev/null \
    || echo "warning: some Python files didn't precompile; they'll be compiled in memory at run time."

if [[ -n "$IDENTITY" ]]; then
    # Nested code is signed before the app itself (which the caller, or Xcode, signs afterwards).
    "$ROOT/Scripts/sign-python-runtime.sh" "$RESOURCES/python" "$IDENTITY" \
        $([[ "$IDENTITY" != "-" ]] && echo --timestamp)
fi
