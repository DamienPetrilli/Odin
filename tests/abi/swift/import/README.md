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
task, ok := example.add_later(17, 9, finished)
if ok {
	// Store task, or release it now if no further control is needed.
	swift.task_release(task)
}

finished :: proc(task: swift.Task, result: u64) {
	// task is borrowed here; it identifies the same native operation.
}
```

Import `swift "core:sys/darwin/Swift"` for `Task` and its lifetime operations.
Starts return `(task, ok) #optional_ok`. The existing `or_return` operator works:

```odin
start :: proc() -> bool {
	task := example.add_later(17, 9, finished) or_return
	defer swift.task_release(task)
	// This example deliberately requests cancellation before returning.
	swift.task_cancel(task)
	return true
}
```

`ok` reports whether the start was accepted, not whether the operation later
succeeded. A rejected start returns nil, false and no callback runs. Omitting
`ok` does not assert success. There is no generated ID or custom callback payload.
Use the native task handle to identify application-owned records.

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

Swift `[UInt64]`, `[Int64]`, `[Double]` and `[String]` parameters and results map
to ordinary Odin `[]u64`, `[]i64`, `[]f64` and `[]string`. Inputs are copied into
Swift-owned storage before the call (or async start) returns. Results are
independent copies allocated using `context.allocator`. Delete a returned scalar
slice; for `[]string`, delete each string and then the slice with that allocator.
An empty result is a successful empty slice. Nested arrays are not yet supported.

Swift array allocation capacity is obtained through Swift's buffer-size ABI,
including usable spare storage, so imported arrays follow native Swift growth.
The growth fixture compares both capacity and buffer relocations with native
construction under the same runtime/allocator. No platform malloc-size API is
called directly by the bridge.

For example, a Swift `func increment(_ values: [UInt64]) -> [UInt64]` is called as:

```odin
values := example.increment([]u64{1, 2, 3}) or_return
defer delete(values)
```

An async array result adds a final conversion `ok` to its callback:
`proc(task: swift.Task, values: []u64, ok: bool)`. With Swift `throws`, the signature
is `proc(task: swift.Task, values: []u64, error: swift.Error, ok: bool)`. Conversion
failure gives an empty slice and `ok = false`; partial copies are cleaned up.
A Swift error also gives `ok = false`, with the owned error set. A successful
start and successful result conversion are separate events. Allocators captured
by the start must remain valid through completion and result deallocation.

Arrays of supported imported value types retain the owned typed-value API:
`_count`, bounds-checked `_get`, `_copy` and `_destroy`. Element access creates an
owned copy. One supported generic specialization accepts a single
`Collection<String>` argument using Swift `Array<String>` metadata and its
standard Collection conformance. This does not implement Odin protocol
conformances or general Swift generics. An explicit empty `Set` default on a
single-parameter function may be omitted; nonempty Set construction is not supported.

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

Native scalar arguments are copied into Swift-owned task storage before start
returns. Nontrivial imported inputs follow the copy/borrow rules below. Each
successful start returns one owned native task reference. Copying `Task` copies
its address without retaining; `swift.task_retain` acquires another reference,
and `swift.task_release` drops one. No extra object or ID table is allocated by
the bridge. Addresses can be reused after final release.

Completion borrows the same task handle. It may retain that handle beyond the
callback, but must not release the borrowed reference itself. Releasing a reference
owned by application storage during completion is valid. Execution independently
keeps the task alive, even when the caller releases its reference before completion.
A retained completed task does not keep the bridge's copied inputs alive.

`swift.task_cancel` requests cooperative cancellation. It may synchronously run
Swift cancellation handlers; release locks those handlers might acquire before
calling it. `swift.task_is_cancelled` reports the request, not completion. An
operation may ignore cancellation and succeed. Cancellation and release neither
wait nor suppress completion; completion runs once if the operation returns.
Each concurrent user must have a live reference throughout its accesses.

Completions run on the main executor with a copy of the caller's Odin context.
Referenced allocators and context data stay borrowed and must survive completion.
Mutating receivers likewise remain exclusively borrowed through completion.
Cancellation does not permit early teardown of any of these resources. Swift
owns the task and its async frames. A GUI application's main run loop delivers
callbacks; a command-line program must keep that loop running. Starts from the
main thread can register their returned handles before returning to the run loop.
From other threads completion can race with start returning; synchronize shared
application storage accordingly. Cancellation is not a synchronization barrier.

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
uses Swift's native string release operation without a type-metadata lookup. It
does not use Foundation, NSString or an autorelease pool. Small strings copy their
inline UTF-8 using the frozen Darwin arm64 layout. Large contiguous strings use
Swift's borrowed-buffer getter; foreign strings retain the native transcoding
path. No borrowed pointer escapes the conversion. Swift allocation failures are
governed by Swift's runtime; the boolean result does not make all foreign
allocations recoverable. This does not extend the current Darwin arm64 target
support to other platforms.

Text retains its UTF-8 contents. Odin `len(string)` counts bytes and Odin string
equality compares bytes; Swift's character count and canonically equivalent
Unicode equality are different operations. A plain Odin string does not gain
Swift's character semantics.

See `run.sh`, `main.odin`, `values.odin`, `strings.odin`, `arrays.odin` and
`tasks.odin` for executable round trips, overlapping tasks, native handle identity,
preserved context, guarded allocations, ownership, failure paths and rejection
diagnostics.

The separate `../strings/run.sh` fixture checks Foundation-free linkage,
standard-library strings in both directions, independent storage after owner
release, invalid UTF-8 and failed allocation. It also checks the trailing-byte
aggregate ABI used by Swift's UTF-8 copy result.

## iOS simulator execution

`run.sh iphonesimulator debug` (or `release`) links the fixtures without running
them. To also execute the normal library and evolved static-library tests, supply
a booted simulator's identifier:

```sh
SWIFT_TEST_SIMULATOR="<device-identifier>" bash tests/abi/swift/import/run.sh iphonesimulator release
```

The script leaves device creation, boot and cleanup to its caller. Each fixture
has a 60-second process deadline; an assertion, crash or timeout fails the run.
Compiler rejection tests continue to run in the macOS invocation. The separate
`../strings/run.sh` also honors `SWIFT_TEST_SIMULATOR` for its UTF-8 round trips.
