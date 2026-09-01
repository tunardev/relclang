# Relastic

A systems programming language. Source files use the `.rls` extension.

Relastic compiles to native code. The compiler is written in Zig and
currently generates Zig, which is then compiled to a binary.

## Status

Very early. Right now it handles functions, `let` bindings, integers,
strings, arithmetic, structs and fixed size arrays:

    struct Point {
        x: Int
        y: Int
    }

    fn dist2(a: Point, b: Point) -> Int {
        let dx = a.x - b.x
        let dy = a.y - b.y
        dx * dx + dy * dy
    }

    fn main() {
        let a = Point { x: 10, y: 20 }
        let b = Point { x: 15, y: 25 }
        println(dist2(a, b))

        let nums = [3, 1, 4]
        println(nums[0])
    }

It also has enums with associated values and pattern matching:

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

Values are owned. Structs and enums move when you pass them; integers,
booleans, strings and references copy. Using a value after it moved is
a compile error:

    let a = Point { x: 1, y: 2 }
    let b = a
    println(a.x)      # error: use of moved value `a`

Borrow it instead with `&` or `&mut`:

    fn dist2(a: &Point, b: &Point) -> Int { ... }
    fn bump(p: &mut Point) { p.x = p.x + 1 }

A value can have many shared borrows or one mutable borrow, never both.

Functions, structs and enums can be generic, and traits describe what a
type can do:

    trait Show {
        fn show(self) -> Str
    }

    impl Show for User {
        fn show(self) -> Str {
            self.name
        }
    }

    fn announce<T: Show>(x: T) -> Str {
        x.show()
    }

Generic code is compiled separately for each type it is used with, so
calls are direct. Type arguments are worked out from the arguments you
pass; there is no way to write them at a call site yet.

`?` unwraps the first variant of an enum and returns the second one
from the enclosing function, which is how errors travel:

    fn quarter(n: Int) -> Result<Int, Str> {
        let half = halve(n)?
        halve(half)
    }

The last line of a function body is its return value, and `return` exits
early. Arrays have a fixed length that is part of their type, written
`[Int; 3]`. Slices do not exist yet. Every `match` must cover all
variants, or end with a `_` arm.

There is one integer type, `Int`, which is 64 bits and signed. Division
truncates toward zero and dividing by zero stops the program. Bindings
are immutable and cannot be redeclared in the same scope.

## What it compiles to

Relastic is compiled, not interpreted. The compiler works out what your
program means, then writes Zig, and Zig turns that into a binary.

`examples/showcase.rls` uses every part of the language, and
`examples/showcase.generated.zig` is exactly what the compiler produces
for it. A test regenerates that file and fails if the two ever disagree,
so it always shows real output.

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

Generic types are compiled into real ones, so `Result<Int, Str>` becomes
a plain tagged union. Traits become direct calls. Borrows become
pointers, because the compiler has already proved they are safe.

To see it for any file of your own:

    relc emit-zig myfile.rls

## Build

You need Zig 0.16.0.

    zig build

## Use

    relc build hello.rls
    ./hello

Other commands:

    relc run hello.rls       build and run
    relc check hello.rls     report errors only
    relc emit-zig hello.rls  print the generated Zig
    relc version

## Test

    zig build test
    zig build cases
