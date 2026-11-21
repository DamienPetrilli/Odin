# Swift-facing Odin exports

A static library containing `@(export)` procedures with the `"swift"` calling
convention automatically produces its Swift module. Build it normally:

```sh
odin build math -build-mode:static -out:build/libOdinMath.a
swiftc -I build main.swift build/libOdinMath.a -o build/example
```

For an Odin package named `math`:

```odin
package math

@(export)
add_numbers :: proc "swift" (a, b: u64) -> u64 {
	return a + b
}
```

The Swift client needs only:

```swift
import OdinMath

let result = addNumbers(17, 9)
```

The module name defaults to `Odin` followed by the package name in UpperCamelCase:
`image_tools` becomes `OdinImageTools`. `-swift-module-name:Name` overrides it.
Procedure names become lowerCamelCase, and struct names become UpperCamelCase.
Names that collide after conversion are rejected. Swift keyword type names are
escaped in both declarations and signatures. A type named `Swift`, or matching
the selected module name, is rejected because it would shadow a module. User link
names must not overlap generated entry points or Swift metadata symbols. Only
explicitly exported `proc "swift"` procedures in the initial package appear in
the interface. C/ordinary Odin exports and unexported Swift callbacks retain their
existing behavior and do not enter that interface. Other build modes
do not generate a Swift module. Build exports for Darwin arm64 on a macOS host with Xcode and LLVM 18 or newer.

The compiler emits a static archive, `.swiftmodule`, and `.swiftinterface` beside
the requested output. The latter allows Swift to rebuild the module interface
when necessary. Generated declarations refer directly to Odin's native Swift-ABI
entry points; callers write no ABI declarations or Swift forwarding code. For
exported structs, the archive also contains Swift-generated type metadata and
memberwise initializers. This is needed for normal Swift value construction and
reflection. Application procedures execute in Odin.

## Values and memory

This subset supports `proc "swift"` with 8-, 16-, 32-, and 64-bit signed and unsigned
integer scalars, `int`, `uint`, `f32`, `f64`, `bool`, and flat
named structs containing `bool`, `i64`, `u64`, `int`, `uint`, and `f64`. A procedure can return one such value or two to four numeric or Bool results
as a Swift tuple. Named Odin results become lowerCamelCase tuple labels. Struct fields preserve their order and offsets. Swift value size,
array stride and register/indirect lowering are checked separately. Packed, aligned, nested, or nontrivial structs
are rejected. Scalar parameters use their corresponding Swift scalar types;
structs become frozen Swift value types. Bool fields may be mixed with the
supported 64-bit scalars. The Swift compiler verifies field offsets, size, stride
and native register lowering; indirect results preserve Swift tail padding. Values are passed using the native ABI.

Input slices of the supported native numeric scalars and `bool` become
`UnsafeMutableBufferPointer<Element>`. Swift owns the storage; Odin borrows it
only for the call. The entry point passes the same address and count and makes
no buffer allocation or element copy. Odin must not free or retain this storage.
Swift's usual exclusive-access and buffer-lifetime rules apply:

```odin
@(export)
modify_values :: proc "swift" (values: []u64, delta: u64) {
	for &value in values {
		value += delta
	}
}
```

```swift
var values: [UInt64] = [10, 20, 30]
values.withUnsafeMutableBufferPointer { buffer in
	modifyValues(buffer, 7)
}
// values == [17, 27, 37]
```

`core:encoding/uuid.Identifier` parameters and results become `Foundation.UUID`:

```odin
package identifiers
import "core:encoding/uuid"

@(export)
echo_identifier :: proc "swift" (id: uuid.Identifier) -> uuid.Identifier {
	return id
}
```

```swift
import Foundation
import OdinIdentifiers

let id = UUID()
precondition(echoIdentifier(id) == id)
```

This recognizes the exact core type, including aliases, rather than treating any
`[16]u8` as a UUID. The generated entry reads borrowed Swift parameters through
the verified byte getter and initializes Swift's result through its initializer.
The Odin body receives an independent sixteen-byte value with no per-value
cleanup. This does not promise a fixed layout for native Swift UUID storage.
The initial subset covers direct parameters/results, not UUID fields, optional
or array exports. Low-level handwritten `foreign` UUID declarations are rejected;
use the importer for calls into Swift. A module or exported type named `Foundation`
is rejected when UUID is present because it would shadow the required module.

A synchronous exported `string` parameter appears as `Swift.String`. The
Odin procedure borrows its UTF-8 bytes until it returns. Small strings use
the entry's inline storage. Large contiguous strings use Swift's buffer.
A foreign string requiring transcoding uses temporary storage released by
the entry after the call. Clone a string that must outlive the procedure.
Embedded zero bytes are preserved.

Scalar `Maybe(T)` parameters and results become Swift optionals. The element
can be an exported numeric scalar or `bool`. A present zero or false remains
distinct from nil. Conversion uses registers and local value storage. The
compiler checks the SDK's calling convention and case encodings for each
element type before emitting the module.

String results, owned collections, slice results, closures, generics, async exports,
and throwing exports are outside this subset and receive diagnostics. Swift
calling Odin is a separate direction from the richer existing Swift importer.
Default argument values are not exported; Swift callers supply every argument.

`proc "swift"` keeps its existing foreign calling convention: no implicit Odin
context is passed. Procedures needing allocators or context-dependent diagnostics
establish their context explicitly:

```odin
import "base:runtime"

@(export)
check_value :: proc "swift" (value: u64) {
	context = runtime.default_context()
	assert(value > 0)
}
```

The compiler initializes Odin globals and
`@(init)` procedures before the Swift host's main and runs `@(fini)` at shutdown.
The application's own thread-safety rules still apply. One exported Odin root
owns runtime state per executable: combine required Odin packages in that build.
Linking independently exported roots is rejected rather than merging unrelated
runtime initializers. This initial packaging targets Swift-hosted static
libraries; it does not emit a framework bundle or SwiftPM manifest. The consumer
must also link any external libraries required by the Odin package.

Run `bash tests/abi/swift/export/run.sh macosx debug` (or `release`). iPhone and
simulator targets use `iphoneos` and `iphonesimulator`. Set
`SWIFT_TEST_SIMULATOR` to an already booted, caller-owned device to execute the
simulator tests. `SWIFT_TEST_ASAN=1` instruments both languages with Apple's
matching AddressSanitizer toolchain, compiling Odin's LLVM bitcode with clang.
