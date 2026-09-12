#!/bin/bash
# sweep-10s.sh — drive gpu_freq_ctl across power levels using the repo's own
# documented methodology: `cap N --confirm` (saves the original cap once, sets
# the cap, burns in 10 s of sustained GPU load, then reads powermetrics for the
# settled frequency), followed by `status`. Writes a table plus a raw transcript,
# then restores the original cap.
#
# Usage (root is required for the AGX writes):
#     cd <checkout> && sudo bash sweep-10s.sh
#     sudo CAPS="20 10 5" bash sweep-10s.sh        # subset, quicker
#     sudo LOG=/tmp/sweep.txt bash sweep-10s.sh    # custom log path
#
# Ctrl-C at any point is safe: the trap restores the original power cap on exit.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$DIR/gpu_freq_ctl"
CAPS="${CAPS:-20 15 10 5 3 2 1}"

if [ ! -x "$BIN" ]; then
  echo "error: $BIN not found — build it first:" >&2
  echo "  xcrun clang -framework IOKit -framework Foundation -framework Metal -O2 -o gpu_freq_ctl gpu_freq_ctl.m" >&2
  exit 1
fi
if [ "$(id -u)" != "0" ]; then
  echo "warning: not running as root — the cap/status calls will fail" >&2
fi

# Log into the repo owner's home even under a root prompt: `sudo` keeps HOME, but
# `do shell script ... with administrator privileges` does not (it would write to
# /var/root instead).
OWNER="$(stat -f%Su "$DIR" 2>/dev/null || echo "${SUDO_USER:-$USER}")"
OWNER_HOME="$(eval echo "~$OWNER" 2>/dev/null || echo "$HOME")"
LOG="${LOG:-$OWNER_HOME/gpu-dvfs-sweep.txt}"
RAW="$LOG.raw"

restore() { "$BIN" uncap >/dev/null 2>&1 || true; }
trap restore EXIT INT TERM

{
  echo "# GPU power-cap sweep — $(sysctl -n machdep.cpu.brand_string) / $(sysctl -n hw.model)"
  echo "# $(date '+%Y-%m-%d %H:%M:%S %Z')   caps: $CAPS"
  echo "# method: cap N --confirm (10 s burn-in) then status"
  echo
  printf "%-7s %-11s %-11s %-13s %s\n" "cap_W" "GFLOPS" "actual_mW" "settled_MHz" "path"
} > "$LOG"
: > "$RAW"

path="AGX"
for w in $CAPS; do
  out="$("$BIN" cap "$w" --confirm 2>&1)"
  { echo "### cap $w"; echo "$out"; echo; } >> "$RAW"

  case "$out" in *"CLPC fallback"*) path="CLPC" ;; esac
  gf="$(echo "$out" | grep -oE '[0-9.]+ GFLOPS' | head -1)"
  mw="$(echo "$out" | grep -oE 'power: [0-9]+ mW' | grep -oE '[0-9]+' | head -1)"
  mhz="$(echo "$out" | grep -E 'Frequency:' | grep -oE '[0-9]+' | head -1)"
  printf "%-7s %-11s %-11s %-13s %s\n" \
         "$w" "${gf:-?}" "${mw:-?}" "${mhz:-?}" "$path" | tee -a "$LOG"
done

{
  echo
  echo "--- restore (uncap) ---"
  "$BIN" uncap
  echo "--- status after restore ---"
  "$BIN" status
  echo "--- info after restore ---"
  "$BIN" info
} >> "$LOG" 2>&1
echo "log written: $LOG"
