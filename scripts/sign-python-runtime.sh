#!/bin/bash
# Signs every Mach-O file under a directory (the embedded Python runtime) with the hardened runtime:
# libraries and extension modules first, executables last.
#
#   scripts/sign-python-runtime.sh <dir> <identity> [--timestamp] [--entitlements <plist>]
#
# The Python executable needs no entitlements as long as everything it loads is signed by the same
# team (tested: MLX on the GPU, every helper job, under the hardened runtime with library validation).
set -euo pipefail

dir="$1"; identity="$2"; shift 2
timestamp="--timestamp=none"; entitlements=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --timestamp) timestamp="--timestamp"; shift ;;
        --entitlements) entitlements=(--entitlements "$2"); shift 2 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
done

list="$(mktemp)"; trap 'rm -f "$list"' EXIT
# Candidates: anything that could be code. `file` decides.
find "$dir" -type f \( -name "*.so" -o -name "*.dylib" -o -perm -u+x \) -print0 \
    | xargs -0 file --no-pad --separator '|' \
    | awk '/Mach-O/ { p = $0; sub(/ \(for architecture .*$/, "", p); sub(/\|.*$/, "", p); print p }' \
    | sort -u > "$list"

libraries="$(grep -v '/bin/' "$list" || true)"
executables="$(grep '/bin/' "$list" || true)"
count=$(wc -l < "$list" | tr -d ' ')
echo "Signing $count Mach-O files in $dir as \"$identity\" ($timestamp)…"

sign() { tr '\n' '\0' | xargs -0 -n 1 -P 8 codesign --force --sign "$identity" --options runtime $timestamp ${entitlements[@]+"${entitlements[@]}"} 2>&1 | grep -v "replacing existing signature" || true; }
# One file alone first: the Keychain asks once to let codesign use the key, instead of once per parallel signer.
first="$(head -n 1 "$list")"
if [[ -n "$first" ]]; then
    codesign --force --sign "$identity" --options runtime $timestamp ${entitlements[@]+"${entitlements[@]}"} "$first" 2>&1 \
        | grep -v "replacing existing signature" || true
fi
if [[ -n "$libraries" ]]; then printf '%s\n' "$libraries" | sign; fi
if [[ -n "$executables" ]]; then printf '%s\n' "$executables" | sign; fi

# Verify everything we signed.
bad=0
while IFS= read -r f; do
    codesign --verify --strict "$f" 2>/dev/null || { echo "verification failed: $f" >&2; bad=1; }
done < "$list"
exit $bad
