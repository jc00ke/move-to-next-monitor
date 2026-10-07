#!/bin/bash
#
# Test with two 1280x720 monitors side by side in a nested X server
# (Xephyr + Xinerama), a minimal window manager (openbox) and a test window (xeyes).
# Xephyr opens a 2560x720 window on the current desktop while the test runs.
#
# Dependencies: Xephyr, openbox, xeyes, plus the script's own
# (xdotool, wmctrl, xwininfo, xprop, xdpyinfo).
# Usage: test/xephyr-test.sh

set -u
cd "$(dirname "$0")/.." || exit 1
script=./move-to-next-monitor
# Pick a free display number and wait until the nested server answers.
display=99
while [ -e "/tmp/.X${display}-lock" ]; do display=$((display + 1)); done
Xephyr ":$display" -ac +xinerama -screen 1280x720+0+0 -screen 1280x720+1280+0 >/dev/null 2>&1 &
xephyr=$!
wm=
app=
export DISPLAY=":$display"
trap 'kill $wm $app $xephyr 2>/dev/null' EXIT
for _ in $(seq 50); do xdpyinfo >/dev/null 2>&1 && break; sleep 0.1; done
openbox >/dev/null 2>&1 &
wm=$!
for _ in $(seq 50); do xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -q 'window id' && break; sleep 0.1; done
xeyes -geometry 300x200+100+100 &
app=$!
window=$(xdotool search --sync --class xeyes | head -1)
# The script acts on the active window. openbox does not honour xdotool's
# activation request alone, so ask through wmctrl, focus, and click inside.
for _ in 1 2 3 4 5; do
    wmctrl -i -a "$window"
    xdotool windowfocus "$window"
    xdotool mousemove --window "$window" 50 50 click 1
    sleep 0.5
    [ "$(xdotool getactivewindow 2>/dev/null)" = "$window" ] && break
done
if [ "$(xdotool getactivewindow 2>/dev/null)" != "$window" ]; then
    echo "FAIL could not activate the test window"
    exit 1
fi

failures=0
left_x() { xwininfo -id "$window" | awk '/Absolute upper-left X:/ { print $4 }'; }
check() {  # check <description> <expected monitor: 0 or 1>
    sleep 0.5
    local x monitor
    x=$(left_x)
    monitor=$(( x >= 1280 ? 1 : 0 ))
    if [ "$monitor" -eq "$2" ]; then
        echo "ok   $1 (x=$x)"
    else
        echo "FAIL $1: expected monitor $2, window at x=$x"
        failures=$((failures + 1))
    fi
}

check "starts on the left monitor" 0
$script;              check "default moves to the next (right) monitor" 1
$script --next;       check "--next wraps around to the left monitor" 0
$script --previous;   check "--previous wraps around to the right monitor" 1
$script -p;           check "-p moves back to the left monitor" 0

wmctrl -ir "$window" -b add,maximized_vert,maximized_horz; sleep 0.5
$script;              check "maximized window moves to the next monitor" 1
if xprop -id "$window" _NET_WM_STATE | grep -q MAXIMIZED_HORZ; then
    echo "ok   window stays maximized"
else
    echo "FAIL window lost maximized state"
    failures=$((failures + 1))
fi
$script --previous;   check "maximized window moves to the previous monitor" 0

if $script --bogus 2>/dev/null; [ $? -eq 1 ]; then
    echo "ok   unknown option exits with status 1"
else
    echo "FAIL unknown option"
    failures=$((failures + 1))
fi

if [ "$failures" -eq 0 ]; then
    echo "All tests passed."
else
    echo "$failures test(s) failed."
fi
exit "$failures"
