# move-to-next-monitor

Script to move windows from one monitor to the next in Xubuntu

Even though I don't use Xubuntu anymore, people are still interested
in this script. Sweet! Glad it can help others.

I mapped `ctrl+alt+n` to execute this script.

To move the window the other way, pass `--previous` (or `-p`); `--next` (or `-n`)
is the default. For example, map `ctrl+alt+n` to `move-to-next-monitor` and
`ctrl+alt+p` to `move-to-next-monitor --previous`.

## Usage

```
wget https://raw.githubusercontent.com/jc00ke/move-to-next-monitor/master/move-to-next-monitor
chmod +x move-to-next-monitor
mv move-to-next-monitor /somewhere/in/your/$PATH
```

## Monitor geometry

The script uses each monitor's RandR rectangle instead of assuming that every
monitor has the dimensions of the first one. It keeps the window's offset from
the source monitor and clamps that offset to the destination. Windows larger
than the destination are placed at its top-left corner without resizing.

Monitors cycle from left to right, then top to bottom when their X coordinates
match. The source monitor is the one containing the largest part of the window;
fully off-screen windows use the nearest monitor centre. Mirrored rectangles
are counted once, and one-monitor configurations are left untouched.

This is an X11 tool. It requires `xrandr`; RandR 1.5 monitor objects are used
when available, with connected-output geometry as a fallback for older servers.
See the [xrandr manual](https://manpages.debian.org/bookworm/x11-xserver-utils/xrandr.1.en.html).

## Testing

```sh
python3 test/geometry-test.py -v
shellcheck move-to-next-monitor test/randr-xvfb-test.sh
bash test/randr-xvfb-test.sh
```

The deterministic tests exercise the shell script with command fixtures. The
integration test starts a private Xvfb with 1280x720 and 1024x900 RandR monitors,
Openbox and an xmessage window. It checks both directions, wrap-around and
maximization. It requires access to local X11 sockets.

The earlier `test/xephyr-test.sh` uses Xinerama; its topology may not expose two
RandR monitors, so use the new RandR integration test for this implementation.

## Dependencies

```
# Xubuntu 18.04
sudo apt install xdotool wmctrl x11-xserver-utils x11-utils

# Xubuntu 16.04
sudo apt-get install xdotool wmctrl x11-xserver-utils x11-utils

# Arch based (Manjaro / Endeavour OS)
sudo pacman -S xorg-xwininfo xorg-xrandr xorg-xprop
sudo pacman -S xdotool
sudo pacman -S wmctrl
```

## Code of Conduct

[We have one](code_of_conduct.md), and you're expected to follow it.

## Support

Since I don't use Xubuntu and therefore don't have a way to test changes, I'm going to rely on others to QA and give me feedback.

## Thanks

* [icyrock](http://icyrock.com/blog/2012/05/xubuntu-moving-windows-between-monitors/) post for initial development
* [@jordansissel](https://github.com/jordansissel) for his excellent [xdotool](https://github.com/jordansissel/xdotool)
