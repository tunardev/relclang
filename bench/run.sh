#!/bin/sh
set -e

cd "$(dirname "$0")"
RELC=../zig-out/bin/relc

echo "building"
$RELC build collatz.rls --release -o collatz_rls > /dev/null
zig build-exe collatz.zig -OReleaseFast -femit-bin=collatz_zig > /dev/null
cc -O2 collatz.c -o collatz_c

echo "checking they agree"
a=$(./collatz_rls)
b=$(./collatz_zig 2>&1)
c=$(./collatz_c)
[ "$a" = "$b" ] && [ "$a" = "$c" ] || { echo "outputs differ"; exit 1; }
echo "$a" | tr '\n' ' '
echo

echo "timing, best of 5"
for name in rls zig c; do
  best=999999
  for i in 1 2 3 4 5; do
    s=$(date +%s%N)
    ./collatz_$name > /dev/null 2>&1
    e=$(date +%s%N)
    d=$(( (e - s) / 1000000 ))
    [ $d -lt $best ] && best=$d
  done
  printf '  %-4s %4d ms\n' "$name" "$best"
done
