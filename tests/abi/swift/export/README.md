# Swift-facing Odin exports

Build a static library and its Swift module together:

```sh
odin build math -build-mode:static -swift-export -out:build/libOdinMath.a
swiftc -I build main.swift build/libOdinMath.a -o build/example
```

For an Odin package named `math`:

```odin
package math

@(export)
add_numbers :: proc(a, b: u64) -> u64 {
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
explicitly exported procedures in the initial package appear in the interface. Build exports for
Darwin arm64 on a macOS host with Xcode and LLVM 18 or newer.

The compiler emits a static archive, `.swiftmodule`, and `.swiftinterface` beside
the requested output. The latter allows Swift to rebuild the module interface
when necessary. Generated declarations refer directly to Odin's native Swift-ABI
entry points; callers write no ABI declarations or Swift forwarding code. For
exported structs, the archive also contains Swift-generated type metadata and
memberwise initializers. This is needed for normal Swift value construction and
reflection. Application procedures execute in Odin.

## Values and memory

This first subset supports ordinary Odin procedures and `proc "contextless"`,
with `i64`, `u64`, `f64`, `bool`, and flat named structs containing `i64`, `u64`,
and `f64`. A procedure returns at most one such value. Struct fields preserve
their order; their offsets, size, stride, and Swift register/indirect lowering
are compatible with this subset. Packed, aligned, nested, or nontrivial structs
are rejected. Scalar parameters use their corresponding Swift scalar types;
structs become frozen Swift value types. Values are passed using the native ABI.

Input slices of `i64`, `u64`, or `f64` become
`UnsafeMutableBufferPointer<Element>`. Swift owns the storage; Odin borrows it
only for the call. The entry point passes the same address and count and makes
no buffer allocation or element copy. Odin must not free or retain this storage.
Swift's usual exclusive-access and buffer-lifetime rules apply:

```odin
@(export)
modify_values :: proc(values: []u64, delta: u64) {
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

Strings, owned collections, slice results, closures, generics, async exports,
and throwing exports are outside this subset and receive diagnostics. Swift
calling Odin is a separate direction from the richer existing Swift importer.
Default argument values are not exported; Swift callers supply every argument.

Ordinary exported procedures receive a freshly initialized default Odin context.
They can use Odin allocators normally. The compiler initializes Odin globals and
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
