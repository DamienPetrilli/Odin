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

build=$(mktemp -d "${TMPDIR:-/tmp}/odin-swift-strings.XXXXXXXX")
trap 'rm -rf -- "$build"' EXIT
"$ODIN" build "$here/strings.odin" -file -no-entry-point -build-mode:obj -use-single-module \
	-vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do \
	"${odin_target[@]}" "${odin_opt[@]}" -out:"$build/strings.o"
xcrun --sdk "$sdk" swiftc -target "$triple" -swift-version 6 -warnings-as-errors \
	-module-cache-path "$build/cache" "${swift_opt[@]}" \
	"$here/main.swift" "$build/strings.o" -o "$build/strings"
xcrun otool -L "$build/strings" > "$build/libraries.txt"
xcrun nm -u "$build/strings" > "$build/symbols.txt"
# Odin's Darwin runtime also contains unrelated Objective-C block support.
if grep -E 'Foundation' "$build/libraries.txt" || \
   grep -E 'Foundation|NSString|objc_msgSend|objc_autoreleasePool' "$build/symbols.txt"; then
	echo "Unexpected Objective-C or Foundation string dependency" >&2
	exit 1
fi
if [[ "$sdk" == macosx ]]; then
	"$build/strings"
else
	echo "Swift-only string fixture linked for $sdk ($mode)"
fi
