#!/bin/bash
# Measures carnival against a baseline commit on this Mac and prints a Markdown report.
#   idle:  every build runs at once, menus closed; counters read IDLE seconds apart
#   open:  one build at a time, alternating; tools/bench/hook.m keeps its menu open for
#          OPEN seconds and counts redraws
#   micro: cost and syscalls of one sample, the baseline's code against the working tree's
#
#   tools/bench/run.sh [baseline-ref]                default: main
#   IDLE=600 OPEN=40 ROUNDS=3 tools/bench/run.sh 046bd92
#   TRACE=1 ...   also dtrace (sudo) what an idle build does besides its own tick
# Written for the stock /bin/bash 3.2.
set -eo pipefail
cd "$(dirname "$0")/../.."
base_ref=${1:-main}
IDLE=${IDLE:-600}
OPEN=${OPEN:-40}
ROUNDS=${ROUNDS:-3}
out=${OUT:-$PWD/bench-out}
rm -rf "$out"
mkdir -p "$out"
work=$(mktemp -d)
pids=""
trap 'kill $pids 2>/dev/null || true; rm -rf "$work"' EXIT

target=arm64-apple-macos26.0
{ sw_vers; sysctl -n machdep.cpu.brand_string hw.model hw.ncpu hw.memsize; swiftc --version 2>&1 | head -1; } \
    > "$out/env.txt"

# --- build -----------------------------------------------------------------------------

clang -O2 -Wall -o "$work/probe" tools/bench/probe.c
clang -c -O2 -Wall -fobjc-arc -mmacosx-version-min=26.0 -o "$work/hook.o" tools/bench/hook.m
"$work/probe" --selfcheck > "$out/selfcheck.txt"

plist() {  # plist APP NAME: a minimal Info.plist with a bundle id of its own, then sign
    cat > "$1/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>carnival</string>
	<key>CFBundleIdentifier</key><string>local.carnival.bench.$2</string>
	<key>CFBundleName</key><string>carnival-$2</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
    codesign --force -s - "$1" 2>/dev/null
}

bundle() {  # bundle NAME SOURCE [more sources...]
    local name=$1
    shift
    mkdir -p "$work/$name.app/Contents/MacOS"
    swiftc -O -wmo -parse-as-library -module-name carnival -target "$target" "$@" "$work/hook.o" \
        -o "$work/$name.app/Contents/MacOS/carnival" -framework AppKit -framework IOKit
    plist "$work/$name.app" "$name"
}

clone() {  # clone FROM TO: another copy of a build, to show the noise between processes
    cp -R "$work/$1.app" "$work/$2.app"
    plist "$work/$2.app" "$2"
}

extract() {  # extract FILE FROM TO: one MARK section of a carnival.swift
    sed -n "/^\/\/ MARK: - $2/,/^\/\/ MARK: - $3/p" "$1"
}

git show "$base_ref:carnival.swift" > "$work/before.swift"
bundle before "$work/before.swift"
bundle after carnival.swift
# floor: the working tree with its idle ticker never armed - what AppKit costs by itself
sed 's/idle\.run(true)//' carnival.swift > "$work/floor.swift"
bundle floor "$work/floor.swift"
for n in before after; do
    for i in 2 3; do clone "$n" "$n$i"; done
done
ls -l "$work"/*.app/Contents/MacOS/carnival

{ echo 'import Foundation; import IOKit; import os'; extract "$work/before.swift" metrics temperature; } \
    > "$work/m-before.swift"
{ echo 'import Foundation; import IOKit; import os'; extract carnival.swift metrics temperature
  extract carnival.swift sampling view; } > "$work/m-after.swift"
for side in before after; do  # the shims name 1.4's and 1.5's functions; other commits skip this
    swiftc -O -wmo -parse-as-library -target "$target" tools/bench/micro.swift \
        "tools/bench/micro-$side.swift" "$work/m-$side.swift" -o "$work/micro-$side" -framework IOKit \
        2> "$out/micro-$side.build.txt" || echo "micro-$side does not build against this commit, skipped" >&2
done

launch() {  # launch NAME [VAR=value...]; leaves the pid in $pid
    local name=$1
    shift
    env "$@" "$work/$name.app/Contents/MacOS/carnival" >> "$out/$name.log" 2>&1 &
    pid=$!
    pids="$pids $pid"
}

# --- idle ------------------------------------------------------------------------------
# Launches are staggered so the builds' 10 s ticks do not all land on the same instant.

: > "$out/idle.names"
for n in ${IDLE_SET:-before after before2 after2 before3 after3 floor}; do
    launch "$n"
    echo "$n $pid" >> "$out/idle.names"
    sleep 1.27
done
idle_pids=$(awk '{print $2}' "$out/idle.names")
sleep 60
"$work/probe" $idle_pids > "$out/idle0.txt"
sleep "$IDLE"
"$work/probe" $idle_pids > "$out/idle1.txt"
kill $idle_pids 2>/dev/null || true
wait 2>/dev/null || true
pids=""

# --- trace -----------------------------------------------------------------------------

if [ -n "$TRACE" ]; then
    for n in floor after; do
        launch "$n"
        sleep 30
        sudo dtrace -q -n "
            mach_trap:::entry /pid == $pid/ { @[probefunc, ustack(10)] = count(); }
            syscall:::entry /pid == $pid/ { @[probefunc, ustack(10)] = count(); }
            tick-120s { exit(0); }" > "$out/trace.$n.txt" 2>&1 || true
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    pids=""
fi

# --- menu open -------------------------------------------------------------------------
# t=20 s the menu opens, t=25 and t=25+OPEN the counters are read, t=30+OPEN it closes,
# t=65+OPEN the footprint is read once more.

: > "$out/open.names"
runs=""
i=1
while [ "$i" -le "$ROUNDS" ]; do runs="$runs before.$i after.$i"; i=$((i + 1)); done
for r in $runs; do
    n=${r%.*}
    launch "$n" CARNIVAL_BENCH_OPEN=20 CARNIVAL_BENCH_CLOSE=$((30 + OPEN))
    echo "$r $pid" >> "$out/open.names"
    sleep 25
    "$work/probe" "$pid" > "$out/open0.$r.txt"
    sleep "$OPEN"
    "$work/probe" "$pid" > "$out/open1.$r.txt"
    sleep 40
    "$work/probe" "$pid" > "$out/closed.$r.txt"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    grep -o 'draws=[0-9]*' "$out/$n.log" | tail -1 | cut -d= -f2 > "$out/draws.$r.txt" || true
done
pids=""

# --- micro -----------------------------------------------------------------------------

: > "$out/micro.txt"
for side in before after; do
    [ -x "$work/micro-$side" ] && "$work/micro-$side" "$side" >> "$out/micro.txt"
done
for side in before after; do  # once a second, the two side by side
    [ -x "$work/micro-$side" ] && "$work/micro-$side" "$side" cold > "$out/cold-$side.txt" &
    sleep 0.5
done
wait
cat "$out"/cold-*.txt >> "$out/micro.txt" 2>/dev/null || true

python3 tools/bench/report.py "$out" "$IDLE" "$OPEN" | tee "$out/report.md"
