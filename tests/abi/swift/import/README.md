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

## Inspecting the bindings

Run `odin check app -show-swift-imports` with the same target and minimum OS version as the application. Standard output lists each inspected module, the accepted Swift declarations and their Odin procedure signatures, short aliases, projected types, and reasons for skipped bindings. The report uses the declarations emitted for that target, including both forms of a defaulted Set argument. Declarations absent from Swift's module inspection data cannot appear in the report.

Each async entry describes ownership of the returned task, the callback's borrowed handle, and any result cleanup. Use the allocator that owns a returned string or slice. A lookup fallback explains what happens when no accepted binding matches a selector. A rejected overload can share a selector with a callable overload.

## Names

Swift type identity comes from compiler identifiers, not display names. A user
type named `UInt64`, `Void`, or `GenericTypeParam` remains a user type. Generated
Swift probes qualify standard types and escape nominal type references.

Procedures and parameters that would shadow Odin builtins gain a trailing
underscore, for example Swift `len` becomes `len_`. Types that conflict with
names used by generated Odin code are currently rejected. Flattened nested types,
projected container names, ownership helpers and enum cases must also be unique.
An ambiguous name produces an import diagnostic instead of selecting a different
declaration. A labeled procedure keeps its full name when its optional short alias
would conflict with a helper, for example `Item_copy_amount` alongside `Item_copy`.
Explicit import-name overrides are outside this subset.

## Supported subset

The importer supports `Bool`, `Int`, `UInt`, `Int64`, `UInt64`, `Double` and
`String` arguments and results in synchronous or asynchronous procedures. Strings
become ordinary Odin `string` values. Async String completions report output
conversion separately from Swift `throws` and from acceptance of the start.

`Bool`, `Int` and `UInt` use native Odin `bool`, `int` and `uint`, including
scalar async completions, getters and optionals. Int and UInt are 64-bit on the
supported Darwin arm64 target. Int/UInt arrays use `[]int`/`[]uint` with the same
copy/ownership rules as the other scalar arrays. Bool arrays remain outside this subset.

Swift `Float` and signed and unsigned 8-, 16-, and 32-bit integers import directly
as `f32`, `i8/u8`, `i16/u16`, and `i32/u32` in synchronous and asynchronous
procedures. Their optional, array and record mappings need separate layout checks.

A synchronous `UnsafeBufferPointer<T>` or `UnsafeMutableBufferPointer<T>`
parameter accepts an ordinary Odin slice of a supported numeric scalar or bool.
The call passes its address and count directly. Swift writes through a mutable
buffer reach the original Odin elements. A nil slice is an empty buffer.
`UnsafePointer<T>` and `UnsafeMutablePointer<T>` take a non-nil `^T`.
Keep the storage alive for the lifetime documented by the Swift callee. The
importer rejects async capture and returned views for these borrowed types.

Copyable, escapable resilient structs use typed addresses backed by Swift
metadata. Struct constructors, methods, getters and nested types are supported when
inspection confirms their native calling convention. `Type_copy` creates an independent owned value;
`Type_destroy` destroys and frees it. Assignment aliases the same address.
Factory procedures return `(value, ok) #optional_ok`. Nonmutating asynchronous
receivers and arguments are copied before start returns. A mutating receiver is
borrowed through completion, so its changes reach the original value. Do not
access or destroy that receiver while the call is outstanding.

Plain frozen structs with public stored `Bool`, `UInt64`, `Int64`, `UInt`, `Int` and `Double` fields
map to ordinary Odin structs. Empty structs are also supported. The importer
checks every field offset, value size, array stride, alignment and native call lowering using
the target Swift compiler. Unsupported or hidden fields retain opaque storage;
`@frozen` alone does not establish a direct mapping. Field names use snake case,
and ambiguous field names are diagnosed.

```swift
@frozen public struct Point {
	public var x: Double
	public var y: Double
}
public func echoPoint(_ value: Point) -> Point { value }
public func echoPoints(_ values: [Point]) -> [Point] { values }
```

```odin
point := example.Point{x = 10, y = 20}
assert(example.echo_point(point) == point)
points := example.echo_points([]example.Point{point}) or_return
defer delete(points)
points[0].x = 30
```

These records copy by value and need no record destroy helper. Record arrays
contain contiguous inline values and require only the slice's ordinary `delete`.
The native array retains its own copy; changing the Odin result does not change
Swift storage. Output uses `context.allocator` without redundant zeroing. Runtime
metadata must also confirm POD, size, stride and alignment before bulk copying.
Swift's zero-sized record stride is handled independently of Odin's zero size.
Bool fields use ordinary Odin `bool`. Adjacent Bool fields can share a native
register; the compiler packs and unpacks their bytes. Swift value size can omit
trailing padding included in Odin's size. Field access preserves that boundary,
while arrays use the verified common stride. No extra owner is needed.

Sync and async free functions, supported constructors, optional/enum payloads,
and direct/indirect record arguments/results are checked. Async inputs are copied
before start returns. Native record instance methods, nested records, other smaller
fields and custom alignment are outside this direct
subset. Odin field assignment edits a local value, including fields declared
`let` in Swift; direct construction does not run a Swift initializer or enforce
its application invariants.

Frozen Swift enums with no associated values map to ordinary Odin `enum u32`
types. Cases use an initial capital, so Swift `case running` becomes `.Running`.
They have ordinary value-copy semantics and need no copy/destroy helpers. The
compiler converts their case tags to the inspected native width, including a
zero-sized single case; it does not pass the Odin enum's storage as Swift storage.
Nonfrozen enums still use unions with an owned `Unknown` alternative, even when
today's cases have no payload.

```swift
@frozen public enum Mode { case idle, running }
public func echoMode(_ value: Mode) -> Mode { value }

@frozen public enum Code: UInt64 { case first = 10, second = 20 }
```

```odin
mode := example.echo_mode(.Running)
assert(mode == .Running)
code, present := example.Code_init_raw_value(20).?
assert(present && code == .Second)
assert(example.Code_init_raw_value(11) == nil)
```

Raw values are distinct from ABI case tags: `u32(code)` above is the case tag,
not the Swift raw value 20. Supported failable initializers preserve `Maybe(T)`;
a valid absent result is not a failed conversion. Initializers with owned inputs
or results additionally report conversion success using the existing boolean.
Enum instance getters/methods, including `rawValue`, remain outside this subset.
Known native tag widths are checked from the Swift compiler; unfamiliar lowering
is rejected. Names that collide after case conversion are diagnosed.

Swift optionals map to native `Maybe(T)`, including nested optionals, strings,
supported slices and projected enums. Supported associated-value enums map to
native unions with a named struct per case. Two or more variants use `#no_nil`.
A frozen enum with one payload case uses an ordinary union; its extra Odin nil
state is not a Swift case. Conversion and copying reject nil; destruction is a
no-op for nil. Multiple payloads
become fields; labels are preserved in snake case, with `value` for a single
unlabeled payload or `value_0`, `value_1`, etc. for multiple unlabeled payloads.
Cases with identical payload types still have distinct case structs. Concrete
single-parameter enum specializations and their nested error enums are supported
when all payloads and their lowering are supported. Enum instance members,
recursive/indirect enums, noncopyable values and existential payloads are outside
this subset. Deeper optional nesting whose lowering needs an unsupported integer
width is also diagnosed; `Maybe(Maybe(u64))` is covered by the fixture. Empty namespace enums are not projected as values.

For example, this ordinary Swift declaration:

```swift
@frozen public enum Lookup {
	case found(UInt64)
	case missing
	case rejected(code: UInt64, message: String)
}
public func echoLookup(_ value: Lookup) -> Lookup { value }
public func nextPage(_ page: UInt64?) -> UInt64? { page.map { $0 &+ 1 } }
```

is used directly from Odin:

```odin
page: Maybe(u64) = u64(41)
next := example.next_page(page)
if value, present := next.?; present {
	assert(value == 42)
}

// Input text is borrowed; the returned result owns its converted payload.
input: example.Lookup = example.Lookup_Rejected{7, "Café 📚"}
result := example.echo_lookup(input) or_return
defer example.Lookup_destroy(result)

switch item in result {
case example.Lookup_Found:
	// item.value
case example.Lookup_Missing:
case example.Lookup_Rejected:
	// item.code and item.message are borrowed from result here.
}
```

These are value conversions, not casts between Swift and Odin union layouts.
The importer verifies native size and register components. Scalar optionals use
verified inline storage without allocating or resolving metadata on each call.
Other enum layouts use Swift's metadata and destructive projection/injection
witnesses. Multi-field offsets come from native tuple metadata. Concrete metadata
lookups are cached safely across threads. No Swift adapter is linked.

A nonfrozen enum additionally exposes `Type_Unknown`, containing a typed opaque
owner of the unrecognized native value. `Type_copy`, `Type_destroy` and passing
that value back to Swift preserve its payload, including cases added by a newer
library. An unsupported known case is diagnosed rather than silently dropped.

`Type_destroy` recursively cleans the active owned payload. Assignment, a type
assertion or a switch binding performs an ordinary Odin copy, without implicit
retaining or deep copying. Clean up the original owned result once. Use
`Type_copy(result)` for an independent owner; if keeping only a nested imported
value, use that value's own copy procedure before destroying the parent.
Hand-constructed inputs containing borrowed strings/slices are not owned results:
do not destroy a borrowed literal or buffer. The optional allocator on projected
copy/destroy helpers defaults to `context.allocator`; use the allocator which
owns the Odin string/slice storage. Opaque native owners remember their allocator.

A scalar optional returns `Maybe(T)` directly. A conversion that can allocate
returns `(Maybe(T), bool) #optional_ok`: absent with `ok = true` is a valid Swift
nil; `ok = false` is a conversion failure. Present empty strings and zero values
remain present. A nested optional preserves each level of absence.

Async allocating enum/optional results add a conversion boolean to completion,
just like arrays: `proc(task: swift.Task, result: example.Lookup, ok: bool)`.
With untyped Swift throws, an owned module `Async_Error` replaces the boolean;
only a nil error makes the result usable.
Only a successful conversion transfers an owned result to the callback. Failed
conversions clean all partially constructed fields; a thrown error leaves no
result to destroy. Trivial async scalar optionals need no conversion boolean.
Inputs are copied before async start returns, and callback results are independent
of the completed Swift call frame. These rules do not change native task lifetime
or cancellation.

Swift `[UInt64]`, `[Int64]`, `[UInt]`, `[Int]`, `[Double]` and `[String]` parameters
and results map to ordinary Odin `[]u64`, `[]i64`, `[]uint`, `[]int`, `[]f64` and
`[]string`. Inputs are copied into
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
is `proc(task: swift.Task, values: []u64, err: example.Async_Error)`.
Conversion failure gives an empty slice and `swift.Result_Conversion_Failed`;
partial copies are cleaned up. A thrown Swift error becomes a concrete or
fallback union case. Only `err == nil` transfers a usable result. A successful
start and successful result conversion are separate events. Allocators captured
by the start must remain valid through completion and result deallocation.

Arrays of supported imported structs, enums and optional values also map to
native slices: `[Value]` becomes `[]example.Value`, `[Lookup]` becomes
`[]example.Lookup`, and `[Value?]` becomes `[]Maybe(example.Value)`. The importer
emits an `Array_Value` slice alias and `Array_Value_copy`/`Array_Value_destroy`
helpers, likewise for other imported element types. Ordinary indexing borrows
an element; it does not make an independent owner. Ordinary assignment aliases
both slices and their owned contents.

```odin
values := example.make_values(3) or_return
defer example.Array_Value_destroy(values)
for value in values {
	use_value(value)
}
copy := example.Value_copy(values[0]) or_return
defer example.Value_destroy(copy)
```

`Array_Value_destroy` destroys each owned element and frees the slice. Pass the
slice's original allocator if the current allocator has changed. Element owners
remember their allocator. `delete(values)` alone frees only the slice: use that
when ownership of every element has been transferred elsewhere. To move one
element, take it and clear its original slot before destroying the remaining
array. Destroy a moved element once, or use the element's `_copy` helper when
both places need independent ownership. A borrowed subslice must not be passed
to the array destroy helper, since it does not own the slice allocation.

Resilient structs keep their existing typed native-value address representation;
this does not claim their Swift memory layout matches an Odin struct. Opaque
output elements share one backing allocation, in addition to the slice allocation.
A one-element result instead uses the ordinary standalone value allocation.
Each slot owns a Swift value independently. Moving one slot out keeps the backing
block alive until the last slot is destroyed, even after the slice is deleted.
Enum/optional projections own their payloads under the same rules as standalone
values; they may require additional allocations. Array copying is linear and
creates independent owners, unlike Swift's copy-on-write array assignment. Swift's
copy semantics still apply to references inside an element; copying an element
does not recursively clone referenced objects.

Inputs initialize Swift-owned storage using the element's native runtime stride
and copy operation. An owned result may transfer opaque elements with Swift's
initialize-with-take witness when the exact native allocation type is known and
Swift confirms unique ownership. Shared and borrowed arrays copy their elements;
the source remains intact. Both Odin output allocations complete before any
transfer, so allocation failure leaves the native result available for normal
cleanup. The native array is released after conversion. Projected results clean
any initialized prefix on failure. Zero-sized values use the runtime stride, not
zero. These choices preserve the same independent Odin ownership in either case.
The async callback and conversion boolean follow the scalar array rules above.
Arrays within supported enum/optional payloads work; direct nested arrays,
recursive enums and unsupported element types remain rejected.

One supported generic specialization accepts a single
`Collection<String>` argument using Swift `Array<String>` metadata and its
standard Collection conformance. This does not implement Odin protocol
conformances or general Swift generics. An explicit empty `Set` default on a
single-parameter function may be omitted; a second overload accepts an explicit
slice of candidates. See Set inputs below.

Asynchronous untyped `throws` adds the module's native `Async_Error` union to the
completion. Nil means success with a usable result; non-nil means no result to
destroy. The union includes supported concrete Error enums and explicit fallbacks
for unknown errors or conversion failures. The callback owns it: use
`Async_Error_destroy` once, transfer it, or use `Async_Error_copy` for another owner.
Start rejection still means no callback. Synchronous and typed throws remain
unsupported. Async MainActor procedures execute on the main executor; this does
not add an actor or async/await system to Odin.

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

## External Date values

External `Foundation.Date` maps to `swift.Date`, an ordinary Odin `distinct f64`
containing seconds since 2001-01-01 00:00:00 UTC. Imported modules alias the same
canonical type. `Date?` maps to `Maybe(swift.Date)` and `[Date]` to `[]swift.Date`.
The value needs no destruction. This preserves Swift's precision and range;
`core:time.Time` has a narrower range and cannot represent subnanosecond values.
Conversion to another epoch or time representation is an explicit application choice.

```swift
import Foundation
public func echoDate(_ value: Date) -> Date { value }
```

```odin
value := example.echo_date(swift.Date(0)) or_return
assert(value == 0) // 2001-01-01, not the Unix epoch.
```

The compiler inspects the native getter and initializer. It constructs and destroys
resilient Swift storage through the original ABI, rather than interpreting Swift
memory as a Double. Synchronous temporary storage uses checked inline capacity
with allocation fallback. Complete Date metadata and its checked temporary layout
are initialized once, following Odin global initialization dependencies. Destruction
is skipped only when Swift metadata identifies a trivially destructible value;
nontrivial values retain native destruction. Async native storage survives suspension. This bounded
mapping recognizes Foundation.Date's compiler identity, not any type named Date.
It does not add automatic Date exports or UUID/Decimal/Data projections.

## Frozen records with string fields

Flat frozen records with public stored String and the supported scalar fields
use ordinary Odin structs. Native String storage stays private to the conversion.
Supported optional, enum-payload, slice and async forms use the same ownership rules.

```swift
@frozen public struct Book {
    public var title: String
    public var pages: Int
    public init(_ title: String, _ pages: Int) {
        self.title = title; self.pages = pages
    }
}
public func echoBook(_ value: Book) -> Book { value }
```

```odin
input := example.Book{title = "Café 📚", pages = 73}
book := example.echo_book(input) or_return
defer example.Book_destroy(book)
copy := example.Book_copy(book) or_return
defer example.Book_destroy(copy)
assert(copy.title == input.title)
```

Inputs borrow Odin fields and construct independent native fields. Returned strings
belong to the caller's allocator. Copy creates independent owned fields; assignment
only copies descriptors. Destroy an owned result once, using its allocation's
allocator. A literal or borrowed input does not become owned just because its type
has a destroy helper. Partial conversion failures destroy initialized fields.
Async callbacks receive an independently owned record plus a conversion boolean;
these fields may outlive the callback/task, but their allocator must remain valid.

Record literals initialize a fresh native value and do not call a Swift initializer.
The caller must respect any application-level field invariants. This does not mutate
Swift let properties on a live instance. Hidden fields, nested/array fields, direct
record instance methods and automatic exports of Odin string records remain outside
this subset. They are not accepted by assuming equal byte sizes.

## Callback errors

An untyped throwing callback receives the generated module's `Async_Error`, an
ordinary nil-capable Odin union. It contains the module's supported concrete Error
enums, using their existing enum/union representations, and three fallback types:

| Case | Meaning and ownership |
| --- | --- |
| `nil` | Swift returned successfully and the Odin result is usable. |
| Imported concrete error type | Independent native Odin enum or owned payload union. |
| `swift.Unknown_Error` | Owned `.error` box for an unmapped, private or unsupported type. |
| `swift.Error_Conversion_Failed` | Matching concrete type could not be projected; owned original `.error` box is preserved. |
| `swift.Result_Conversion_Failed` | Swift returned successfully, but copying the result failed; no error box or result owner. |

Only use/destroy the result when the error is nil. The callback owns the error
union independently of the task. `defer example.Async_Error_destroy(err)` releases
its active payload; `Async_Error_copy` creates an independent owner. Assignment
only aliases owners. Copy/destroy accept the allocator used for Odin strings/slices;
opaque native owners remember their allocator. Unknown and failed-projection
fallbacks retain the original box when copied, without allocating Odin storage.

```swift
@frozen public enum Failure: Error { case missing, denied }
public func lookup() async throws -> UInt64 { throw Failure.missing }
```

```odin
lookup_received :: proc(task: swift.Task, value: u64, err: example.Async_Error) {
	defer example.Async_Error_destroy(err)
	if err == nil {
		// Use value.
		return
	}
	switch failure in err {
	case example.Failure:
		messages := [example.Failure]string {
			.Missing = "Missing item",
			.Denied = "Access denied",
		}
		message := messages[failure]
		// Present the application's message.
	case swift.Unknown_Error:
		// failure.error remains available for diagnostics.
	case swift.Error_Conversion_Failed:
		// failure.error preserves the original error for diagnostics or retry.
	case swift.Result_Conversion_Failed:
		// A successful Swift result could not be copied to Odin.
	}
}
```

Payload errors select their native Odin union within `Async_Error`; switch on that
value to access associated strings or other data. Destroying the outer union cleans
those payloads. Frozen payload-free errors are native enums, suitable for ordinary
enumerated arrays. Nonfrozen errors preserve unknown future cases in their existing
owned `Type_Unknown` alternative. A future error type not known at build time becomes
`swift.Unknown_Error`, so untyped throws never assumes a closed set of types.

The union contains all supported Error enums in the imported module, not a guessed
per-function throw list. Its names (`Async_Error`, `Async_Error_copy`,
`Async_Error_destroy`) must not collide with Swift declarations. No Swift shim,
new attribute or application-written ABI declaration is required.

## Low-level error inspection

Fallback `.error` boxes can be inspected without consuming them.
`swift.error_type_name` and `swift.error_description` return independently owned
Odin strings via `(string, bool) #optional_ok`. Delete the returned strings; the
outer error union still owns its box. Nil or output-allocation failure returns
false. Descriptions follow Swift `String(describing:)`, including custom descriptions.
Names and descriptions are diagnostic text, not stable codes or localized messages.
These operations use the Swift runtime and standard library, including runtime
handling of bridged errors; they introduce no Foundation conversion dependency.

`Type_from_error(error) -> (value: Type, err: swift.Error_Cast_Error)` remains an
explicit inspection/recovery helper. It borrows the box and tests exact metadata:
`nil` means an independent concrete value, `.Type_Mismatch` means nil or another
type, and `.Conversion_Failed` means matching data could not be copied. Use/destroy
its output only on nil status. Normal callbacks already perform this projection;
application code need not call the helper to handle a supported error type.
It is not Swift's broader bridging cast behavior. Error structs, unsupported
payloads, synchronous throws and typed throws remain outside the projection subset;
thrown values with those unsupported representations survive as owned fallbacks.

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
function. Input conversion failure rejects the call; synchronous output conversion
or Odin allocation failure returns `ok = false`.

Async results use the same callback convention as other converted results:

```swift
public func decorateLater(_ text: String) async -> String {
	await Task.yield()
	return "[" + text + "]"
}
```

```odin
start :: proc() -> bool {
	task := example.decorate_later("café 🦉", received) or_return
	defer swift.task_release(task)
	return true
}

received :: proc(task: swift.Task, text: string, converted: bool) {
	if !converted { return }
	defer delete(text)
	assert(text == "[café 🦉]")
}
```

The callback runs with the captured Odin context. Successful output is independently
owned and may outlive the callback and task; free it with the captured allocator.
The native Swift result remains alive through conversion and is released before
the callback, including when Odin allocation fails. An empty result succeeds with
`converted = true` and needs no Odin allocation.

For `async throws -> String`, the callback is
`proc(task: swift.Task, text: string, err: example.Async_Error)`.
A thrown Swift error produces empty text and an owned error-union case. A successful
Swift return followed by output conversion failure produces empty text and
`swift.Result_Conversion_Failed`. Only nil err transfers an owned string. Neither failure
changes the already accepted start or suppresses its completion. Cancellation
follows the existing cooperative task contract; it can produce either an error
or a successful result, depending on the Swift function.

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

See `run.sh`, `main.odin`, `values.odin`, `enums.odin`, `strings.odin`,
`async_strings.odin`, `arrays.odin`, `value_arrays.odin`, `records.odin`, `mixed_records.odin`,
`scalars.odin` and `tasks.odin` for executable round trips, overlapping tasks, native handle identity,
preserved context, guarded allocations, ownership, failure paths and rejection
diagnostics.

The separate `../strings/run.sh` fixture checks Foundation-free linkage,
standard-library strings in both directions, independent storage after owner
release, invalid UTF-8 and failed allocation. It also checks the trailing-byte
aggregate ABI used by Swift's UTF-8 copy result.

## UUID values

`Foundation.UUID` maps to `core:encoding/uuid.Identifier`, including optional
values, array elements and asynchronous results. Imported `UUID` names alias the
same core type across modules. All sixteen bytes are preserved, including a
present all-zero identifier; it is distinct from an absent optional.

```swift
import Foundation
public func echoIdentifier(_ value: UUID) -> UUID { value }
public func identifierLater(_ value: UUID) async -> UUID { value }
```

```odin
foreign import example "swift:Example"
import "core:encoding/uuid"
import swift "core:sys/darwin/Swift"

id := uuid.Identifier{15 = 42}
copy := example.echo_identifier(id) or_return
task := example.identifier_later(copy, received) or_return
swift.task_release(task)

received :: proc(task: swift.Task, value: uuid.Identifier) {
	// An independent plain value; no per-value destroy or release.
	use_identifier(value)
}
```

The compiler inspects the SDK's native byte getter and initializer. It does not
assume Swift's resilient UUID has Odin's byte-array layout, use text conversion,
or bridge through NSUUID. Native temporary size/alignment and destruction follow
Swift metadata. Async input is initialized before start returns; output bytes are
copied before native result/frame cleanup. Odin assignment copies the identifier.
A returned `[]uuid.Identifier` owns only its slice allocation: `delete(values)`
is sufficient. Optional results use `Maybe(uuid.Identifier)`.

UUID belongs to Foundation, so APIs using it depend on that Swift module. This
mapping does not add Foundation to generic String conversion or extend the
current Darwin arm64 support to Linux. UUID fields inside imported records and
UUID methods/initializers are outside this initial projection. See `uuids.odin`
for value, optional, union, slice, async, cancellation and allocation-failure tests.

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

Swift inspection retains Xcode's module cache under
`$TMPDIR/odin-swift-module-cache` (using the system temporary directory if
`TMPDIR` is unset). Swift validates cached modules against their dependencies
and toolchain. Odin still extracts and checks the current API, native lowering,
ownership, and exported symbols on every invocation; generated Odin declarations
are not reused across builds. `-show-more-timings` reports each inspection tool's
elapsed time. The module cache can be removed when no builds are using it; Swift
recreates it on demand.

For the reverse direction, see [Swift-facing Odin exports](../export/README.md).

## Set inputs

A supported Swift `Set<T>` parameter accepts an ordinary Odin slice. Swift's
Hashable conformance determines uniqueness, including custom equality and
canonically equivalent Strings. Odin does not sort, mutate or deduplicate the
caller's slice.

```swift
public func uniqueCount(_ values: Set<UInt64>) -> UInt64 {
    UInt64(values.count)
}
```

```odin
foreign import example "swift:Example"
count := example.unique_count([]u64{7, 7, 9}) or_return
assert(count == 2)
```

The initial subset accepts the supported scalar, String, UUID, record and owned
value element mappings used by arrays, when the concrete Swift type conforms to
Hashable. Bool elements, nested Sets, Set results, inout parameters and automatic
Set exports are outside this subset. This does not expose general Swift protocol
conformance from Odin. A Swift `Set` is not layout-compatible with an Odin slice.

The generated code resolves the concrete Swift Hashable conformance. Nontrivial
members use Swift's native literal constructor, which consumes a converted Array.
The supported 64-bit scalars initialize fresh Swift-owned Set storage directly,
after the compiler checks the SDK's fixed layout and calling conventions and the
runtime checks the actual allocation. Hashing and equality call Swift's concrete
implementations, including Double's signed-zero and NaN behavior. Unrecognized
layouts retain the literal-constructor path. No borrowed or shared native storage
is mutated, and no Swift inspection code is linked.

The caller retains its input ownership. A synchronous call releases the temporary
Set afterward; a consuming Swift initializer receives its ownership. Async starts
complete conversion before returning, so the caller may then destroy its input
owners, strings and slice. The task holds the native Set through completion and
releases it before the Odin callback. A failed conversion releases initialized
values and any earlier converted arguments; no callback runs after a failed start.

See `sets.odin` for duplicate removal, custom equality with colliding hashes,
input preservation, consuming initialization, failure cleanup and async lifetimes.
