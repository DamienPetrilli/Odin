#!/usr/bin/env bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
: "${ODIN:=$here/../../../../odin}"
sdk=${1:-macosx}
mode=${2:-debug}
odin_target=(-target:darwin_arm64 -minimum-os-version:15.0)
case "$sdk" in
	macosx) triple=arm64-apple-macosx15.0 ;;
	iphoneos) triple=arm64-apple-ios15.0; odin_target+=(-subtarget:iphone) ;;
	iphonesimulator) triple=arm64-apple-ios15.0-simulator; odin_target+=(-subtarget:iphonesimulator) ;;
	*) echo "Unsupported SDK: $sdk" >&2; exit 1 ;;
esac
case "$mode" in
	debug) odin_opt=(-debug -o:none); swift_opt=(-g -Onone) ;;
	release) odin_opt=(-o:speed); swift_opt=(-O) ;;
	*) echo "Expected debug or release" >&2; exit 1 ;;
esac
if [[ "${SWIFT_TEST_ASAN:-0}" == 1 ]]; then
	odin_opt+=(-sanitize:address -lto:thin)
	swift_opt+=(-sanitize=address)
fi
build=$(mktemp -d "${TMPDIR:-/tmp}/odin swift export.XXXXXXXX")
trap 'rm -rf -- "$build"' EXIT
mkdir "$build/reply"
swiftc=(xcrun --sdk "$sdk" swiftc -target "$triple" -swift-version 6 -warnings-as-errors
	-module-cache-path "${TMPDIR:-/tmp}/odin-swift-module-cache" "${swift_opt[@]}")
"${swiftc[@]}" -parse-as-library -module-name SwiftReply -emit-object \
	-o "$build/reply/SwiftReply.o" -emit-module-path "$build/reply/SwiftReply.swiftmodule" "$here/Reply.swift"
cp "$here/library.odin" "$build/library.odin"
"$ODIN" build "$build" -build-mode:static "${odin_target[@]}" "${odin_opt[@]}" \
	-vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do -out:"$build/libOdinExportFixture.a"
# Use the same Apple sanitizer runtime for Swift and Odin. Instrument Odin's
# bitcode with Apple's clang instead of mixing LLVM's ASan runtime with Xcode's.
if [[ "${SWIFT_TEST_ASAN:-0}" == 1 ]]; then
	mkdir "$build/asan"
	(
		cd "$build/asan"
		xcrun ar x "$build/libOdinExportFixture.a"
		for bitcode in ./*.bc; do
			xcrun --sdk "$sdk" clang -target "$triple" -Wno-override-module -x ir -c -fsanitize=address \
				"$bitcode" -o "${bitcode%.bc}.o"
		done
		xcrun ar rcs "$build/instrumented.a" ./*.o
	)
	mv "$build/instrumented.a" "$build/libOdinExportFixture.a"
fi
# Automatic discovery must omit Odin's main in debug and optimized archives.
xcrun nm -gU "$build/libOdinExportFixture.a" > "$build/archive-symbols.log"
if grep -Eq ' T _main$' "$build/archive-symbols.log"; then
	echo "Unexpected Odin main in a Swift-hosted library" >&2
	exit 1
fi
"${swiftc[@]}" -I "$build" "$here/main.swift" "$build/libOdinExportFixture.a" "$build/reply/SwiftReply.o" -o "$build/exports"
# The Swift client must target Odin's native entry points directly.
"${swiftc[@]}" -I "$build" -emit-ir "$here/main.swift" -o "$build/client.ll"
grep -Eq 'call swiftcc .*@__odin_swift_OdinExportFixture_addNumbers' "$build/client.ll"
grep -Eq 'call swiftcc \{ i64, i64 \} @__odin_swift_OdinExportFixture_updateAny' "$build/client.ll"
# Verify the textual interface too, without the compiler-specific binary module.
rm "$build/OdinExportFixture.swiftmodule"
"${swiftc[@]}" -I "$build" "$here/main.swift" "$build/libOdinExportFixture.a" "$build/reply/SwiftReply.o" -o "$build/interface"
if [[ "$sdk" == macosx ]]; then
	"$build/exports"
	"$build/interface"
elif [[ "$sdk" == iphonesimulator && -n "${SWIFT_TEST_SIMULATOR:-}" ]]; then
	xcrun simctl spawn "$SWIFT_TEST_SIMULATOR" "$build/exports"
	xcrun simctl spawn "$SWIFT_TEST_SIMULATOR" "$build/interface"
else
	echo "Swift exports linked for $sdk ($mode)"
fi

# Case conversion must not silently merge declarations or nominal types.
cat > "$build/invalid.odin" <<'ODIN'
package rejected
@(export)
read_value :: proc "swift" () -> u64 { return 1 }
@(export)
readValue :: proc "swift" () -> u64 { return 2 }
ODIN
if "$ODIN" build "$build/invalid.odin" -file -build-mode:static "${odin_target[@]}" \
	-out:"$build/rejected.a" > "$build/invalid.log" 2>&1; then
	echo "Expected invalid Swift exports to fail" >&2
	exit 1
fi
grep -q 'collides after case conversion' "$build/invalid.log"
test ! -f "$build/OdinRejected.swiftmodule"

# A supported low-level signature need not be a supported module interface.
cat > "$build/unsupported.odin" <<'ODIN'
package unsupported
@(export)
pointer :: proc "swift" (value: rawptr) -> rawptr { return value }
@(export)
receiver :: proc "swift" (#swift_self value: rawptr) {}
ODIN
if "$ODIN" build "$build/unsupported.odin" -file -build-mode:static "${odin_target[@]}" \
	-out:"$build/unsupported.a" > "$build/unsupported.log" 2>&1; then
	echo "Expected unsupported module signatures to fail" >&2
	exit 1
fi
grep -q 'Swift export: expected a synchronous Swift procedure' "$build/unsupported.log"

# Other foreign exports and private callbacks must remain outside the module.
grep -Eq 'public func `?addNumbers`?\(' "$build/OdinExportFixture.swiftinterface"
if grep -Eq 'public func `?(cAnswer|odinLength|privateAdd)`?\(' "$build/OdinExportFixture.swiftinterface"; then
	echo "Unexpected non-Swift export or private callback in the module" >&2
	exit 1
fi
cat > "$build/client.c" <<'C'
#include <stdint.h>
extern int32_t c_answer(int32_t value);
int main(void) { return c_answer(41) == 42 ? 0 : 1; }
C
xcrun --sdk "$sdk" clang -target "$triple" -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
	-c "$build/client.c" -o "$build/client.o"
"${swiftc[@]}" "$build/client.o" "$build/libOdinExportFixture.a" "$build/reply/SwiftReply.o" -o "$build/c-client"
if [[ "$sdk" == macosx ]]; then
	"$build/c-client"
elif [[ "$sdk" == iphonesimulator && -n "${SWIFT_TEST_SIMULATOR:-}" ]]; then
	xcrun simctl spawn "$SWIFT_TEST_SIMULATOR" "$build/c-client"
fi

# A C-only library with a private Swift callback does not generate a Swift module.
mkdir "$build/c-only"
cat > "$build/c-only/library.odin" <<'ODIN'
package callback_only
callback :: proc "swift" (value: u64) -> u64 { return value + 1 }
@(export)
c_entry :: proc "c" (value: u64) -> u64 { return callback(value) }
ODIN
"$ODIN" build "$build/c-only" -build-mode:static "${odin_target[@]}" -out:"$build/c-only/library.a"
test ! -e "$build/c-only/OdinCallbackOnly.swiftmodule"
status=0
"$ODIN" build "$build/c-only" -build-mode:static -swift-module-name:Unselected "${odin_target[@]}" \
	-out:"$build/c-only/invalid.a" > "$build/invalid.log" 2>&1 || status=$?
if [[ "$status" != 1 ]]; then
	echo "Expected a normal diagnostic for a module override without Swift exports" >&2
	exit 1
fi
grep -q 'requires exported Swift procedures in a static library' "$build/invalid.log"

# Explicit module names work without changing Odin declarations.
cat > "$build/named.odin" <<'ODIN'
package named_fixture
@(export)
answer :: proc "swift" () -> u64 { return 42 }
ODIN
"$ODIN" build "$build/named.odin" -file -swift-module-name:ChosenModule -build-mode:static \
	"${odin_target[@]}" "${odin_opt[@]}" -out:"$build/named.a"
printf 'import ChosenModule\nprecondition(answer() == 42)\n' > "$build/named.swift"
"${swiftc[@]}" -I "$build" "$build/named.swift" "$build/named.a" -o "$build/named"
if [[ "$sdk" == macosx ]]; then "$build/named"; fi
# Raw object builds keep existing Swift entry semantics and emit no module.
mkdir "$build/raw-object"
"$ODIN" build "$build/named.odin" -file -build-mode:obj -use-single-module "${odin_target[@]}" \
	-out:"$build/raw-object/named.o"
test ! -e "$build/raw-object/OdinNamedFixture.swiftmodule"
xcrun nm "$build/raw-object/named.o" | grep -q ' T _answer$'

# One Odin root owns runtime initialization. Do not silently merge the weak
# runtime definitions of two independently compiled roots.
printf 'import OdinExportFixture\nimport ChosenModule\nprint(addNumbers(1, 2), answer())\n' > "$build/two.swift"
if "${swiftc[@]}" -I "$build" "$build/two.swift" "$build/libOdinExportFixture.a" \
	"$build/named.a" "$build/reply/SwiftReply.o" -o "$build/two" > "$build/two.log" 2>&1; then
	echo "Expected independently exported Odin runtimes to be rejected" >&2
	exit 1
fi
grep -q 'duplicate symbol' "$build/two.log"
grep -q 'startup_runtime' "$build/two.log"
# Keywords and built-in type names must keep the declared record ABI.
"$ODIN" build "$here/names.odin" -file -build-mode:static "${odin_target[@]}" "${odin_opt[@]}" \
	-vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do -out:"$build/names.a"
"${swiftc[@]}" -I "$build" "$here/names.swift" "$build/names.a" -o "$build/names"
"${swiftc[@]}" -I "$build" -emit-ir "$here/names.swift" -o "$build/names.ll"
for index in {0..13}; do
	grep -Eq "call swiftcc \{ i64, i64 \} @__odin_swift_OdinSwiftNames_named$index\(" "$build/names.ll"
done
if [[ "$sdk" == macosx ]]; then
	"$build/names"
elif [[ "$sdk" == iphonesimulator && -n "${SWIFT_TEST_SIMULATOR:-}" ]]; then
	xcrun simctl spawn "$SWIFT_TEST_SIMULATOR" "$build/names"
fi

cat > "$build/clashes.odin" <<'ODIN'
package clashes
Swift :: struct { value: u64 }
Clashes :: struct { value: u64 }
Field_Collision :: struct { read_value, readValue: u64 }
Case_Name :: struct { value: u64 }
CaseName :: struct { value: u64 }
@(export)
probe :: proc "swift" (a: Swift, b: Clashes, c: Field_Collision, d: Case_Name, e: CaseName) {}
@(export)
_leading :: proc "swift" () {}
@(export)
leading :: proc "swift" () {}
@(export, link_name="__odin_swift_Clashes_probe")
conflict: u64
@(export, link_name="__odin_swift_Clashes.initialize")
helper :: proc "swift" () {}
@(export, link_name="$s7ClashesReserved")
metadata: u64
ODIN
if "$ODIN" build "$build/clashes.odin" -file -swift-module-name:Clashes -build-mode:static \
	"${odin_target[@]}" -out:"$build/clashes.a" > "$build/clashes.log" 2>&1; then
	echo "Expected ambiguous Swift export names to fail" >&2
	exit 1
fi
for diagnostic in 'shadows a module name' 'collides after case conversion' 'duplicate type name' 'reserved namespace'; do
	if ! grep -q "$diagnostic" "$build/clashes.log"; then cat "$build/clashes.log" >&2; exit 1; fi
done
test ! -e "$build/Clashes.swiftmodule"
cat > "$build/symbols.odin" <<'ODIN'
package symbols
Record :: struct { value: u64 }
@(export)
record :: proc "swift" (value: Record) -> Record { return value }
@(export, link_name="__swift_reflection_version")
reflection: u64
ODIN
if "$ODIN" build "$build/symbols.odin" -file -build-mode:static "${odin_target[@]}" \
	-out:"$build/symbols.a" > "$build/symbols.log" 2>&1; then
	echo "Expected a Swift metadata helper collision to fail" >&2
	exit 1
fi
grep -q 'conflicts with a Swift-generated symbol' "$build/symbols.log"
test ! -e "$build/OdinSymbols.swiftmodule"
echo "Swift export checks passed ($sdk, $mode)"
