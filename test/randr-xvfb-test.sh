#!/usr/bin/env bash
# Integration test: a private Xvfb, two unequal RandR monitors and Openbox.
# Requires Xvfb, xrandr, openbox, xmessage, xdotool, wmctrl, xwininfo, xprop and xdpyinfo.
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."
script="$PWD/move-to-next-monitor"
for command in Xvfb xrandr openbox xmessage xdotool wmctrl xwininfo xprop xdpyinfo; do
    command -v "$command" >/dev/null || { echo "Missing dependency: $command" >&2; exit 1; }
done
log_dir=$(mktemp -d -t randr-xvfb-test-XXXXXX)
server='' wm='' app=''
cleanup() {
    local status=$? pid log
    for pid in "$app" "$wm" "$server"; do
        [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
    done
    # CI runners are discarded after the job, so show the logs on failure.
    if [ "$status" -ne 0 ]; then
        for log in "$log_dir"/*.log; do
            [ -s "$log" ] || continue
            echo "== $log" >&2
            tail -50 "$log" >&2
        done
    fi
    echo "X11 logs: $log_dir"
}
trap cleanup EXIT
display=120
while [ -e "/tmp/.X${display}-lock" ] || [ -S "/tmp/.X11-unix/X${display}" ]; do
    display=$((display + 1))
done
Xvfb ":$display" -screen 0 2304x900x24 -nolisten tcp -noreset >"$log_dir/server.log" 2>&1 &
server=$!
export DISPLAY=":$display"
ready=false
for _ in {1..150}; do
    kill -0 "$server" 2>/dev/null || { echo "Xvfb exited during startup" >&2; exit 1; }
    if xdpyinfo >/dev/null 2>&1; then ready=true; break; fi
    sleep 0.1
done
$ready || { echo "Xvfb startup timed out" >&2; exit 1; }
xrandr --setmonitor LEFT 1280/340x720/190+0+0 screen
xrandr --setmonitor RIGHT 1024/270x900/240+1280+0 none
layout=$(xrandr --listactivemonitors)
echo "$layout"
[[ "$layout" == "Monitors: 2"$'\n'* && "$layout" == *1280/340x720/190+0+0* && "$layout" == *1024/270x900/240+1280+0* ]] || {
    echo "Xvfb did not expose both unequal active RandR monitors" >&2
    exit 1
}
openbox >"$log_dir/wm.log" 2>&1 &
wm=$!
ready=false
for _ in {1..150}; do
    if xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -q 'window id'; then ready=true; break; fi
    sleep 0.1
done
$ready || { echo "Openbox startup timed out" >&2; exit 1; }
xmessage -name randr-test -geometry 300x200+100+100 "RandR integration test" >"$log_dir/app.log" 2>&1 &
app=$!
window=
for _ in {1..150}; do
    window=$(xdotool search --onlyvisible --name randr-test 2>/dev/null | head -1) || true
    [ -z "$window" ] || break
    sleep 0.1
done
[ -n "$window" ] || { echo "Test window startup timed out" >&2; exit 1; }
wmctrl -i -a "$window"
for _ in {1..150}; do
    [ "$(xdotool getactivewindow 2>/dev/null)" != "$window" ] || break
    sleep 0.1
done
[ "$(xdotool getactivewindow)" = "$window" ] || { echo "Cannot activate test window" >&2; exit 1; }

check() {
    local label=$1 target=$2 geometry x y width height ok=false
    for _ in {1..150}; do
        geometry=$(xwininfo -id "$window")
        read -r x y width height < <(awk '
            /Absolute upper-left X:/ {x=$4} /Absolute upper-left Y:/ {y=$4}
            /^[[:space:]]*Width:/ {w=$2} /^[[:space:]]*Height:/ {h=$2}
            END {print x,y,w,h}' <<<"$geometry")
        if [ "$target" = left ]; then
            if ((x >= 0 && x + width <= 1280 && y >= 0 && y + height <= 720)); then ok=true; break; fi
        elif ((x >= 1280 && x + width <= 2304 && y >= 0 && y + height <= 900)); then
            ok=true; break
        fi
        sleep 0.1
    done
    $ok || { echo "FAIL $label: $x,$y ${width}x$height" >&2; exit 1; }
    echo "ok   $label"
}

check "starts on left monitor" left
"$script"; check "next moves to unequal right monitor" right
"$script" --next; check "next wraps to left monitor" left
"$script" --previous; check "previous wraps to right monitor" right
"$script" -p; check "previous moves to left monitor" left
wmctrl -ir "$window" -b add,maximized_vert,maximized_horz
maximized=false
for _ in {1..150}; do
    state=$(xprop -id "$window" _NET_WM_STATE)
    if [[ "$state" == *MAXIMIZED_VERT* && "$state" == *MAXIMIZED_HORZ* ]]; then maximized=true; break; fi
    sleep 0.1
done
$maximized || { echo "Window did not maximize" >&2; exit 1; }
"$script"; check "maximized window moves to right monitor" right
state=$(xprop -id "$window" _NET_WM_STATE)
[[ "$state" == *MAXIMIZED_VERT* && "$state" == *MAXIMIZED_HORZ* ]] || { echo "Maximization lost" >&2; exit 1; }
"$script" --previous; check "maximized window returns to left monitor" left
xprop -id "$window" -f _NET_WM_WINDOW_TYPE 32a -set _NET_WM_WINDOW_TYPE _NET_WM_WINDOW_TYPE_DESKTOP
"$script"; check "desktop window stays on left monitor" left
xprop -id "$window" -remove _NET_WM_WINDOW_TYPE
"$script"; check "normal window moves again" right
echo "All unequal-monitor X11 integration tests passed."
