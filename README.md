# Relastic

A systems programming language. Source files use the `.rls` extension.

Relastic compiles to native code. The compiler is written in Zig and
currently generates Zig, which is then compiled to a binary.

## Status

Very early. Right now it handles functions with parameters and return
types, `let` bindings, integers, strings and arithmetic:

    fn add(a: Int, b: Int) -> Int {
        a + b
    }

    fn main() {
        println(add(3, 4))
    }

The last line of a function body is its return value. There is no
`return` keyword yet.

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
