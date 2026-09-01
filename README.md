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

The same Collatz workload, written three times and built for release:

| implementation   | time  |
|------------------|-------|
| Relastic         | 42 ms |
| Zig, by hand     | 42 ms |
| C, clang -O2     | 42 ms |

Generic code is compiled once per type and trait calls are direct, so
there is nothing left at run time for the optimiser to trip over.
Run `bench/run.sh` to reproduce it.

Compiling is fast on the Relastic side and slow on the Zig side:

| stage                        | time  | share |
|------------------------------|-------|-------|
| Relastic front end + codegen  | 6 ms  | 0.4%  |
| `zig build-exe`               | 1594 ms | 99.6% |

The front end handles about 1.7 million lines a second and scales
linearly. Startup is 3.7 ms, so small files feel instant. Almost all of
a build is Zig, which is the price of using it as the backend.

## Status

This is an experiment, and it is honest about its size.

Working: functions, generics, traits, structs, enums, pattern matching,
fixed size arrays, ownership, borrow checking, `if`, `while`, and clear
error messages.

Missing: there is no way to allocate memory yet. That means no growable
lists, no joining strings, no reading input, and no linked structures.
Every program is limited to fixed size data and printing. There are also
no modules, so a program is a single file, and no standard library, so
`println` is the only thing the compiler gives you.

The ownership rules are the groundwork for allocation, so this is the
next real step rather than a rewrite.

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
