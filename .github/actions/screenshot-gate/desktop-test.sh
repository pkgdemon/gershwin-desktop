#!/bin/sh
# desktop-test.sh — the interactive desktop gate, driven entirely from OUTSIDE
# the guest over the QEMU monitor (screendump + sendkey; no mouse, nothing
# installed in-guest). Every numbered step is a HARD gate: any failure exits
# non-zero, fails the job, and blocks the ISO publish.
#
#   1. desktop rendered  — OCR must find BOTH "System Disk" and "Workspace"
#   2. discover Command  — probe sendkey modifiers until Cmd+R opens the Run…
#                          dialog ("Type the command to execute:")
#   3. close everything  — Cmd+W a few times
#   4. open About        — Cmd+R, type "uitest aboutcomputer", Enter
#   5. About is up       — OCR must find "About This Computer"
#   6. capture           — screendump THIS frame -> screenshot/gershwin-on-<flavor>.png,
#                          the ONLY published screenshot (About This Computer + desktop)
#
# The Command modifier and the About-opening command are the two things that can
# only be confirmed on a real boot, so step 2 auto-probes the modifier and each
# failure prints a precise, actionable reason (wrong modifier vs. uitest/-d).
set -u

SOCK=tests/mon.sock
DESKTOP_DEADLINE=120
ABOUT_DEADLINE=25
CMD="${GATE_ABOUT_CMD:-uitest aboutcomputer}"            # run via the Run… dialog
MODS="${GATE_CMD_MODS:-meta_l alt altgr meta_r ctrl}"    # GNUstep Command modifier — probed
FLAVOR="${GATE_FLAVOR:-desktop}"                         # which flavor we're testing (from the caller workflow)
SHOT="screenshot/gershwin-on-${FLAVOR}.png"              # the ONE published screenshot

mon()  { printf '%s\n' "$*" | socat -t2 - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1 || true; }
key()  { mon "sendkey $1"; sleep 0.25; }
park() {   # shove the (relative PS/2) pointer hard into the bottom-right corner so
    # it doesn't sit over the centred About window in the published screenshot.
    mon "mouse_move 20000 20000"; sleep 0.4;
}
dump() { mon "screendump $1"; sleep 0.6; }
ocr()  {   # OCR the whole frame (reads the menu bar: "Workspace", etc.)
    command -v tesseract >/dev/null 2>&1 || return 1
    magick "$1" -resize 200% "$1.png" 2>/dev/null || convert "$1" -resize 200% "$1.png" 2>/dev/null || return 1
    tesseract "$1.png" - 2>/dev/null | tr -d '\r'
}
ocr_corner() {   # OCR just the top-right corner where the "System Disk" volume
    # icon lives. Its ~11px label is invisible to a full-frame OCR pass but reads
    # cleanly cropped, greyscaled and upscaled hard. NOTE: use tesseract's default
    # psm 3 (auto) — the sparse-text modes (psm 11/12) mangle this label; verified
    # against a real captured frame.
    command -v tesseract >/dev/null 2>&1 || return 1
    magick "$1" -gravity NorthEast -crop 42%x24%+0+0 +repage -colorspace Gray -resize 400% "$1.ne.png" 2>/dev/null \
      || convert "$1" -gravity NorthEast -crop 42%x24%+0+0 +repage -colorspace Gray -resize 400% "$1.ne.png" 2>/dev/null || return 1
    tesseract "$1.ne.png" - 2>/dev/null | tr -d '\r'
}
has() { printf '%s' "$2" | grep -qiE "$1"; }             # has REGEX TEXT
type_str() {
    s=$1
    while [ -n "$s" ]; do
        ch=$(printf '%.1s' "$s"); s=${s#?}
        case "$ch" in ' ') key spc ;; *) key "$ch" ;; esac
    done
}
save_shot() {   # copy $1 (or a fresh screendump) to the published $SHOT
    if [ -n "${1:-}" ] && [ -s "${1:-}" ]; then cp "$1" tests/desktop.ppm 2>/dev/null || true
    else mon "screendump tests/desktop.ppm"; sleep 1; fi
    magick tests/desktop.ppm "$SHOT" 2>/dev/null || convert tests/desktop.ppm "$SHOT" 2>/dev/null || true
}

mkdir -p tests screenshot

# --- 1. desktop rendered: "System Disk" AND "Workspace" -----------------------
echo "[desktop-test] 1/5 waiting for the desktop — 'System Disk' AND 'Workspace' (<= ${DESKTOP_DEADLINE}s)"
END=$(( $(date +%s) + DESKTOP_DEADLINE )); i=0; up=0; text=""; corner=""; f=""
while [ "$(date +%s)" -lt "$END" ]; do
    i=$((i + 1)); f="tests/desk-$(printf '%03d' "$i").ppm"; dump "$f"
    [ -s "$f" ] || { sleep 3; continue; }
    text=$(ocr "$f"); corner=$(ocr_corner "$f"); d=0; w=0
    # "Workspace" is menu-bar text -> full-frame OCR; "System Disk" is the small
    # top-right icon label -> corner OCR (full frame can't read it).
    { has 'System[[:space:]]*Disk' "$corner" || has 'System[[:space:]]*Disk' "$text"; } && d=1
    has 'Workspace' "$text" && w=1
    echo "[desktop-test]   frame $i: System Disk=$d Workspace=$w"
    { [ "$d" -eq 1 ] && [ "$w" -eq 1 ]; } && { up=1; break; }
    sleep 3
done
if [ "$up" -ne 1 ]; then
    save_shot "$f"
    echo "[desktop-test] FAIL(1): 'System Disk' and 'Workspace' not both OCR-detected within ${DESKTOP_DEADLINE}s."
    echo "[desktop-test]   full-frame OCR:"; printf '%s\n' "${text:-<none>}" | sed 's/^/[ocr] /'
    echo "[desktop-test]   corner OCR:";     printf '%s\n' "${corner:-<none>}" | sed 's/^/[ocr-ne] /'
    exit 1
fi
echo "[desktop-test] 1/5 PASS: desktop is up"

# --- 2. discover the Command modifier via the Run… dialog ---------------------
# Run… uses NSCommandKeyMask|NSShiftKeyMask + "R" (confirmed in Workspace.m), so
# the chord is Cmd+SHIFT+R. Probe each candidate Command modifier WITH shift.
echo "[desktop-test] 2/5 probing Command modifier (Cmd+Shift+R must open the Run… dialog)"
MOD=""; RUN_KEYS=""
for cand in $MODS; do
    key esc; key esc
    combo="${cand}-shift-r"
    mon "sendkey $combo"; sleep 1.2
    f="tests/run-${cand}.ppm"; dump "$f"
    t=$(ocr "$f")
    if has 'command to execute|Type the command' "$t"; then
        MOD="$cand"; RUN_KEYS="$combo"
        echo "[desktop-test]   Command modifier = '$cand' — '$combo' opened the Run… dialog"; key esc; break
    fi
    echo "[desktop-test]   '$combo' did not open Run… (OCR: $(printf '%s' "$t" | tr '\n' ' ' | grep -oiE 'run|cancel|command' | tr '\n' ',' | sed 's/,$//'))"
done
if [ -z "$MOD" ]; then
    save_shot ""
    echo "[desktop-test] FAIL(2): no modifier opened the Run… dialog with Cmd+Shift+R (tried: $MODS)."
    echo "[desktop-test]   -> the QEMU keyname for GNUstep's Command modifier is wrong (see run-*.ppm in boot-artifacts),"
    echo "[desktop-test]      or the Run… detection missed the dialog. Set GATE_CMD_MODS and re-run."
    exit 1
fi

# --- 3. close everything ------------------------------------------------------
echo "[desktop-test] 3/5 closing open windows (Cmd+W x5)"
n=0; while [ "$n" -lt 5 ]; do mon "sendkey ${MOD}-w"; sleep 0.4; n=$((n + 1)); done

# --- 4. open About This Computer via Run… + uitest ----------------------------
echo "[desktop-test] 4/5 opening About This Computer ($RUN_KEYS -> '$CMD')"
key esc
mon "sendkey $RUN_KEYS"; sleep 1
type_str "$CMD"
key ret
park   # get the mouse pointer out of the About window before we capture the frame

# --- 5. About This Computer is up ---------------------------------------------
echo "[desktop-test] 5/5 verifying 'About This Computer' (<= ${ABOUT_DEADLINE}s)"
END=$(( $(date +%s) + ABOUT_DEADLINE )); i=0; ok=0; text=""; f=""
while [ "$(date +%s)" -lt "$END" ]; do
    i=$((i + 1)); f="tests/about-$(printf '%03d' "$i").ppm"; dump "$f"
    [ -s "$f" ] || { sleep 2; continue; }
    text=$(ocr "$f")
    has 'About[[:space:]]*This[[:space:]]*Computer' "$text" && { ok=1; break; }
    echo "[desktop-test]   frame $i: About This Computer not yet visible"
    sleep 2
done

# --- 6. capture — always leave $SHOT (the published screenshot) ---------------
save_shot "$f"
if [ "$ok" -ne 1 ]; then
    echo "[desktop-test] FAIL(5): 'About This Computer' never appeared."
    echo "[desktop-test]   Run… opened (modifier '$MOD' works), so the command ran but produced no About window."
    echo "[desktop-test]   -> likely: Workspace must be started with -d (to vend uitest's DO), or 'uitest' is not on PATH."
    echo "[desktop-test]   last OCR text:"; printf '%s\n' "${text:-<none>}" | sed 's/^/[ocr] /'
    exit 1
fi
echo "[desktop-test] PASS: 'About This Computer' is up — wrote $SHOT (the published screenshot)"
