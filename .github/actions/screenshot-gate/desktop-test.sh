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
#   4. open About        — Cmd+R, type "uitest about", Enter
#   5. About is up       — OCR must find "About This Computer"
#   6. capture           — screendump THIS frame -> docs/desktop.png, the ONLY
#                          published screenshot (About This Computer + desktop)
#
# The Command modifier and the About-opening command are the two things that can
# only be confirmed on a real boot, so step 2 auto-probes the modifier and each
# failure prints a precise, actionable reason (wrong modifier vs. uitest/-d).
set -u

SOCK=tests/mon.sock
DESKTOP_DEADLINE=120
ABOUT_DEADLINE=25
CMD="${GATE_ABOUT_CMD:-uitest about}"                    # run via the Run… dialog
MODS="${GATE_CMD_MODS:-meta_l alt meta_r ctrl}"          # GNUstep Command modifier — probed

mon()  { printf '%s\n' "$*" | socat -t2 - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1 || true; }
key()  { mon "sendkey $1"; sleep 0.25; }
dump() { mon "screendump $1"; sleep 0.6; }
ocr()  {
    command -v tesseract >/dev/null 2>&1 || return 1
    magick "$1" -resize 200% "$1.png" 2>/dev/null || convert "$1" -resize 200% "$1.png" 2>/dev/null || return 1
    tesseract "$1.png" - 2>/dev/null | tr -d '\r'
}
has() { printf '%s' "$2" | grep -qiE "$1"; }             # has REGEX TEXT
type_str() {
    s=$1
    while [ -n "$s" ]; do
        ch=$(printf '%.1s' "$s"); s=${s#?}
        case "$ch" in ' ') key spc ;; *) key "$ch" ;; esac
    done
}
save_shot() {   # copy $1 (or a fresh screendump) to the published docs/desktop.png
    if [ -n "${1:-}" ] && [ -s "${1:-}" ]; then cp "$1" tests/desktop.ppm 2>/dev/null || true
    else mon "screendump tests/desktop.ppm"; sleep 1; fi
    magick tests/desktop.ppm docs/desktop.png 2>/dev/null || convert tests/desktop.ppm docs/desktop.png 2>/dev/null || true
}

mkdir -p tests docs

# --- 1. desktop rendered: "System Disk" AND "Workspace" -----------------------
echo "[desktop-test] 1/5 waiting for the desktop — 'System Disk' AND 'Workspace' (<= ${DESKTOP_DEADLINE}s)"
END=$(( $(date +%s) + DESKTOP_DEADLINE )); i=0; up=0; text=""; f=""
while [ "$(date +%s)" -lt "$END" ]; do
    i=$((i + 1)); f="tests/desk-$(printf '%03d' "$i").ppm"; dump "$f"
    [ -s "$f" ] || { sleep 3; continue; }
    text=$(ocr "$f"); d=0; w=0
    has 'System[[:space:]]*Disk' "$text" && d=1
    has 'Workspace'              "$text" && w=1
    echo "[desktop-test]   frame $i: System Disk=$d Workspace=$w"
    { [ "$d" -eq 1 ] && [ "$w" -eq 1 ]; } && { up=1; break; }
    sleep 3
done
if [ "$up" -ne 1 ]; then
    save_shot "$f"
    echo "[desktop-test] FAIL(1): desktop landmarks not both present within ${DESKTOP_DEADLINE}s (login likely never reached the desktop)."
    echo "[desktop-test]   last OCR text:"; printf '%s\n' "${text:-<none>}" | sed 's/^/[ocr] /'
    exit 1
fi
echo "[desktop-test] 1/5 PASS: desktop is up"

# --- 2. discover the Command modifier via the Run… dialog ---------------------
echo "[desktop-test] 2/5 probing Command modifier (Cmd+R must open the Run… dialog)"
MOD=""
for cand in $MODS; do
    key esc; key esc
    mon "sendkey ${cand}-r"; sleep 1.2
    f="tests/run-${cand}.ppm"; dump "$f"
    t=$(ocr "$f")
    if has 'command to execute|Type the command' "$t"; then
        MOD="$cand"; echo "[desktop-test]   Command modifier = '$cand' (Run… dialog opened)"; key esc; break
    fi
    echo "[desktop-test]   '$cand' did not open Run…"
done
if [ -z "$MOD" ]; then
    save_shot ""
    echo "[desktop-test] FAIL(2): no sendkey modifier opened the Run… dialog (tried: $MODS)."
    echo "[desktop-test]   -> the QEMU keyname for GNUstep's Command modifier is wrong, or Run…'s Cmd+R is remapped."
    echo "[desktop-test]   -> set GATE_CMD_MODS to the correct sendkey modifier and re-run."
    exit 1
fi

# --- 3. close everything ------------------------------------------------------
echo "[desktop-test] 3/5 closing open windows (Cmd+W x5)"
n=0; while [ "$n" -lt 5 ]; do mon "sendkey ${MOD}-w"; sleep 0.4; n=$((n + 1)); done

# --- 4. open About This Computer via Run… + uitest ----------------------------
echo "[desktop-test] 4/5 opening About This Computer (Cmd+R -> '$CMD')"
key esc
mon "sendkey ${MOD}-r"; sleep 1
type_str "$CMD"
key ret

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

# --- 6. capture — always leave docs/desktop.png (the published screenshot) -----
save_shot "$f"
if [ "$ok" -ne 1 ]; then
    echo "[desktop-test] FAIL(5): 'About This Computer' never appeared."
    echo "[desktop-test]   Run… opened (modifier '$MOD' works), so the command ran but produced no About window."
    echo "[desktop-test]   -> likely: Workspace must be started with -d (to vend uitest's DO), or 'uitest' is not on PATH."
    echo "[desktop-test]   last OCR text:"; printf '%s\n' "${text:-<none>}" | sed 's/^/[ocr] /'
    exit 1
fi
echo "[desktop-test] PASS: 'About This Computer' is up — wrote docs/desktop.png (the published screenshot)"
