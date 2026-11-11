#!/usr/bin/env bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
: "${ODIN:=$here/../../../odin}"

odin_target=(-target:darwin_arm64 -minimum-os-version:15.0)
sdk=${1:-macosx}
case "$sdk" in
	macosx)
		triple=arm64-apple-macosx15.0
		;;
	iphoneos)
		triple=arm64-apple-ios15.0
		odin_target+=(-subtarget:iphone)
		;;
	iphonesimulator)
		triple=arm64-apple-ios15.0-simulator
		odin_target+=(-subtarget:iphonesimulator)
		;;
	*)
		echo "Unsupported Swift ABI test SDK: $sdk" >&2
		exit 1
		;;
esac

case "${2:-debug}" in
	debug)
		odin_opt=(-debug -o:none)
		swift_opt=(-g -Onone)
		;;
	release)
		odin_opt=(-o:speed)
		swift_opt=(-O)
		;;
	*)
		echo "Expected debug or release" >&2
		exit 1
		;;
esac

build=$(mktemp -d "${TMPDIR:-/tmp}/odin-swift-abi.XXXXXXXX")
trap 'rm -rf -- "$build"' EXIT

swiftc=(xcrun --sdk "$sdk" swiftc -target "$triple" -swift-version 6 -warnings-as-errors
	-module-cache-path "$build/cache" "${swift_opt[@]}")
"${swiftc[@]}" -parse-as-library -enable-library-evolution -module-name SwiftABIFixture \
	-emit-object -o "$build/Fixture.o" -emit-module-path "$build/SwiftABIFixture.swiftmodule" "$here/Fixture.swift"

cp "$here/exports.odin" "$build/exports.odin"
"$ODIN" build "$build/exports.odin" -file -no-entry-point -build-mode:obj -use-single-module \
	-vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do \
	"${odin_target[@]}" "${odin_opt[@]}" -out:"$build/exports.o"

"${swiftc[@]}" -I "$build" "$here/main.swift" "$build/Fixture.o" "$build/exports.o" -o "$build/abi"

if [[ "$sdk" != macosx ]]; then
	echo "Swift ABI fixture linked for $sdk"
	exit 0
fi

"$build/abi"

check_invalid() {
	local target=$1
	shift
	if "$ODIN" check "$here/invalid.odin" -file -no-entry-point "-target:$target" > "$build/invalid.log" 2>&1; then
		echo "Expected invalid Swift ABI declarations to fail on $target" >&2
		return 1
	fi
	local diagnostic
	for diagnostic in "$@"; do
		if ! grep -Fq -- "$diagnostic" "$build/invalid.log"; then
			cat "$build/invalid.log" >&2
			echo "Missing diagnostic: $diagnostic" >&2
			return 1
		fi
	done
}

check_invalid darwin_arm64 \
	'Unsupported parameter type for the "swift" calling convention' \
	"'#by_ptr' cannot be used with the \"swift\" calling convention" \
	'Unsupported result type for the "swift" calling convention' \
	'The "swift" calling convention requires a fixed, non-polymorphic procedure with at most one result' \
	'Odin_Callback ::' \
	'C_Callback ::' \
	'C_Callback_Result ::' \
	'The calling conventions differ between the procedure signature types'
check_invalid linux_arm64 'The "swift" calling convention is only supported on Darwin arm64'
echo "Swift ABI tests passed"
