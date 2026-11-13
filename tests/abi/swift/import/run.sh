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

# Exercise spaces in module and library paths as well as normal imports.
build=$(mktemp -d "${TMPDIR:-/tmp}/odin swift import.XXXXXXXX")
trap 'rm -rf -- "$build"' EXIT
mkdir "$build/fixture"
swiftc=(xcrun --sdk "$sdk" swiftc -target "$triple" -swift-version 6 -warnings-as-errors
	-module-cache-path "${TMPDIR:-/tmp}/odin-swift-module-cache" "${swift_opt[@]}")
# The library author builds an ordinary Swift module, with no interop code.
"${swiftc[@]}" -parse-as-library -enable-library-evolution -module-name SwiftImportFixture \
	-emit-object -o "$build/fixture/SwiftImportFixture.o" \
	-emit-module-path "$build/fixture/SwiftImportFixture.swiftmodule" "$here/Fixture.swift"
cp "$here/main.odin" "$build/main.odin"
cp "$here/values.odin" "$build/values.odin"
cp "$here/strings.odin" "$build/strings.odin"
cp "$here/tasks.odin" "$build/tasks.odin"
cp "$here/arrays.odin" "$build/arrays.odin"

# Odin imports, checks and links the Swift module in a single invocation.
"$ODIN" build "$build" \
	-vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do \
	"${odin_target[@]}" "${odin_opt[@]}" -out:"$build/import"
xcrun nm "$build/import" > "$build/symbols.txt"
if grep -q OdinSwiftImportProbe "$build/symbols.txt"; then
	echo "Unexpected Swift inspection code in the application" >&2
	exit 1
fi
grep -q 'SwiftImportFixture.*addLater.*YaF$' "$build/symbols.txt"
grep -q 'SwiftImportFixture.*addLater.*Tu' "$build/symbols.txt"
grep -q 'SwiftImportFixture.*3add' "$build/symbols.txt"

# A separate Swift module deliberately shadows standard scalar type names.
mkdir -p "$build/names/fixture"
"${swiftc[@]}" -parse-as-library -enable-library-evolution -module-name SwiftNamesFixture \
	-emit-object -o "$build/names/fixture/SwiftNamesFixture.o" \
	-emit-module-path "$build/names/fixture/SwiftNamesFixture.swiftmodule" "$here/Names.swift"
cp "$here/names.odin" "$build/names/main.odin"
"$ODIN" build "$build/names" "${odin_target[@]}" "${odin_opt[@]}" \
	-vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do -out:"$build/names-test"

# Simulator execution is opt-in and uses a caller-owned, booted device.
# Do not change the user's simulator state from this test script.
if [[ "$sdk" == iphoneos || ( "$sdk" == iphonesimulator && -z "${SWIFT_TEST_SIMULATOR:-}" ) ]]; then
	echo "Swift import fixture linked for $sdk ($mode)"
	exit 0
fi
run_fixture() {
	if [[ "$sdk" == iphonesimulator ]]; then
		xcrun simctl spawn "$SWIFT_TEST_SIMULATOR" "$1"
	else
		"$1"
	fi
}
run_fixture "$build/import"
run_fixture "$build/names-test"

# A static archive and repeated imports use the same normal build path.
# Keep the original module as the SDK and replace only the binary with a newer
# resilient enum, including an unknown case with a larger, nontrivial payload.
"${swiftc[@]}" -D EVOLVED_VALUE_ENUM -parse-as-library -enable-library-evolution \
	-module-name SwiftImportFixture -emit-object -o "$build/fixture/SwiftImportFixture.o" "$here/Fixture.swift"
xcrun ar rcs "$build/fixture/libSwiftImportFixture.a" "$build/fixture/SwiftImportFixture.o"
rm "$build/fixture/SwiftImportFixture.o"
cat > "$build/second.odin" <<'ODIN'
package swift_import_test

import "base:runtime"

foreign import second "swift:fixture/SwiftImportFixture"

@(init)
check_second_import :: proc "contextless" () {
	context = runtime.default_context()
	assert(second.add(10, 20) == 30)
}
ODIN
"$ODIN" build "$build" "${odin_target[@]}" "${odin_opt[@]}" -define:EVOLVED_VALUE_ENUM=true -out:"$build/repeated"
run_fixture "$build/repeated"
if [[ "$sdk" == iphonesimulator ]]; then
	echo "Swift import tests passed on iOS simulator ($mode)"
	exit 0
fi

# Reject names that could change the generated ABI or select a helper instead
# of the original declaration. These are separate module variants.
mkdir -p "$build/clashes/fixture"
cat > "$build/clashes/main.odin" <<'ODIN'
package clashes
foreign import fixture "swift:fixture/SwiftClashesFixture"
main :: proc() {}
ODIN
for selection in BUILTIN FLATTENED HELPER UNSUPPORTED_HELPER ENUM_CASE STRING_TYPE; do
	"${swiftc[@]}" -D "$selection" -parse-as-library -enable-library-evolution -module-name SwiftClashesFixture \
		-emit-object -o "$build/clashes/fixture/SwiftClashesFixture.o" \
		-emit-module-path "$build/clashes/fixture/SwiftClashesFixture.swiftmodule" "$here/Clashes.swift"
	if "$ODIN" check "$build/clashes" "${odin_target[@]}" > "$build/invalid.log" 2>&1; then
		echo "Expected Swift name collision rejection: $selection" >&2
		exit 1
	fi
	case "$selection" in
		BUILTIN) diagnostic="type 'f64' conflicts" ;;
		FLATTENED | STRING_TYPE) diagnostic="map to the same Odin name" ;;
		HELPER | ENUM_CASE) diagnostic="is ambiguous" ;;
		UNSUPPORTED_HELPER) diagnostic="conflicts with a generated Odin helper" ;;
	esac
	if ! grep -F 'Swift import:' "$build/invalid.log" | grep -Fq "$diagnostic"; then
		cat "$build/invalid.log" >&2
		echo "Missing name collision diagnostic: $selection" >&2
		exit 1
	fi
done

# Check all rejected declarations in one import. Each compiler invocation
# inspects the Swift module; repeating that for each diagnostic is expensive.
cat > "$build/rejected.odin" <<'ODIN'
package rejected
foreign import fixture "swift:fixture/SwiftImportFixture"
main :: proc() {
ODIN
for selection in narrow generic throwing isolated_sync overloaded future optional inout_value direct_value typed_throwing text_later unsupported_nested_array; do
	printf '\t_ = fixture.%s\n' "$selection" >> "$build/rejected.odin"
done
printf '}\n' >> "$build/rejected.odin"
if "$ODIN" check "$build/rejected.odin" -file "${odin_target[@]}" > "$build/invalid.log" 2>&1; then
	echo "Expected importer to reject unsupported declarations" >&2
	exit 1
fi
for selection in narrow generic throwing isolated_sync overloaded future optional inout_value direct_value typed_throwing text_later unsupported_nested_array; do
	if ! grep -F "Swift import:" "$build/invalid.log" | grep -Fq "'$selection'"; then
		cat "$build/invalid.log" >&2
		echo "Missing rejection for $selection" >&2
		exit 1
	fi
done

if "$ODIN" build "$build/main.odin" -file -internal-cached -out:"$build/cached" > "$build/invalid.log" 2>&1; then
	echo "Expected unsupported cached Swift imports to fail" >&2
	exit 1
fi
grep -q 'Swift imports do not yet support -internal-cached builds' "$build/invalid.log"

if "$ODIN" check "$build/main.odin" -file -target:linux_arm64 > "$build/invalid.log" 2>&1; then
	echo "Expected unsupported Swift import target to fail" >&2
	exit 1
fi
grep -q 'Swift imports currently require a Darwin arm64 target' "$build/invalid.log"

if "$ODIN" check "$here/invalid.odin" -file -no-entry-point > "$build/invalid.log" 2>&1; then
	echo "Expected invalid Swift import calls to fail" >&2
	exit 1
fi
for diagnostic in \
	'requires a constant Swift link name' \
	'completion task handle must have a rawptr base type' \
	'result must be i64, u64, or f64' \
	'completion must be an Odin procedure' \
	'arguments must be i64, u64, or f64' \
	'receiver must be a pointer to a live Swift value' \
	'requires an Odin context'; do
	if ! grep -Fq "$diagnostic" "$build/invalid.log"; then
		cat "$build/invalid.log" >&2
		echo "Missing diagnostic: $diagnostic" >&2
		exit 1
	fi
done
echo "Swift import tests passed ($mode)"
