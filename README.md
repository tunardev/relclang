# Relastic

A systems programming language. Source files use the `.rls` extension.

Relastic compiles to native code. The compiler is written in Zig and
currently generates Zig, which is then compiled to a binary.

## Status

Very early. Right now it compiles this and nothing more:

    fn main() {
        println("Hello, Relastic!")
    }

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
