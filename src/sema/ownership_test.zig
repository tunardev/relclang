const std = @import("std");
const source = @import("../support/source.zig");
const diagnostics = @import("../support/diagnostics.zig");
const compile = @import("../driver/pipeline.zig");

const testing = std.testing;

fn checkText(gpa: std.mem.Allocator, text: []const u8) !diagnostics.Diagnostics {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    var d: diagnostics.Diagnostics = .init(gpa);
    errdefer d.deinit();

    const file: source.SourceFile = .{ .path = "t.rls", .text = text };
    _ = try compile.toZig(arena_state.allocator(), gpa, file, &d);
    return d;
}

fn has(d: diagnostics.Diagnostics, code: diagnostics.Code) bool {
    for (d.list.items) |item| {
        if (item.code == code) return true;
    }
    return false;
}

const resource =
    \\struct R {
    \\    id: Int
    \\}
    \\
    \\fn take(r: R) -> Int {
    \\    r.id
    \\}
    \\
;

test "use after move reports E0028" {
    var d = try checkText(testing.allocator, resource ++
        \\fn main() {
        \\    let x = R { id: 1 }
        \\    let y = x
        \\    println(take(x))
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(has(d, .use_after_move));
}

test "copy types are never moved" {
    var d = try checkText(testing.allocator,
        \\fn main() {
        \\    let a = 5
        \\    let b = a
        \\    println(a + b)
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(!d.hasErrors());
}

test "an array of copy elements is copy" {
    var d = try checkText(testing.allocator,
        \\fn first(a: [Int; 2]) -> Int {
        \\    a[0]
        \\}
        \\fn main() {
        \\    let a = [1, 2]
        \\    println(first(a))
        \\    println(first(a))
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(!d.hasErrors());
}

test "a move inside one branch poisons the value afterwards" {
    var d = try checkText(testing.allocator, resource ++
        \\fn main() {
        \\    let x = R { id: 1 }
        \\    if true {
        \\        println(take(x))
        \\    }
        \\    println(take(x))
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(has(d, .use_after_move));
}

test "using a value in both branches is fine" {
    var d = try checkText(testing.allocator, resource ++
        \\fn main() {
        \\    let x = R { id: 1 }
        \\    if true {
        \\        println(take(x))
        \\    } else {
        \\        println(take(x))
        \\    }
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(!d.hasErrors());
}

test "moving an outer value inside a loop reports E0029" {
    var d = try checkText(testing.allocator, resource ++
        \\fn main() {
        \\    let x = R { id: 1 }
        \\    let mut i = 0
        \\    while i < 3 {
        \\        println(take(x))
        \\        i = i + 1
        \\    }
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(has(d, .move_in_loop));
}

test "a value created inside a loop may be moved each iteration" {
    var d = try checkText(testing.allocator, resource ++
        \\fn main() {
        \\    let mut i = 0
        \\    while i < 3 {
        \\        let x = R { id: i }
        \\        println(take(x))
        \\        i = i + 1
        \\    }
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(!d.hasErrors());
}

test "reassigning a moved binding restores it" {
    var d = try checkText(testing.allocator, resource ++
        \\fn main() {
        \\    let mut x = R { id: 1 }
        \\    println(take(x))
        \\    x = R { id: 2 }
        \\    println(take(x))
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(!d.hasErrors());
}

test "reading a copy field does not move the struct" {
    var d = try checkText(testing.allocator,
        \\struct R {
        \\    id: Int
        \\}
        \\fn main() {
        \\    let x = R { id: 7 }
        \\    println(x.id)
        \\    println(x.id)
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(!d.hasErrors());
}

test "moving a non copy field moves the whole value" {
    var d = try checkText(testing.allocator,
        \\struct Inner {
        \\    v: Int
        \\}
        \\struct Outer {
        \\    i: Inner
        \\}
        \\fn take(x: Inner) -> Int {
        \\    x.v
        \\}
        \\fn main() {
        \\    let o = Outer { i: Inner { v: 1 } }
        \\    println(take(o.i))
        \\    println(take(o.i))
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(has(d, .use_after_move));
}

test "matching a non copy payload moves the scrutinee" {
    var d = try checkText(testing.allocator, resource ++
        \\enum Box {
        \\    Full(R)
        \\    Empty
        \\}
        \\fn main() {
        \\    let b = Full(R { id: 1 })
        \\    let n = match b {
        \\        Full(r) => take(r)
        \\        Empty => 0
        \\    }
        \\    let m = match b {
        \\        Full(r) => take(r)
        \\        Empty => 0
        \\    }
        \\    println(n + m)
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(has(d, .use_after_move));
}

test "matching a copy payload only reads the scrutinee" {
    var d = try checkText(testing.allocator,
        \\enum N {
        \\    Some(Int)
        \\    None
        \\}
        \\fn main() {
        \\    let b = Some(5)
        \\    let x = match b {
        \\        Some(v) => v
        \\        None => 0
        \\    }
        \\    let y = match b {
        \\        Some(v) => v
        \\        None => 0
        \\    }
        \\    println(x + y)
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(!d.hasErrors());
}

test "a moved value cannot be returned twice" {
    var d = try checkText(testing.allocator, resource ++
        \\fn pass(r: R) -> R {
        \\    r
        \\}
        \\fn main() {
        \\    let x = R { id: 1 }
        \\    let a = pass(x)
        \\    let b = pass(x)
        \\    println(take(a) + take(b))
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(has(d, .use_after_move));
}

const counter =
    \\struct C {
    \\    v: Int
    \\}
    \\
    \\fn read(c: &C) -> Int {
    \\    c.v
    \\}
    \\
    \\fn take(c: C) -> Int {
    \\    c.v
    \\}
    \\
;

test "a shared borrow does not move" {
    var d = try checkText(testing.allocator, counter ++
        \\fn main() {
        \\    let c = C { v: 1 }
        \\    println(read(&c))
        \\    println(read(&c))
        \\    println(take(c))
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(!d.hasErrors());
}

test "many shared borrows coexist" {
    var d = try checkText(testing.allocator, counter ++
        \\fn main() {
        \\    let c = C { v: 1 }
        \\    let a = &c
        \\    let b = &c
        \\    println(read(a) + read(b))
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(!d.hasErrors());
}

test "a mutable borrow conflicts with a shared one" {
    var d = try checkText(testing.allocator, counter ++
        \\fn main() {
        \\    let mut c = C { v: 1 }
        \\    let a = &c
        \\    let b = &mut c
        \\    println(read(a))
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(has(d, .borrow_conflict));
}

test "two mutable borrows conflict" {
    var d = try checkText(testing.allocator, counter ++
        \\fn main() {
        \\    let mut c = C { v: 1 }
        \\    let a = &mut c
        \\    let b = &mut c
        \\    println(c.v)
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(has(d, .borrow_conflict));
}

test "moving while borrowed reports E0031" {
    var d = try checkText(testing.allocator, counter ++
        \\fn main() {
        \\    let c = C { v: 1 }
        \\    let r = &c
        \\    println(take(c))
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(has(d, .move_while_borrowed));
}

test "assigning while borrowed reports E0030" {
    var d = try checkText(testing.allocator, counter ++
        \\fn main() {
        \\    let mut c = C { v: 1 }
        \\    let r = &c
        \\    c = C { v: 2 }
        \\    println(c.v)
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(has(d, .borrow_conflict));
}

test "a mutable borrow of an immutable binding is rejected" {
    var d = try checkText(testing.allocator, counter ++
        \\fn main() {
        \\    let c = C { v: 1 }
        \\    let m = &mut c
        \\    println(c.v)
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(has(d, .immutable_assign));
}

test "mutating through a mutable reference is allowed" {
    var d = try checkText(testing.allocator, counter ++
        \\fn bump(c: &mut C) {
        \\    c.v = c.v + 1
        \\}
        \\fn main() {
        \\    let mut c = C { v: 1 }
        \\    bump(&mut c)
        \\    println(c.v)
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(!d.hasErrors());
}

test "references are copy so they can be passed twice" {
    var d = try checkText(testing.allocator, counter ++
        \\fn main() {
        \\    let c = C { v: 1 }
        \\    let r = &c
        \\    println(read(r) + read(r))
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(!d.hasErrors());
}

test "a vec is moved rather than copied" {
    var d = try checkText(testing.allocator,
        \\fn take(v: Vec<Int>) -> Int {
        \\    v.len()
        \\}
        \\fn main(alloc: Allocator) {
        \\    let v: Vec<Int> = Vec.new(alloc)
        \\    println(take(v))
        \\    println(v.len())
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(has(d, .use_after_move));
}

test "a vec used once is fine" {
    var d = try checkText(testing.allocator,
        \\fn main(alloc: Allocator) {
        \\    let v: Vec<Int> = Vec.new(alloc)
        \\    v.push(1)
        \\    println(v.len())
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(!d.hasErrors());
}

test "borrowing a vec does not move it" {
    var d = try checkText(testing.allocator,
        \\fn size(v: &Vec<Int>) -> Int {
        \\    v.len()
        \\}
        \\fn main(alloc: Allocator) {
        \\    let v: Vec<Int> = Vec.new(alloc)
        \\    println(size(&v))
        \\    println(size(&v))
        \\    println(v.len())
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(!d.hasErrors());
}

test "a vec can hold a struct" {
    var d = try checkText(testing.allocator,
        \\struct P {
        \\    x: Int
        \\}
        \\fn main(alloc: Allocator) {
        \\    let v: Vec<P> = Vec.new(alloc)
        \\    v.push(P { x: 1 })
        \\    println(v.len())
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(!d.hasErrors());
}

test "a struct can hold a vec" {
    var d = try checkText(testing.allocator,
        \\struct Bag {
        \\    items: Vec<Int>
        \\}
        \\fn main(alloc: Allocator) {
        \\    let b = Bag { items: Vec.new(alloc) }
        \\    b.items.push(1)
        \\    println(b.items.len())
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(!d.hasErrors());
}

test "pushing a vec into a vec moves it" {
    var d = try checkText(testing.allocator,
        \\fn main(alloc: Allocator) {
        \\    let inner: Vec<Int> = Vec.new(alloc)
        \\    let rows: Vec<Vec<Int>> = Vec.new(alloc)
        \\    rows.push(inner)
        \\    println(inner.len())
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(has(d, .use_after_move));
}

test "a string builds and prints without moving" {
    var d = try checkText(testing.allocator,
        \\fn main(alloc: Allocator) {
        \\    let s: String = String.new(alloc)
        \\    s.push("n = ")
        \\    s.push_int(7)
        \\    println(s)
        \\    println(s.len())
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(!d.hasErrors());
}

test "an unannotated vec cannot be inferred" {
    var d = try checkText(testing.allocator,
        \\fn main(alloc: Allocator) {
        \\    let v = Vec.new(alloc)
        \\    println(1)
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(has(d, .cannot_infer));
}

test "main may take an allocator or nothing" {
    var with = try checkText(testing.allocator, "fn main(alloc: Allocator) {\n    println(1)\n}\n");
    defer with.deinit();
    try testing.expect(!with.hasErrors());

    var without = try checkText(testing.allocator, "fn main() {\n    println(1)\n}\n");
    defer without.deinit();
    try testing.expect(!without.hasErrors());

    var bad = try checkText(testing.allocator, "fn main(n: Int) {\n    println(n)\n}\n");
    defer bad.deinit();
    try testing.expect(has(bad, .bad_signature));
}

test "returning a reference to a local reports E0036" {
    var d = try checkText(testing.allocator,
        \\struct R {
        \\    id: Int
        \\}
        \\fn dangle() -> &R {
        \\    let local = R { id: 1 }
        \\    &local
        \\}
        \\fn main() {
        \\    println(dangle().id)
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(has(d, .escaping_reference));
}

test "returning a local reference through a binding reports E0036" {
    var d = try checkText(testing.allocator,
        \\struct R {
        \\    id: Int
        \\}
        \\fn dangle() -> &R {
        \\    let local = R { id: 1 }
        \\    let r = &local
        \\    r
        \\}
        \\fn main() {
        \\    println(dangle().id)
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(has(d, .escaping_reference));
}

test "passing a reference straight through is allowed" {
    var d = try checkText(testing.allocator,
        \\struct R {
        \\    id: Int
        \\}
        \\fn pass(r: &R) -> &R {
        \\    r
        \\}
        \\fn main() {
        \\    let x = R { id: 1 }
        \\    println(pass(&x).id)
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(!d.hasErrors());
}

test "a struct cannot store a reference" {
    var d = try checkText(testing.allocator,
        \\struct Holder {
        \\    r: &Int
        \\}
        \\fn main() {
        \\    println(1)
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(has(d, .reference_field));
}

test "an enum cannot store a reference" {
    var d = try checkText(testing.allocator,
        \\enum Holder {
        \\    Some(&Int)
        \\}
        \\fn main() {
        \\    println(1)
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(has(d, .reference_field));
}

test "growing a vec while an element is borrowed reports E0030" {
    var d = try checkText(testing.allocator,
        \\fn main(alloc: Allocator) {
        \\    let rows: Vec<Vec<Int>> = Vec.new(alloc)
        \\    let a: Vec<Int> = Vec.new(alloc)
        \\    rows.push(a)
        \\    let first = rows.get(0)
        \\    let b: Vec<Int> = Vec.new(alloc)
        \\    rows.push(b)
        \\    println(first.len())
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(has(d, .borrow_conflict));
}

test "growing a vec with no live borrow is allowed" {
    var d = try checkText(testing.allocator,
        \\fn main(alloc: Allocator) {
        \\    let v: Vec<Int> = Vec.new(alloc)
        \\    v.push(1)
        \\    v.push(2)
        \\    println(v.get(0))
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(!d.hasErrors());
}

test "returning a local reference with return reports E0036" {
    var d = try checkText(testing.allocator,
        \\fn f() -> &Int {
        \\    let x = 1
        \\    return &x
        \\}
        \\fn main() {
        \\    let r = f()
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(has(d, .escaping_reference));
}

test "returning a local reference from an if reports E0036" {
    var d = try checkText(testing.allocator,
        \\fn f(c: Bool, p: &Int) -> &Int {
        \\    let x = 1
        \\    if c { p } else { &x }
        \\}
        \\fn main() {
        \\    let n = 1
        \\    let r = f(true, &n)
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(has(d, .escaping_reference));
}

test "returning a local reference from a match reports E0036" {
    var d = try checkText(testing.allocator,
        \\enum E {
        \\    A
        \\    B
        \\}
        \\fn f(e: E, p: &Int) -> &Int {
        \\    let x = 1
        \\    match e {
        \\        A => p
        \\        B => &x
        \\    }
        \\}
        \\fn main() {
        \\    let n = 1
        \\    let r = f(A, &n)
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(has(d, .escaping_reference));
}

test "returning a reference into a local vec reports E0036" {
    var d = try checkText(testing.allocator,
        \\fn f(alloc: Allocator) -> &String {
        \\    let v: Vec<String> = Vec.new(alloc)
        \\    v.push(String.new(alloc))
        \\    v.get(0)
        \\}
        \\fn main(alloc: Allocator) {
        \\    let r = f(alloc)
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(has(d, .escaping_reference));
}

test "returning a reference into a vec parameter is allowed" {
    var d = try checkText(testing.allocator,
        \\fn first(v: &Vec<String>) -> &String {
        \\    v.get(0)
        \\}
        \\fn main(alloc: Allocator) {
        \\    let v: Vec<String> = Vec.new(alloc)
        \\    v.push(String.new(alloc))
        \\    println(first(&v))
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(!d.hasErrors());
}

test "returning a local reference through a call reports E0036" {
    var d = try checkText(testing.allocator,
        \\fn same(r: &Int) -> &Int {
        \\    r
        \\}
        \\fn f() -> &Int {
        \\    let x = 1
        \\    same(&x)
        \\}
        \\fn main() {
        \\    let r = f()
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(has(d, .escaping_reference));
}

test "a binding that may point at a local cannot be returned" {
    var d = try checkText(testing.allocator,
        \\fn f(c: Bool, p: &Int) -> &Int {
        \\    let x = 1
        \\    let r = if c { p } else { &x }
        \\    r
        \\}
        \\fn main() {
        \\    let n = 1
        \\    let r = f(true, &n)
        \\}
        \\
    );
    defer d.deinit();
    try testing.expect(has(d, .escaping_reference));
}
