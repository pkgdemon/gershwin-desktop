#!/bin/sh
# workspace-test.sh — verify the login actually reached the Gershwin DESKTOP
# (not just the greeter), and capture it to docs/desktop.png for the README.
#
# GATING: this FAILS (exit 1) if the desktop never appears. The earlier
# boot-test only proves the graphical GREETER painted; a login that authenticates
# but whose session can't start drops straight back to the greeter, which the
# boot-test still passes. So without this gate a broken login → desktop slips
# through as a green build (exactly what happened while /Local/Users/admin was
# getting clobbered). "Desktop is up" is detected by a high unique-colour count —
# the greeter is ~200-400 colours on flat grey, the wallpapered desktop is
# ~5000+ from the gradient — with the 'System Disk' icon via OCR as a secondary
# signal. Runs from outside the guest via the QEMU monitor.
set -u

SOCK=tests/mon.sock
DEADLINE_SECS=120          # max wait for the desktop to come up post-login
DESKTOP_COLORS=1500        # > this many unique colours => wallpapered desktop is up
mon() { printf '%s\n' "$*" | socat -t2 - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1 || true; }
colors() { magick identify -format '%k' "$1" 2>/dev/null || identify -format '%k' "$1" 2>/dev/null || echo 0; }

# Secondary signal: does this frame show the "System Disk" desktop icon label?
have_system_disk() {
    command -v tesseract >/dev/null 2>&1 || return 1
    magick "$1" "$1.png" 2>/dev/null || convert "$1" "$1.png" 2>/dev/null || return 1
    tesseract "$1.png" - 2>/dev/null | tr -d '\r' | grep -qiE 'System[[:space:]]*Disk'
}

echo "[workspace-test] waiting for the DESKTOP (>${DESKTOP_COLORS} colours or 'System Disk') <= ${DEADLINE_SECS}s"
END=$(( $(date +%s) + DEADLINE_SECS ))
i=0
found=0
while [ "$(date +%s)" -lt "$END" ]; do
    i=$((i + 1))
    f="tests/desktop-$(printf '%03d' "$i").ppm"
    mon "screendump $f"
    sleep 1
    [ -f "$f" ] || { sleep 3; continue; }
    c=$(colors "$f")
    echo "[workspace-test] frame $i: ${c} colours"
    if [ "$c" -gt "$DESKTOP_COLORS" ] 2>/dev/null || have_system_disk "$f"; then
        echo "[workspace-test] PASS: desktop is up (frame $i, ${c} colours)"
        cp "$f" tests/desktop.ppm 2>/dev/null || true
        found=1
        break
    fi
    sleep 3
done

# Always leave a screenshot artifact for inspection — even on failure, so the
# boot-artifacts upload shows what was actually on screen (greeter? blank?).
[ "$found" -eq 1 ] || mon "screendump tests/desktop.ppm"
sleep 1
mkdir -p docs
magick tests/desktop.ppm docs/desktop.png 2>/dev/null || convert tests/desktop.ppm docs/desktop.png 2>/dev/null || true

if [ "$found" -ne 1 ]; then
    echo "[workspace-test] FAIL: desktop did not appear within ${DEADLINE_SECS}s"
    echo "[workspace-test] login authenticated but the session never painted (see docs/desktop.png)"
    exit 1
fi
echo "[workspace-test] wrote docs/desktop.png ($(magick identify -format '%wx%h, %k colours' docs/desktop.png 2>/dev/null))"
