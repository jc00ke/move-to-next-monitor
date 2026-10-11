"""Exercise the actual shell script with deterministic X11 command fixtures."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "move-to-next-monitor"
MOCK = r'''
import json, os, sys
from pathlib import Path
command = Path(sys.argv[0]).name
args = sys.argv[1:]
state = Path(os.environ["FIXTURE_STATE"])
calls = Path(os.environ["FIXTURE_CALLS"])
with calls.open("a") as stream:
    stream.write(json.dumps([command, *args]) + "\n")
if command == "xrandr":
    if args == ["--listactivemonitors"] and os.environ.get("FIXTURE_OLD_RANDR"):
        sys.exit(1)
    print(os.environ["FIXTURE_MONITORS"])
elif command == "xdotool":
    if args == ["getactivewindow"]:
        print(123)
    elif os.environ.get("FIXTURE_MOVE_FAIL"):
        sys.exit(7)
elif command == "xwininfo":
    x,y,w,h = json.loads(os.environ["FIXTURE_GEOMETRY"])
    print(f"Absolute upper-left X: {x}\nAbsolute upper-left Y: {y}")
    print("Relative upper-left X: 0\nRelative upper-left Y: 0")
    print(f"Width: {w}\nHeight: {h}")
elif command == "xprop":
    if args[-1] == "_NET_FRAME_EXTENTS":
        print("_NET_FRAME_EXTENTS(CARDINAL) = " + os.environ.get("FIXTURE_EXTENTS", "0, 0, 0, 0"))
    else:
        flags = state.read_text()
        print("_NET_WM_STATE(ATOM) = " + flags)
elif command == "wmctrl":
    if args[-1].startswith("remove,"):
        state.write_text("")
    else:
        state.write_text(", ".join("_NET_WM_STATE_" + f.upper() for f in args[-1].split(",")[1:]))
'''


def monitors(*rectangles):
    return "Monitors: " + str(len(rectangles)) + "\n" + "\n".join(
        f" {i}: +monitor{i} {w}/300x{h}/200{x:+d}{y:+d} output{i}"
        for i, (w, h, x, y) in enumerate(rectangles)
    )


class GeometryTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="monitor-tests-"))
        for command in ("xrandr", "xdotool", "xwininfo", "xprop", "wmctrl"):
            path = self.root / command
            path.write_text(f"#!{sys.executable}\n" + MOCK)
            path.chmod(0o700)
        self.state = self.root / "state"
        self.state.write_text("")
        self.calls = self.root / "calls"

    def run_script(self, layout, geometry, *args, **extra):
        env = {**os.environ, "PATH": str(self.root) + ":" + os.environ["PATH"],
               "FIXTURE_STATE": str(self.state), "FIXTURE_CALLS": str(self.calls),
               "FIXTURE_MONITORS": layout, "FIXTURE_GEOMETRY": json.dumps(geometry), **extra}
        result = subprocess.run(["bash", str(SCRIPT), *args], env=env, capture_output=True, text=True)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []
        moves = [call[-2:] for call in calls if call[:2] == ["xdotool", "windowmove"]]
        return result, moves, calls

    def assert_move(self, layout, geometry, expected, *args, **extra):
        result, moves, _ = self.run_script(layout, geometry, *args, **extra)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(moves, [[str(v) for v in expected]])

    def test_unequal_side_by_side(self):
        self.assert_move(monitors((1280,720,0,0),(1024,900,1280,0)), (100,100,300,200), (1380,100))

    def test_previous_wraps(self):
        self.assert_move(monitors((1280,720,0,0),(1024,900,1280,0)), (100,100,300,200), (1380,100), "--previous")

    def test_next_wraps_from_smaller_monitor(self):
        self.assert_move(monitors((1280,720,0,0),(1024,900,1280,0)), (1380,100,300,200), (100,100))

    def test_clamps_window_to_smaller_destination(self):
        self.assert_move(monitors((1920,1080,0,0),(1024,768,1920,0)), (1500,800,400,300), (2544,468))

    def test_vertical_layout(self):
        self.assert_move(monitors((1280,720,0,0),(1024,900,0,720)), (100,100,300,200), (100,820))

    def test_offset_destination(self):
        self.assert_move(monitors((1280,720,0,180),(1024,900,1280,0)), (100,280,300,200), (1380,100))

    def test_negative_monitor_origin(self):
        self.assert_move(monitors((1280,720,0,0),(1024,900,-1024,0)), (100,100,300,200), (-924,100), "-p")

    def test_three_monitors_use_spatial_order(self):
        self.assert_move(monitors((800,600,1800,0),(1000,700,800,0),(800,600,0,0)), (900,100,200,100), (1900,100), "-n")

    def test_overlap_selects_largest_window_area(self):
        self.assert_move(monitors((1280,720,0,0),(1024,900,1280,0)), (1200,100,400,200), (0,100))

    def test_offscreen_window_uses_nearest_monitor(self):
        self.assert_move(monitors((1280,720,0,0),(1024,900,1280,0)), (2400,100,300,200), (980,100))

    def test_oversized_window_anchors_at_destination_origin(self):
        self.assert_move(monitors((1280,720,0,0),(1024,900,1280,0)), (100,100,1500,1000), (1280,0))

    def test_frame_extents_count_towards_bounds(self):
        self.assert_move(monitors((1920,1080,0,0),(1024,768,1920,0)), (1500,800,400,300), (2534,433), FIXTURE_EXTENTS="5, 5, 30, 5")

    def test_randr_query_fallback_ignores_disconnected_and_inactive_outputs(self):
        layout = "A connected primary 1280x720+0+0\nB connected 1024x900+1280+0\nC disconnected\nD connected\n"
        self.assert_move(layout, (100,100,300,200), (1380,100), FIXTURE_OLD_RANDR="1")

    def test_mirrored_outputs_do_not_move_window(self):
        result, moves, calls = self.run_script(monitors((1280,720,0,0),(1280,720,0,0)), (100,100,300,200))
        self.assertEqual(result.returncode, 0)
        self.assertEqual(moves, [])
        self.assertFalse(any(call[0] == "wmctrl" for call in calls))

    def test_no_active_monitor_fails_without_touching_window(self):
        result, moves, calls = self.run_script("Monitors: 0\n", (100,100,300,200))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(moves, [])
        self.assertFalse(any(call[0] == "wmctrl" for call in calls))

    def test_maximized_state_is_restored(self):
        for flags in ("_NET_WM_STATE_MAXIMIZED_HORZ", "_NET_WM_STATE_MAXIMIZED_VERT",
                      "_NET_WM_STATE_MAXIMIZED_HORZ, _NET_WM_STATE_MAXIMIZED_VERT"):
            with self.subTest(flags=flags):
                self.state.write_text(flags)
                result, _, _ = self.run_script(monitors((1280,720,0,0),(1024,900,1280,0)), (100,100,300,200))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(set(self.state.read_text().split(", ")), set(flags.split(", ")))

    def test_failed_move_restores_maximization_and_returns_error(self):
        self.state.write_text("_NET_WM_STATE_MAXIMIZED_HORZ")
        result, _, _ = self.run_script(monitors((1280,720,0,0),(1024,900,1280,0)), (100,100,300,200), FIXTURE_MOVE_FAIL="1")
        self.assertEqual(result.returncode, 7)
        self.assertEqual(self.state.read_text(), "_NET_WM_STATE_MAXIMIZED_HORZ")

    def test_invalid_options_do_not_query_display(self):
        for args in (("--bogus",), ("--next", "extra")):
            result, moves, calls = self.run_script("Monitors: 0\n", (100,100,300,200), *args)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(moves, [])
            self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
