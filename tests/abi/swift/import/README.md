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
symbols, ownership, lowering, and runtime search paths. Temporary Swift inspection
source, SIL and LLVM IR are build inputs only; none is linked into the application.
They are removed unless `-keep-temp-files` is enabled.

## Supported subset

The importer supports `Int64`, `UInt64`, `Double`, synchronous String results,
and synchronous or asynchronous procedures with those arguments. String inputs
become ordinary Odin `string` parameters. An asynchronous String result is not
yet exposed: a failed UTF-8 allocation after completion needs a separate error
contract from Swift `throws`.

Copyable, escapable resilient structs and enums use typed addresses backed by
Swift metadata. Constructors, methods, getters, nested types and concrete
single-parameter enum specializations are supported when inspection confirms
their native calling convention. `Type_copy` creates an independent owned value;
`Type_destroy` destroys and frees it. Assignment aliases the same address.
Factory procedures return `(value, ok) #optional_ok`. Nonmutating asynchronous
receivers and arguments are copied before start returns. A mutating receiver is
borrowed through completion, so its changes reach the original value. Do not
access or destroy that receiver while the call is outstanding.

`Type_case` identifies an enum case, including `Unknown_Default` for newer
resilient cases. `Type_get_case` copies a supported single payload without
consuming the enum. A payload returned as an owned Swift value needs its own
destruction. Multi-value case extraction and arbitrary generic specialization
are not implemented. Optional values are inspected with the same case/payload
operations; they are not confused with allocation failure.

Swift arrays are owned typed values with `_count`, bounds-checked `_get`,
`_copy` and `_destroy`. Element access creates an owned copy. A `[String]` input
accepts `[]string` and copies every element. One supported generic specialization
accepts a single `Collection<String>` argument using Swift `Array<String>`
metadata and its standard Collection conformance. This does not implement Odin
protocol conformances or general Swift generics. An explicit empty `Set` default
on a single-parameter function may be omitted; nonempty Set construction is
not supported.

Asynchronous untyped `throws` adds an owned `swift.Error` to the completion.
A nil error means success; on failure the result is zero-initialized. Release
the error with `swift.error_release`, or retain it explicitly if another owner
needs it. Start rejection still means no callback. Synchronous and typed throws
remain unsupported. Async MainActor procedures execute on the main executor;
this does not add an actor or async/await system to Odin.

Full argument-label names distinguish declarations, and a unique supported
procedure also gets its short name. Unsupported or ambiguous declarations are
omitted and diagnosed when referenced. The importer verifies both native LLVM
lowering and SIL ownership conventions; it does not infer ownership from a
pointer or assume that a Swift constructor borrows its arguments. SDK availability
is checked against the deployment target; runtime availability guards are not
synthesized.

A macOS host with Xcode, a Darwin arm64 target and LLVM 18 or newer are required.
The importer accepts API-digester JSON format 8 and rejects unfamiliar lowering.
Cached builds are rejected until external module dependencies are tracked.

## Memory and callbacks

Native scalar arguments and supplied user data are copied into Swift-owned task
storage before the start returns. User data can be scalars, distinct IDs, enums,
pointers, fixed arrays, or records of those, aligned to at most eight bytes.
Dynamic containers and strings are not accepted as user data; this restriction
does not apply to imported Swift function parameters. Copying a pointer does not
retain its pointee or extend its lifetime. The same applies to pointers nested
inside a copied record.

Completions run once on the main executor with a copy of the caller's Odin
context. Referenced allocators and other context data remain borrowed and must
survive completion. Swift owns and frees the task and its async frames. Nothing
needs releasing for a generated ID. A GUI application's main run loop delivers
callbacks; a command-line program must keep that loop running while work remains.

The storage around an owned resilient value remembers the Odin allocator that
created it, even when destruction uses a different context. Its contents retain
Swift ownership: copying and destruction use value witnesses, and internal Swift
allocations still belong to Swift. An Odin arena cannot replace Swift's heap.
Any arena used for outer storage or saved callback context must remain alive
until those allocations and callbacks are finished.

## Strings

An ordinary Swift declaration:

```swift
public func decorate(_ text: String) -> String { "[" + text + "]" }
```

is called using ordinary Odin strings:

```odin
text := example.decorate("café 🦉") or_return
defer delete(text)
```

The bridge copies valid UTF-8 into an owned Swift string. It delivers a returned
Swift string as an Odin-owned UTF-8 copy using `context.allocator`; free that
copy with the same allocator. An async call copies its input before returning,
so the original Odin bytes may then be modified or freed. Conversion preserves
embedded zero bytes and rejects invalid UTF-8 before calling the imported
function. Conversion or Odin allocation failure returns `ok = false`.

Conversion uses Swift standard-library ABI entry points to validate and construct
an owned String, count its UTF-8 bytes and copy them into Odin storage. Swift
validates input directly; there is no separate Odin validation pass. Destruction
uses Swift's native string release operation without a type-metadata lookup. It does not use
Foundation, NSString or an autorelease pool. The native string representation is
passed through without decoding its small-string flags or object storage. Swift
allocation failures are governed by Swift's runtime; the boolean result does not
make all foreign allocations recoverable. This does not extend the current
Darwin arm64 target support to other platforms.

Text retains its UTF-8 contents. Odin `len(string)` counts bytes and Odin string
equality compares bytes; Swift's character count and canonically equivalent
Unicode equality are different operations. A plain Odin string does not gain
Swift's character semantics.

See `run.sh`, `main.odin`, `values.odin` and `strings.odin` for executable round
trips, overlapping tasks, generated/custom IDs, preserved context, guarded
allocations, ownership, failure paths and rejection diagnostics.

The separate `../strings/run.sh` fixture checks Foundation-free linkage,
standard-library strings in both directions, independent storage after owner
release, invalid UTF-8 and failed allocation. It also checks the trailing-byte
aggregate ABI used by Swift's UTF-8 copy result.
