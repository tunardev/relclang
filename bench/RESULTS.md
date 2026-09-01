# Benchmark results

Measured on an Apple M-series laptop with Zig 0.16.0. Reproduce with
`bench/run.sh`. Every program is built for release, and the three
implementations are checked against each other before timing.

## Run time, binary size and memory

Collatz to 300000. Pure arithmetic, struct field reads, a trait method
and a generic function. No allocation.

| target   | time  | binary | peak memory |
|----------|-------|--------|-------------|
| Relastic | 42 ms | 344 KB | 1520 KB |
| Zig      | 42 ms | 327 KB | 1504 KB |
| C        | 42 ms |  32 KB | 1344 KB |

Sieve of Eratosthenes to 2000000. Builds a two million entry list, so
this is the allocator working.

| target   | time  | binary | peak memory |
|----------|-------|--------|-------------|
| Relastic | 12 ms | 344 KB | 19312 KB |
| Zig      | 13 ms | 344 KB | 19312 KB |
| C        | 11 ms |  32 KB | 17008 KB |

Speed is the same in every case.

On the allocating benchmark the Relastic binary and its memory use match
hand written Zig exactly. A `Vec<Int>` is a Zig `ArrayList(i64)`, so
there is nothing added on top of it.

On the arithmetic benchmark Relastic is 17 KB larger than Zig. That is
the small runtime the compiler emits alongside your program, which holds
the printing helpers.

C is about ten times smaller in both cases because it does not carry
Zig's standard library. It also uses less memory in the sieve, because a
plain array is sized once and a growable list leaves room to grow.

## Compile time

Relastic is quick to compile and Zig is not. Building the same 6000 line
file:

| stage                        | time    | share |
|------------------------------|---------|-------|
| Relastic front end + codegen | 5 ms    | 0.3%  |
| `zig build-exe`              | 1616 ms | 99.7% |

Front end throughput, measured with `relc check`:

| lines  | time    |
|--------|---------|
| 3      | 5.9 ms  |
| 1005   | 5.0 ms  |
| 10005  | 9.1 ms  |
| 40005  | 25.7 ms |

About 5 ms of every run is process startup. Past that the front end
handles roughly 1.9 million lines a second and scales linearly, so
40000 lines cost about 20 ms of real work.

Almost all of a build is Zig. That is the price of using it as the
backend, and it is the strongest argument for a direct backend later.

Numbers above come from a `relc` built with `-Doptimize=ReleaseFast`. A
debug build of the compiler is roughly 80 times slower in the front end.
