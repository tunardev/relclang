# Relastic

[![ci](https://github.com/tunardev/relclang/actions/workflows/ci.yml/badge.svg)](https://github.com/tunardev/relclang/actions/workflows/ci.yml)

A small systems language with ownership, borrow checking, generics and
traits. It compiles to Zig, and Zig compiles that to a native binary.

The compiler catches this before your program ever runs:

```
error[E0028]: use of moved value `x`

   --> main.rls:12:21
    |
 12 |     println(consume(x))
    |                     ^ value used here after move
    |
help: `x` has type `Resource`, which is moved rather than copied
```

## Try it

You need Zig 0.16.0.

    git clone https://github.com/tunardev/relclang
    cd relclang
    zig build

    ./zig-out/bin/relc run examples/fizzbuzz.rls

Other commands:

    relc build hello.rls     write a binary
    relc run hello.rls       build and run
    relc check hello.rls     report errors only
    relc emit-zig hello.rls  print the generated Zig

## The language

Functions, structs, enums and pattern matching:

    struct Point {
        x: Int
        y: Int
    }

    enum Shape {
        Circle(Int)
        Rect(Int, Int)
    }

    fn area(s: Shape) -> Int {
        match s {
            Circle(r) => r * r * 3
            Rect(w, h) => w * h
        }
    }

Every `match` has to cover all variants, or end with a `_` arm.

Values are owned. Structs and enums move when you pass them. Integers,
booleans, strings and references copy. Borrow instead of moving with
`&` and `&mut`:

    fn distance(a: &Point, b: &Point) -> Int { ... }
    fn shift(p: &mut Point) { p.x = p.x + 1 }

A value can have many shared borrows, or one mutable borrow, never both.

Generics and traits, resolved at compile time:

    trait Show {
        fn show(self) -> Str
    }

    impl Show for Point {
        fn show(self) -> Str {
            "a point"
        }
    }

    fn announce<T: Show>(value: &T) -> Str {
        value.show()
    }

`?` unwraps the first variant of an enum and returns the second one from
the enclosing function, which is how errors travel:

    enum Result<T, E> {
        Ok(T)
        Err(E)
    }

    fn quarter(n: Int) -> Result<Int, Str> {
        let half = halve(n)?
        halve(half)
    }

`Result` is not built in. You write it yourself, and `?` works with any
enum shaped like it.

The last line of a function body is its return value. `return` exits
early.

## What it compiles to

Relastic is compiled, not interpreted. The compiler works out what your
program means, then writes Zig.

`examples/showcase.rls` uses every part of the language, and
`examples/showcase.generated.zig` is exactly what the compiler produces
for it. A test regenerates that file and fails if the two disagree, so
it always shows real output.

This Relastic:

    fn doubled(p: &Point) -> Result<Int, Str> {
        let m = checked(p)?
        Ok(m * 2)
    }

becomes this Zig:

    fn rc_doubled(v0_p: *const S0_Point) rt.Error!E0_Result_Int_Str {
        const v1_m = b0: {
                switch ((try rc_checked(v0_p))) {
                    .v0_Ok => |__t| break :b0 __t.f0,
                    .v1_Err => |__e| return E0_Result_Int_Str{ .v1_Err = __e },
                }
        };
        return E0_Result_Int_Str{ .v0_Ok = .{ .f0 = (v1_m * @as(i64, 2)) } };
    }

Generic types become real ones, so `Result<Int, Str>` is a plain tagged
union. Traits become direct calls, with no lookup at run time. Borrows
become pointers, because the compiler already proved they are safe.

Run `relc emit-zig` on any file to see this for yourself.

## Speed

Relastic compiles through Zig, so the question is whether that costs
anything. It does not.

Two workloads, each written three times and built for release. The first
is pure arithmetic, the second builds a two million element list, so it
also shows what the allocator costs.

Collatz, no allocation:

| target   | time  | binary | peak memory |
|----------|-------|--------|-------------|
| Relastic | 42 ms | 344 KB | 1536 KB |
| Zig      | 42 ms | 327 KB | 1504 KB |
| C        | 42 ms |  32 KB | 1344 KB |

Sieve of Eratosthenes, two million entries:

| target   | time  | binary | peak memory |
|----------|-------|--------|-------------|
| Relastic | 13 ms | 344 KB | 19312 KB |
| Zig      | 12 ms | 344 KB | 19312 KB |
| C        | 12 ms |  32 KB | 17008 KB |

Speed is the same everywhere. On the allocating test the Relastic binary
and its memory use match hand written Zig exactly, because a `Vec<Int>`
is a Zig `ArrayList(i64)` and nothing is added on top. C is smaller
because it does not carry Zig's standard library, and it uses less
memory because a plain array does not leave room to grow.

Generic code is compiled once per type and trait calls are direct, so
there is nothing left at run time for the optimiser to trip over.
Run `bench/run.sh` to reproduce all of it.

Compiling is fast on the Relastic side and slow on the Zig side:

| stage                        | time    | share |
|------------------------------|---------|-------|
| Relastic front end + codegen | 6 ms    | 0.4%  |
| `zig build-exe`              | 1594 ms | 99.6% |

The front end handles about 1.7 million lines a second and scales
linearly. Startup is 3.7 ms, so small files feel instant. Almost all of
a build is Zig, which is the price of using it as the backend.

## Status

This is an experiment, and it is honest about its size.

Working: functions, generics, traits, structs, enums, pattern matching,
fixed size arrays, ownership, borrow checking, `if`, `while`, and clear
error messages.

Memory is allocated explicitly. `main` can ask for an allocator, and
`Vec<T>` grows at run time:

    fn main(alloc: Allocator) {
        let v: Vec<Int> = Vec.new(alloc)
        v.push(1)
        v.push(2)
        println(v.len())
    }

A `Vec` frees itself when its scope ends. If you pass it to a function
the function owns it, and frees it instead. The compiler works out which
of the two happens, so nothing is freed twice and you never write the
free yourself.

Missing: `Vec` elements have to be copied types, so `Vec<Int>` and
`Vec<Str>` work but `Vec<Point>` does not yet. Structs and enums cannot
hold a `Vec`, because nested cleanup is not implemented. There is no
growable string, no way to read input, and no modules, so a program is a
single file.

## Design

Relastic has its own meaning, and Zig is a target it happens to use
today. The compiler decides what your program means first, and only then
writes Zig. The code generator can only see the typed representation,
never the syntax tree, and a test enforces that. Another backend could
replace it without touching the language.

## Build and test

    zig build
    zig build test
    zig build cases

## License

MIT
