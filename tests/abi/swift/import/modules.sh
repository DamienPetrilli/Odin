#!/usr/bin/env bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
: "${ODIN:=$here/../../../../odin}"
build=$(mktemp -d "${TMPDIR:-/tmp}/odin swift modules.XXXXXXXX")
trap 'rm -rf -- "$build"' EXIT
cd "$build"

cat > Left.swift <<'SWIFT'
public func read() throws -> UInt64 { 42 }
SWIFT
cp Left.swift Right.swift
for module in Left Right; do
	xcrun swiftc -target arm64-apple-macosx15.0 -parse-as-library -module-name "$module" \
		-emit-module-path "$module.swiftmodule" -emit-object "$module.swift" -o "$module.o"
done
cat > mixed.odin <<'ODIN'
package example
foreign import left "swift:Left"
foreign import right "swift:Right"
read :: proc() -> (value: u64, err: left.Call_Error) {
	value = right.read() or_return
	return
}
ODIN
if "$ODIN" check mixed.odin -file -no-entry-point -minimum-os-version:15.0 > mixed.log 2>&1; then exit 1; fi
grep -Fq "Received 'Right.Call_Error', expected 'Left.Call_Error'" mixed.log

cat > inactive.odin <<'ODIN'
package example
when ODIN_OS == .Darwin {
	foreign import right "swift:Right"
}
ODIN
if "$ODIN" check inactive.odin -file -no-entry-point -target:linux_arm64 > inactive.log 2>&1; then exit 1; fi
grep -Fq '#+build darwin arm64' inactive.log
mkdir portable
printf 'package example\nmain :: proc() {}\n' > portable/main.odin
printf '#+build darwin arm64\npackage example\nforeign import right "swift:Right"\n' > portable/sdk.odin
"$ODIN" check portable -target:linux_arm64

cat > Left.swift <<'SWIFT'
@frozen public struct Point { public var x: UInt64 }
public func identity(_ value: Point) -> Point { value }
SWIFT
cp Left.swift Right.swift
cat > Drawing.swift <<'SWIFT'
import Left
import Right
public func width(_ point: Left.Point) -> UInt64 { point.x }
public func swap(_ point: Right.Point, _ other: Left.Point) -> Left.Point { other }
SWIFT
for module in Left Right Drawing; do
	xcrun swiftc -target arm64-apple-macosx15.0 -I . -parse-as-library -enable-library-evolution -module-name "$module" \
		-emit-module-path "$module.swiftmodule" -emit-object "$module.swift" -o "$module.o"
done
for order in 'Left Right Drawing' 'Drawing Right Left'; do
	echo 'package app' > main.odin
	for module in $order; do printf 'foreign import %s "swift:%s"\n' "$module" "$module" >> main.odin; done
	cat >> main.odin <<'ODIN'
main :: proc() {
	left := Left.Point{x = 42}
	right := Right.Point{x = 7}
	assert(Drawing.width(Left.identity(left)) == 42)
	assert(Left.identity(Drawing.swap(Right.identity(right), left)).x == 42)
}
ODIN
	"$ODIN" build main.odin -file -minimum-os-version:15.0 -out:"$build/client"
	"$build/client"
done
sed 's/Drawing.width(Left.identity(left))/Drawing.width(right)/' main.odin > invalid.odin
if "$ODIN" check invalid.odin -file -minimum-os-version:15.0 > names.log 2>&1; then exit 1; fi
grep -Fq "Cannot assign" names.log
