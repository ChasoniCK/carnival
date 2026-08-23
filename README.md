<img src="docs/icon.png" width="112" align="right" alt="">

# carnival

A macOS menu-bar monitor that shows CPU, GPU and memory — and nothing else.

<img src="docs/panel.png" width="290" alt="carnival panel">

- **CPU** — load, sparkline, temperature
- **GPU** — load, sparkline, temperature
- **MEM** — used percentage, sparkline, used GB, memory pressure, swap
- `Launch at Login` toggle, `Quit`

Written in ~460 lines of Swift against AppKit and IOKit. No dependencies, no
settings window, no background daemon. Idle cost on an M4 Pro, measured over
420 s against the previous build running beside it: **0.0024% of one core**
(10 ms of CPU in seven minutes) and 12 MB.

## Build

```sh
./build.sh
open carnival.app
```

`./tools/make-icon.sh` regenerates `carnival.icns`; the artwork is drawn in code,
there is no binary source asset to edit.

Requires the Xcode command line tools and macOS 26 or newer. The build ad-hoc
signs the bundle, so a copy downloaded from Releases needs its quarantine flag
cleared once:

```sh
xattr -dr com.apple.quarantine /Applications/carnival.app
```

Launch at Login records the bundle path, so after moving the app re-register it
from the new location:

```sh
/Applications/carnival.app/Contents/MacOS/carnival --login on
```

## How it stays cheap

Nobody is looking at the menu 99.9% of the time, and a timer wakeup costs ~284 us
whatever it does, so the tick runs every 10 s while the menu is closed and every 2 s
while it is open. Sparkline history advances on wall-clock rather than per tick, so
the two cadences never mix time scales; the window is a fixed 10 minutes. `cpuUsage`
is a delta of tick counters, so a sample taken too soon after another is noise — the
immediate tick on menu-open is suppressed if less than 0.4 s has passed.

Temperatures are the expensive part: each sensor read blocks ~845 us waiting on the
PMU while burning ~45 us of CPU. The 42 `PMU tdie` clients are only 14 physical dies
exposed three times each, so a pass reads one client per die and re-reads only the
three hottest in full — 20 reads instead of 42, with the reported hot spot unchanged.
The whole pass runs on a utility queue, so the menu never blocks on it.

Panel text is laid out once into cached `CTLine`s: laying out a string costs ~8 us and
drawing a laid-out one ~1 us, which takes `drawRect` down by 30% with byte-identical
output.

Measured and rejected: `Timer.tolerance` and `DispatchSourceTimer` leeway change
nothing (0.0172% vs 0.0177%); a pre-rendered gradient image is a 37% *regression* in a
real menu window; per-row invalidation saves nothing because 83% of a redraw is the
window surface flush. The 130-150 MB spike on first menu render is an in-process GPU
renderer that AppKit raises for text and gradient drawing — it is not reachable from
here and settles back to ~23 MB.

## Notes

The whole panel is one `NSView` with a hand-rolled `drawRect`, and history is a
fixed 60-slot ring buffer per metric, so the process allocates almost nothing
while running. Metrics come from `host_statistics`, `host_statistics64`,
`sysctl` and the `IOAccelerator` registry entry.

Temperatures use the private `IOHIDEventSystem` API — the only route to sensor
data on Apple Silicon. M1/M2 chips label their sensors (`pACC MTR Temp Sensor`,
`GPU MTR Temp Sensor`) and carnival reads those directly. M3 and newer expose 14
unlabeled `PMU tdieN` die sensors instead: under isolated CPU and GPU load they
heat within a degree of each other, so carnival reports the die hot spot as CPU
and the die average as GPU rather than inventing a mapping. Run
`carnival.app/Contents/MacOS/carnival --sensors` to dump the raw sensor list.
