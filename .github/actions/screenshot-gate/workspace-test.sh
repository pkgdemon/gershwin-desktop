#!/bin/sh
# workspace-test.sh — verify the login actually reached the Gershwin DESKTOP
# (not just the greeter) and that it painted a REAL, usable desktop, then
# capture it to docs/desktop.png.
#
# GATING: exits 1 unless a single frame shows BOTH desktop landmarks, via OCR:
#   - the "System Disk" desktop icon label, and
#   - the "Workspace" global menu (GWorkspace is the frontmost app after login).
# The earlier boot-test only proves the graphical GREETER painted; a login that
# authenticates but whose session can't start drops straight back to the greeter,
# which is ALSO high-colour — so a unique-colour count alone can pass on a
# non-desktop (exactly what slipped through while /Local/Users/admin was getting
# clobbered). Requiring both landmarks confirms the session genuinely came up.
# Colour count is kept only as a cheap "screen advanced past flat grey" progress
# signal in the log. Runs from outside the guest via the QEMU monitor.
set -u

SOCK=tests/mon.sock
DEADLINE_SECS=120          # max wait for the desktop to come up post-login
mon() { printf '%s\n' "$*" | socat -t2 - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1 || true; }
colors() { magick identify -format '%k' "$1" 2>/dev/null || identify -format '%k' "$1" 2>/dev/null || echo 0; }

# OCR one frame. Upscale 2x first — the global menu-bar text is small at the
# guest's VGA resolution and tesseract reads it far more reliably enlarged.
ocr() {
    command -v tesseract >/dev/null 2>&1 || return 1
    magick "$1" -resize 200% "$1.png" 2>/dev/null || convert "$1" -resize 200% "$1.png" 2>/dev/null || return 1
    tesseract "$1.png" - 2>/dev/null | tr -d '\r'
}

echo "[workspace-test] waiting for the DESKTOP — 'System Disk' icon AND 'Workspace' menu (<= ${DEADLINE_SECS}s)"
END=$(( $(date +%s) + DEADLINE_SECS ))
i=0
found=0
best=""
saw_disk=0
saw_ws=0
text=""
while [ "$(date +%s)" -lt "$END" ]; do
    i=$((i + 1))
    f="tests/desktop-$(printf '%03d' "$i").ppm"
    mon "screendump $f"
    sleep 1
    [ -f "$f" ] || { sleep 3; continue; }
    [ -s "$f" ] && best="$f"
    c=$(colors "$f")
    text=$(ocr "$f")
    d=0; w=0
    printf '%s' "$text" | grep -qiE 'System[[:space:]]*Disk' && { d=1; saw_disk=1; }
    printf '%s' "$text" | grep -qiE 'Workspace'              && { w=1; saw_ws=1; }
    echo "[workspace-test] frame $i: ${c} colours; System Disk=$d Workspace=$w"
    if [ "$d" -eq 1 ] && [ "$w" -eq 1 ]; then
        echo "[workspace-test] PASS: desktop is up — both 'System Disk' and 'Workspace' present (frame $i)"
        cp "$f" tests/desktop.ppm 2>/dev/null || true
        found=1
        break
    fi
    sleep 3
done

# Always leave a screenshot artifact for inspection — even on failure, so the
# boot-artifacts upload shows what was actually on screen (greeter? blank? a
# desktop missing one landmark?).
if [ "$found" -ne 1 ]; then
    if [ -n "$best" ]; then cp "$best" tests/desktop.ppm 2>/dev/null || true
    else mon "screendump tests/desktop.ppm"; fi
fi
sleep 1
mkdir -p docs
magick tests/desktop.ppm docs/desktop.png 2>/dev/null || convert tests/desktop.ppm docs/desktop.png 2>/dev/null || true

if [ "$found" -ne 1 ]; then
    echo "[workspace-test] FAIL: both desktop landmarks were not present in any frame within ${DEADLINE_SECS}s (ever saw: System Disk=$saw_disk, Workspace=$saw_ws)"
    echo "[workspace-test] login authenticated but the desktop never fully painted (see docs/desktop.png)"
    echo "[workspace-test] last OCR text was:"; printf '%s\n' "${text:-<none>}" | sed 's/^/[ocr] /'
    exit 1
fi
echo "[workspace-test] wrote docs/desktop.png ($(magick identify -format '%wx%h, %k colours' docs/desktop.png 2>/dev/null))"
