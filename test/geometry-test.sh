#!/usr/bin/env bash
# Exercise the actual script with deterministic X11 command fixtures.
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."
script="$PWD/move-to-next-monitor"
fixtures=$(mktemp -d -t geometry-test-XXXXXX)
trap 'rm -rf "$fixtures"' EXIT

# One mock, symlinked as each X11 command. It logs every call to "calls" and
# keeps the window's _NET_WM_STATE in "state", both next to the symlinks.
cat >"$fixtures/mock" <<'EOF'
#!/usr/bin/env bash
command=${0##*/} dir=${0%/*} last=${!#}
echo "$command $*" >>"$dir/calls"
case $command in
    xrandr)
        [[ $1 == --listactivemonitors && -n ${FIXTURE_OLD_RANDR:-} ]] && exit 1
        echo "$FIXTURE_MONITORS" ;;
    xdotool)
        if [ "$1" = getactivewindow ]; then echo 123
        elif [ -n "${FIXTURE_MOVE_FAIL:-}" ]; then exit 7
        fi ;;
    xwininfo)
        read -r x y w h <<<"$FIXTURE_GEOMETRY"
        printf 'Absolute upper-left X: %s\nAbsolute upper-left Y: %s\n' "$x" "$y"
        printf 'Relative upper-left X: 0\nRelative upper-left Y: 0\n'
        printf 'Width: %s\nHeight: %s\n' "$w" "$h" ;;
    xprop)
        if [ "$last" = _NET_FRAME_EXTENTS ]; then
            echo "_NET_FRAME_EXTENTS(CARDINAL) = ${FIXTURE_EXTENTS:-0, 0, 0, 0}"
        else
            echo "_NET_WM_STATE(ATOM) = $(<"$dir/state")"
        fi ;;
    wmctrl)
        if [[ $last == remove,* ]]; then
            : >"$dir/state"
        else
            flags=$(tr '[:lower:]' '[:upper:]' <<<"${last#*,}")
            echo "_NET_WM_STATE_${flags//,/, _NET_WM_STATE_}" >"$dir/state"
        fi ;;
esac
EOF
chmod +x "$fixtures/mock"
for command in xrandr xdotool xwininfo xprop wmctrl; do
    ln -s mock "$fixtures/$command"
done
export PATH="$fixtures:$PATH"

# monitors W H X Y [W H X Y ...] prints "xrandr --listactivemonitors" output.
monitors() {
    local i=0
    echo "Monitors: $(($# / 4))"
    while [ "$#" -gt 0 ]; do
        printf ' %d: +monitor%d %d/300x%d/200%+d%+d output%d\n' "$i" "$i" "$1" "$2" "$3" "$4" "$i"
        shift 4
        i=$((i + 1))
    done
}

# run LAYOUT "X Y WIDTH HEIGHT" [ARGS...] runs the script against the fixtures,
# starting with FIXTURE_WM_STATE, and sets $status, $calls and $moves.
run() {
    echo "${FIXTURE_WM_STATE:-}" >"$fixtures/state"
    : >"$fixtures/calls"
    status=0
    FIXTURE_MONITORS=$1 FIXTURE_GEOMETRY=$2 bash "$script" "${@:3}" \
        >/dev/null 2>"$fixtures/stderr" || status=$?
    calls=$(<"$fixtures/calls")
    moves=$(awk '$1 == "xdotool" && $2 == "windowmove" {print $(NF-1), $NF}' <<<"$calls")
}

failures=0
# check LABEL ACTUAL EXPECTED
check() {
    if [ "$2" = "$3" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1: got '$2', expected '$3'" >&2
        sed 's/^/    /' "$fixtures/stderr" >&2
        failures=$((failures + 1))
    fi
}

# expect_move LABEL LAYOUT "X Y WIDTH HEIGHT" "NEW_X NEW_Y" [ARGS...]
expect_move() {
    run "$2" "$3" "${@:5}"
    check "$1" "$status $moves" "0 $4"
}

side_by_side=$(monitors 1280 720 0 0 1024 900 1280 0)
large_small=$(monitors 1920 1080 0 0 1024 768 1920 0)
three_wide=$(monitors 800 600 1800 0 1000 700 800 0 800 600 0 0)
window="100 100 300 200"

expect_move "unequal side-by-side monitors" "$side_by_side" "$window" "1380 100"
expect_move "previous wraps" "$side_by_side" "$window" "1380 100" --previous
expect_move "next wraps from smaller monitor" "$side_by_side" "1380 100 300 200" "100 100"
expect_move "clamps window to smaller destination" "$large_small" "1500 800 400 300" "2544 468"
expect_move "vertical layout" "$(monitors 1280 720 0 0 1024 900 0 720)" "$window" "100 820"
expect_move "offset destination" "$(monitors 1280 720 0 180 1024 900 1280 0)" "100 280 300 200" "1380 100"
expect_move "negative monitor origin" "$(monitors 1280 720 0 0 1024 900 -1024 0)" "$window" "-924 100" -p
expect_move "three monitors use spatial order" "$three_wide" "900 100 200 100" "1900 100" -n
expect_move "previous moves the other way on three monitors" "$three_wide" "900 100 200 100" "100 100" -p
expect_move "overlap selects largest window area" "$side_by_side" "1200 100 400 200" "0 100"
expect_move "offscreen window uses nearest monitor" "$side_by_side" "2400 100 300 200" "980 100"
expect_move "oversized window anchors at destination origin" "$side_by_side" "100 100 1500 1000" "1280 0"
FIXTURE_EXTENTS="5, 5, 30, 5" \
    expect_move "frame extents count towards bounds" "$large_small" "1500 800 400 300" "2534 433"
FIXTURE_OLD_RANDR=1 expect_move "RandR query fallback ignores disconnected and inactive outputs" \
    "A connected primary 1280x720+0+0
B connected 1024x900+1280+0
C disconnected
D connected" "$window" "1380 100"

run "$(monitors 1280 720 0 0 1280 720 0 0)" "$window"
check "mirrored outputs do not touch window" "$status|$calls" "0|xrandr --listactivemonitors"
run "Monitors: 0" "$window"
check "no active monitor fails without touching window" "$status|$calls" "1|xrandr --listactivemonitors"

for flags in _NET_WM_STATE_MAXIMIZED_HORZ _NET_WM_STATE_MAXIMIZED_VERT \
    "_NET_WM_STATE_MAXIMIZED_HORZ, _NET_WM_STATE_MAXIMIZED_VERT"; do
    FIXTURE_WM_STATE=$flags run "$side_by_side" "$window"
    check "restores $flags" "$status|$(<"$fixtures/state")" "0|$flags"
done
FIXTURE_WM_STATE=_NET_WM_STATE_MAXIMIZED_HORZ FIXTURE_MOVE_FAIL=1 run "$side_by_side" "$window"
check "failed move restores maximization and returns its error" \
    "$status|$(<"$fixtures/state")" "7|_NET_WM_STATE_MAXIMIZED_HORZ"

run "Monitors: 0" "$window" --bogus
check "unknown option does not query display" "$status|$calls" "1|"
run "Monitors: 0" "$window" --next extra
check "extra argument does not query display" "$status|$calls" "1|"

[ "$failures" -eq 0 ] || { echo "$failures geometry test(s) failed." >&2; exit 1; }
echo "All geometry tests passed."
