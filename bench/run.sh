#!/bin/sh
set -e

cd "$(dirname "$0")"
RELC=../zig-out/bin/relc

size_of() {
  if stat -f%z "$1" > /dev/null 2>&1; then stat -f%z "$1"; else stat -c%s "$1"; fi
}

peak_kb() {
  if [ "$(uname)" = "Darwin" ]; then
    /usr/bin/time -l "$1" 2>&1 >/dev/null | awk '/maximum resident/ {print int($1/1024)}'
  else
    /usr/bin/time -v "$1" 2>&1 >/dev/null | awk '/Maximum resident/ {print $6}'
  fi
}

bench() {
  name=$1

  $RELC build $name.rls --release -o ${name}_rls > /dev/null
  zig build-exe $name.zig -OReleaseFast -femit-bin=${name}_zig > /dev/null
  cc -O2 $name.c -o ${name}_c

  a=$(./${name}_rls)
  b=$(./${name}_zig 2>&1)
  c=$(./${name}_c)
  [ "$a" = "$b" ] && [ "$a" = "$c" ] || { echo "$name: outputs differ"; exit 1; }

  printf '\n%s  (all agree: %s)\n' "$name" "$(echo "$a" | tr '\n' ' ')"
  printf '%-12s %8s %10s %11s\n' "target" "time" "binary" "peak rss"

  for kind in rls zig c; do
    bin=${name}_${kind}
    best=999999
    for i in 1 2 3 4 5; do
      s=$(date +%s%N)
      ./$bin > /dev/null 2>&1
      e=$(date +%s%N)
      d=$(( (e - s) / 1000000 ))
      [ $d -lt $best ] && best=$d
    done

    strip -o ${bin}_s $bin 2>/dev/null || cp $bin ${bin}_s
    printf '%-12s %5d ms %7d KB %8d KB\n' \
      "$kind" "$best" "$(( $(size_of ${bin}_s) / 1024 ))" "$(peak_kb ./$bin)"
    rm -f ${bin}_s
  done
}

bench collatz
bench sieve
