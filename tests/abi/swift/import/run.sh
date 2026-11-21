#!/usr/bin/env bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
: "${ODIN:=$here/../../../../odin}"
sdk=${1:-macosx}
mode=${2:-debug}
platform_target=(-target:darwin_arm64)
case "$sdk" in
	macosx) triple=arm64-apple-macosx15.0 ;;
	iphoneos) triple=arm64-apple-ios15.0; platform_target+=(-subtarget:iphone) ;;
	iphonesimulator) triple=arm64-apple-ios15.0-simulator; platform_target+=(-subtarget:iphonesimulator) ;;
	*) echo "Unsupported SDK: $sdk" >&2; exit 1 ;;
esac
odin_target=("${platform_target[@]}" -minimum-os-version:15.0)
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
cp "$here/enums.odin" "$build/enums.odin"
cp "$here/plain_enums.odin" "$build/plain_enums.odin"
cp "$here/strings.odin" "$build/strings.odin"
cp "$here/async_strings.odin" "$build/async_strings.odin"
cp "$here/tasks.odin" "$build/tasks.odin"
cp "$here/arrays.odin" "$build/arrays.odin"
cp "$here/value_arrays.odin" "$build/value_arrays.odin"
cp "$here/records.odin" "$build/records.odin"
cp "$here/mixed_records.odin" "$build/mixed_records.odin"
cp "$here/dates.odin" "$build/dates.odin"
cp "$here/uuids.odin" "$build/uuids.odin"
cp "$here/sets.odin" "$build/sets.odin"
cp "$here/owned_records.odin" "$build/owned_records.odin"
cp "$here/errors.odin" "$build/errors.odin"
cp "$here/scalars.odin" "$build/scalars.odin"

# Odin imports, checks and links the Swift module in a single invocation.
"$ODIN" build "$build" \
	-vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do \
	"${odin_target[@]}" "${odin_opt[@]}" -out:"$build/import" -show-swift-imports > "$build/mappings.txt"
grep -Fq 'call add_later :: proc(value: u64, delta: u64, completion: proc(swift.Task, u64))' "$build/mappings.txt"
grep -Fq 'call async_tuple :: proc(count: u64, completion: proc(task: swift.Task, count: u64, ready: bool))' "$build/mappings.txt"
grep -Fq 'call bounds :: proc(value: u64) -> (lower: u64, upper: u64)' "$build/mappings.txt"
grep -Fq 'type SwiftImportFixture.`TextRecord` -> TextRecord (struct, frozen)' "$build/mappings.txt"
grep -Fq 'call ArrayRecord_advance :: proc(receiver: ^ArrayRecord, amount: u64) -> u64' "$build/mappings.txt"
grep -Fq 'Swift Bool storage requires bytes 0 or 1' "$build/mappings.txt"
grep -Fq 'receiver: exclusive borrow during call' "$build/mappings.txt"
grep -Fq 'call RawCode_raw_value :: proc(receiver: RawCode) -> u64' "$build/mappings.txt"
grep -Fq 'call RawCode_adding :: proc(receiver: RawCode, value: u64) -> u64' "$build/mappings.txt"
grep -Fq 'owned result: delete(result, allocator)' "$build/mappings.txt"
grep -Fq 'exclusive borrow through completion' "$build/mappings.txt"
grep -Fq 'final bool reports result conversion' "$build/mappings.txt"
grep -Fq 'skipped future: func future()' "$build/mappings.txt"
grep -Fq 'lookup fallback future (future()): requires' "$build/mappings.txt"
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
if [[ "$sdk" != macosx ]]; then cp "$here/controller.odin" "$build/names/"; fi
"$ODIN" build "$build/names" "${odin_target[@]}" "${odin_opt[@]}" \
	-vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do -out:"$build/names-test"

# Check rejections in one invocation on every target, including link-only iOS runs.
rejected=(text_bounds owned_tuple tuple_case_collision throwing_tuple ArrayRecord_recursive_result TextRecord_clear RawCollision_raw_value RawCode_replace async_buffer returned_buffer generic throwing isolated_sync overloaded future inout_value typed_throwing
	unsupported_nested_array indirect_payload recursive_payload existential_payload colliding_fields
	unsupported_scalar_argument unsupported_scalar_result narrow_array unsupported_bool_array unsupported_set_result
	unsupported_optional_set unsupported_bool_set client_only new_number new_number_for_ NewValue
	NewValue_number EvolvingFailure_Deferred retired_value withdrawn_value)
cat > "$build/rejected.odin" <<'ODIN'
package rejected
foreign import fixture "swift:fixture/SwiftImportFixture"
main :: proc() {
ODIN
for name in "${rejected[@]}"; do
	printf '\t_ = fixture.%s\n' "$name" >> "$build/rejected.odin"
done
printf '}\n' >> "$build/rejected.odin"
if "$ODIN" check "$build/rejected.odin" -file "-max-error-count:${#rejected[@]}" "${odin_target[@]}" > "$build/invalid.log" 2>&1; then
	echo "Expected importer to reject unsupported declarations" >&2
	exit 1
fi
expect_diagnostic() {
	if ! grep -Fq "$1" "$build/invalid.log"; then
		cat "$build/invalid.log" >&2
		echo "Missing Swift diagnostic: $1" >&2
		exit 1
	fi
}
for name in "${rejected[@]}"; do expect_diagnostic "Swift import: '$name':"; done
expect_diagnostic "'owned_tuple': tuple results require numeric or Bool scalars"
expect_diagnostic "'text_bounds': tuple results with converted parameters are unsupported"
expect_diagnostic "'tuple_case_collision': tuple result labels collide after Odin name conversion"
expect_diagnostic "'throwing_tuple': tuple results currently require a nonthrowing free function"
platform=iOS
introduced=18.2
if [[ "$sdk" == macosx ]]; then platform=macOS; introduced=15.2.1; fi
grep -Fq "  deprecated: $platform $introduced" "$build/mappings.txt"
expect_diagnostic "'retired_value': deprecated on $platform (deployment target $platform 15.0.0)"
expect_diagnostic "'withdrawn_value': marked obsolete in $platform $introduced (deployment target $platform 15.0.0)"
for name in new_number new_number_for_ NewValue NewValue_number; do
	expect_diagnostic "'$name': requires $platform $introduced (deployment target $platform 15.0.0)"
done
expect_diagnostic "'EvolvingFailure_Deferred': requires $platform 99.0 (deployment target $platform 15.0.0)"
expect_diagnostic "'RawCollision_raw_value': ambiguous Swift binding"
expect_diagnostic "'ArrayRecord_recursive_result': unsupported result type 'SwiftImportFixture.RecursivePayload'"
for name in RawCode_replace TextRecord_clear; do
	expect_diagnostic "'$name': mutating a projected Swift receiver requires write-back to the Odin value"
done
expect_diagnostic "'async_buffer': a borrowed Swift pointer or buffer cannot be captured across suspension"
expect_diagnostic "'returned_buffer': unsupported result type"
expect_diagnostic "'client_only': unsupported Swift attribute '@_alwaysEmitIntoClient'"
expect_diagnostic "'isolated_sync': synchronous @MainActor calls require actor isolation"
expect_diagnostic "'unsupported_scalar_argument': parameter 'value' has unsupported type or modifier 'Swift.Float16'"
expect_diagnostic "'unsupported_scalar_result': unsupported result type 'Swift.Float16'"
expect_diagnostic "'narrow_array': unsupported result type '[Swift.Int16]'"
expect_diagnostic "'unsupported_bool_array': unsupported result type '[Swift.Bool]'"
expect_diagnostic "'recursive_payload': unsupported result type 'SwiftImportFixture.RecursivePayload'"
expect_diagnostic "func overloaded(_ value: UInt64) -> UInt64"
expect_diagnostic "func overloaded(_ value: Double) -> Double"
cat > "$build/rejected.odin" <<'ODIN'
package available
foreign import fixture "swift:fixture/SwiftImportFixture"
main :: proc() {
	_ = fixture.new_number(1)
	_ = fixture.new_number_for_(2)
	_ = fixture.NewValue_number()
}
ODIN
"$ODIN" check "$build/rejected.odin" -file "${platform_target[@]}" -minimum-os-version:"$introduced" -show-swift-imports > "$build/mappings.txt"
grep -Fq "lookup fallback prior_value (priorValue(_:)): marked deprecated in $platform $introduced" "$build/mappings.txt"
rm "$build/rejected.odin"

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

mkdir -p "$build/sets/fixture"
"${swiftc[@]}" -parse-as-library -enable-library-evolution -module-name SwiftSetSync \
	-emit-object -o "$build/sets/fixture/SwiftSetSync.o" \
	-emit-module-path "$build/sets/fixture/SwiftSetSync.swiftmodule" "$here/SetSync.swift"
cp "$here/set_sync.odin" "$build/sets/main.odin"
"$ODIN" build "$build/sets" "${odin_target[@]}" "${odin_opt[@]}" \
	-vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do -out:"$build/sets-test"
run_fixture "$build/sets-test"

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
# Single-module codegen must share tag globals across generic specializations.
"$ODIN" build "$build" "${odin_target[@]}" "${odin_opt[@]}" -use-single-module -define:EVOLVED_VALUE_ENUM=true -out:"$build/repeated"
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
for selection in BUILTIN FLATTENED HELPER UNSUPPORTED_HELPER ENUM_CASE FROZEN_ENUM_CASE STRING_TYPE ARRAY_TYPE RECORD_FIELD UUID_TYPE ERROR_HELPER ASYNC_ERROR_TYPE ASYNC_ERROR_ALIAS ASYNC_ERROR_UNSUPPORTED; do
	"${swiftc[@]}" -D "$selection" -parse-as-library -enable-library-evolution -module-name SwiftClashesFixture \
		-emit-object -o "$build/clashes/fixture/SwiftClashesFixture.o" \
		-emit-module-path "$build/clashes/fixture/SwiftClashesFixture.swiftmodule" "$here/Clashes.swift"
	if "$ODIN" check "$build/clashes" "${odin_target[@]}" > "$build/invalid.log" 2>&1; then
		echo "Expected Swift name collision rejection: $selection" >&2
		exit 1
	fi
	case "$selection" in
		BUILTIN) diagnostic="type 'f64' conflicts" ;;
		FLATTENED | STRING_TYPE | ARRAY_TYPE | UUID_TYPE) diagnostic="map to the same Odin name" ;;
		HELPER | ENUM_CASE | FROZEN_ENUM_CASE | RECORD_FIELD | ERROR_HELPER) diagnostic="is ambiguous" ;;
		ASYNC_ERROR_TYPE | ASYNC_ERROR_ALIAS | ASYNC_ERROR_UNSUPPORTED) diagnostic="conflicts with generated async error declarations" ;;
		UNSUPPORTED_HELPER) diagnostic="conflicts with a generated Odin helper" ;;
	esac
	if ! grep -F 'Swift import:' "$build/invalid.log" | grep -Fq "$diagnostic"; then
		cat "$build/invalid.log" >&2
		echo "Missing name collision diagnostic: $selection" >&2
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
	'result must be a supported Swift numeric scalar or bool' \
	'completion must be an Odin procedure' \
	'arguments must be a supported Swift numeric scalar or bool' \
	'receiver must be a pointer to a live Swift value' \
	'requires an Odin context'; do
	if ! grep -Fq "$diagnostic" "$build/invalid.log"; then
		cat "$build/invalid.log" >&2
		echo "Missing diagnostic: $diagnostic" >&2
		exit 1
	fi
done
echo "Swift import tests passed ($mode)"
