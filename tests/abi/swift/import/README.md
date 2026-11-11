# Swift module imports

Import a compiled Swift module with a foreign import:

```odin
foreign import example "swift:Example"
```

The compiler discovers supported public declarations and their native ABI.
There are no handwritten ABI declarations, Swift shims, function lists, or
separate generator commands for the caller. The original Swift library is
linked directly.

For example, an ordinary Swift library can contain:

```swift
public func add(_ value: UInt64, _ delta: UInt64) -> UInt64 {
	value &+ delta
}

public func addLater(_ value: UInt64, _ delta: UInt64) async -> UInt64 {
	await Task.yield()
	return value &+ delta
}
```

Place `Example.swiftmodule` and either `Example.o` or `libExample.a` beside the
Odin source. A relative module path, such as `"swift:swift-lib/Example"`, selects
another directory. Having both binary forms is ambiguous and is diagnosed.
Without a local library/module, a bare module name selects an SDK framework.
Use a target-specific source file or `#+build` constraint for platform-dependent
imports: imports are resolved during parsing.

Swift names become snake case, so `addLater` becomes `add_later`:

```odin
value := example.add(17, 9)
id, ok := example.add_later(17, 9, finished)

finished :: proc(id: swift.Request_Id, result: u64) {
	// Use id to correlate this completion with the accepted start.
}
```

Import `swift "core:sys/darwin/Swift"` for `Request_Id`. Omitting user data
requests a generated nonzero ID. Supplying data copies and returns that value
instead, without generating an extra ID:

```odin
Book_Id :: distinct u64

id, ok := example.add_later(17, 9, Book_Id(73), book_finished)

book_finished :: proc(id: Book_Id, result: u64) {
	// id is 73.
}
```

Both forms return `(id, ok) #optional_ok`. The second result may be omitted;
that does not assert success. A procedure returning a suitable boolean result
can propagate a rejected start using the existing `or_return` operator:

```odin
start :: proc() -> bool {
	id := example.add_later(17, 9, finished) or_return
	// Record id before returning to the main run loop.
	return true
}
```

`ok` reports whether the start was accepted, not whether a later operation
succeeded. On failure the ID is zero-initialized and no callback runs. Zero is
valid as supplied data, so check `ok` when that distinction matters. Generated
IDs do not wrap or repeat within a linked copy of the support package; exhaustion
rejects the start. They are correlation values, not retained task handles, and
do not provide cancellation or access to completed task storage.

Build normally with `odin build app -minimum-os-version:15.0`. For iOS, use
`-target:darwin_arm64`, `-subtarget:iphone` or `-subtarget:iphonesimulator`, and
libraries built for that target. Xcode tools supply the SDK, declarations,
symbols, lowering, and runtime search paths. Temporary Swift inspection source
and LLVM IR are build inputs only; neither is linked into the application.
They are removed unless `-keep-temp-files` is enabled.

## Supported subset

The initial importer supports nonthrowing free functions with `Int64`, `UInt64`
and `Double` arguments and one such result or no result, synchronous or async.
It also supports nonmutating, nonthrowing, zero-argument async methods returning
Void on nongeneric top-level Swift structs, when inspection verifies an indirect
borrowed receiver. These are named `Type_method`. Their receiver is a distinct
typed address of an existing Swift value, not a declaration of its storage
layout. This subset does not construct, copy or destroy resilient Swift values.
Keep a receiver alive through completion; nil receivers reject the start.

Unsupported or ambiguous declarations are omitted and diagnosed when referenced.
The importer does not guess ABI layouts. Generics, throwing calls, actor-isolated
functions, arbitrary Swift value types, and general overload resolution remain
outside this subset. SDK availability is checked against the deployment target;
this version does not synthesize runtime availability guards.

A macOS host with Xcode, a Darwin arm64 target and LLVM 18 or newer are required.
The importer accepts API-digester JSON format 8 and rejects unfamiliar lowering.
Cached builds are rejected until external module dependencies are tracked.

## Memory and callbacks

Native scalar arguments and supplied user data are copied into Swift-owned task
storage before the start returns. User data can be scalars, distinct IDs, enums,
pointers, fixed arrays, or records of those, aligned to at most eight bytes.
Dynamic containers and strings are not accepted. Copying a pointer does not
retain its pointee or extend its lifetime. The same applies to pointers nested
inside a copied record.

Completions run once on the main executor with a copy of the caller's Odin
context. Referenced allocators and other context data remain borrowed and must
survive completion. Swift owns and frees the task and its async frames. Nothing
needs releasing for a generated ID. A GUI application's main run loop delivers
callbacks; a command-line program must keep that loop running while work remains.

See `run.sh` and `main.odin` for executable scalar round trips, overlapping tasks,
copied records, borrowed pointers, generated/custom IDs, optional results,
`or_return`, preserved context, lifetimes and rejection diagnostics.
