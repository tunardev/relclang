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

The last line of a function body is its return value. There is no
`return` keyword yet. Arrays have a fixed length that is part of their
type, written `[Int; 3]`. Slices do not exist yet. Every `match` must
cover all variants, or end with a `_` arm.

There is one integer type, `Int`, which is 64 bits and signed. Division
truncates toward zero and dividing by zero stops the program. Bindings
are immutable and cannot be redeclared in the same scope.

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
