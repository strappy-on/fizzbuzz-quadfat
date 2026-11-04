#!/usr/bin/env bash
#
# report_minos.sh — print the minimum-OS (LC_VERSION_MIN_* / LC_BUILD_VERSION)
# of each built slice. Tolerant: if a slice's min-OS cannot be read it prints
# "  <kind>[<arch>]: <unreadable>" instead of failing.
#
# The modern osxcross vtool/otool cannot read a PPC Mach-O slice, so the ppc
# slice is read with the danupsher-bundled PPC otool
# (toolchain/ppc-tiger-xcompiler/bin/powerpc-apple-darwin8-otool).
#
# Usage:  scripts/report_minos.sh <slices-dir>
# Env:    VTOOL, OTOOL (optional, per-slice overrides below),
#         PPC_XC (directory containing the danupsher toolchain).
#
# This script is the single source of truth for the min-OS report so the
# Makefile `validate` target and the workflow "Per-slice min-OS report" step
# stay consistent.

set -u

SLICES="${1:-build/slices}"

# Per-slice readers: <slice-file> -> "output text or empty"
# A slice that a tool cannot read yields empty; the caller then reports
# "<unreadable>".

read_mac_minos() {
  local slice="$1" out
  if out="$("$VTOOL" -show "$slice" 2>/dev/null | grep -E 'minos|sdk|version' | sed '/^$/d')"; [ -n "$out" ]; then
    printf '%s\n' "$out"
    return
  fi
  if out="$("$OTOOL" -l "$slice" 2>/dev/null | awk '/LC_VERSION_MIN_MACOSX|LC_BUILD_VERSION/{f=1} f&&/version/{print; exit}')"; [ -n "$out" ]; then
    printf '%s\n' "$out"
    return
  fi
  # ppc slice: modern tools cannot read it — use the danupsher PPC otool.
  local ppc_otool=""
  for c in "${PPC_XC:-}" "/toolchain/ppc-tiger-xcompiler" "toolchain/ppc-tiger-xcompiler"; do
    [ -n "$c" ] && [ -x "$c/bin/powerpc-apple-darwin8-otool" ] && ppc_otool="$c/bin/powerpc-apple-darwin8-otool" && break
  done
  if [ -n "$ppc_otool" ]; then
    if out="$("$ppc_otool" -l "$slice" 2>/dev/null | awk '/LC_VERSION_MIN_MACOSX/{f=1} f&&/version/{print; exit}')"; [ -n "$out" ]; then
      printf '%s\n' "$out"
      return
    fi
  fi
  return
}

read_ios_minos() {
  local slice="$1" out
  if out="$("$VTOOL" -show "$slice" 2>/dev/null | grep -E 'minos|sdk|version' | sed '/^$/d')"; [ -n "$out" ]; then
    printf '%s\n' "$out"
    return
  fi
  if out="$("$OTOOL" -l "$slice" 2>/dev/null | awk '/LC_VERSION_MIN_IPHONEOS|LC_BUILD_VERSION/{f=1} f&&/version/{print; exit}')"; [ -n "$out" ]; then
    printf '%s\n' "$out"
    return
  fi
  return
}

emit() {
  # emit <kind> <arch> <slice-file> <reader-func>
  local kind="$1" arch="$2" slice="$3" reader="$4" out
  if out="$($reader "$slice")"; [ -n "$out" ]; then
    printf '  %s[%s]: %s\n' "$kind" "$arch" "$(printf '%s' "$out" | tr '\n' ' ')"
  else
    printf '  %s[%s]: <unreadable>\n' "$kind" "$arch"
  fi
}

echo "Per-slice minimum OS (LC_VERSION_MIN_* / LC_BUILD_VERSION):"
for a in ppc i386 x86_64 arm64; do
  emit mac "$a" "$SLICES/fizzbuzz-$a" read_mac_minos
done
for a in armv7 arm64; do
  emit ios "$a" "$SLICES/fizzbuzz-$a-ios" read_ios_minos
done
