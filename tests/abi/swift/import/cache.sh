#!/usr/bin/env bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
: "${ODIN:=$here/../../../../odin}"
build=$(mktemp -d "${TMPDIR:-/tmp}/odin swift cache.XXXXXXXX")
trap 'rm -rf -- "$build"' EXIT
mkdir "$build/fixture"
swiftc=(xcrun swiftc -target arm64-apple-macosx15.0 -parse-as-library -module-name CacheFixture
	-module-cache-path "${TMPDIR:-/tmp}/odin-swift-module-cache")
cat > "$build/Fixture.swift" <<'SWIFT'
public func value(_ input: UInt64) -> UInt64 { input + 1 }
SWIFT
"${swiftc[@]}" -emit-object -o "$build/fixture/CacheFixture.o" \
	-emit-module-path "$build/fixture/CacheFixture.swiftmodule" "$build/Fixture.swift"
cat > "$build/main.odin" <<'ODIN'
package cache_test
foreign import fixture "swift:fixture/CacheFixture"
main :: proc() { assert(fixture.value(41) == 42) }
ODIN
compile() {
	"$ODIN" build "$build/main.odin" -file -target:darwin_arm64 -minimum-os-version:15.0 \
		-show-more-timings -out:"$build/$1" > "$build/$1.log" 2>&1
	"$build/$1"
	# Even a warm build must inspect the current declaration and library.
	grep -q 'Swift inspection swift-symbolgraph-extract:' "$build/$1.log"
	grep -q 'Swift inspection swift-api-digester:' "$build/$1.log"
	grep -q 'Swift inspection nm:' "$build/$1.log"
}
compile first
compile warm
compile concurrent_a &
a=$!
compile concurrent_b &
b=$!
wait "$a"
wait "$b"

# Change both the ABI and implementation at the same module/library paths.
# Reusing the old generated declaration would pass the argument in the wrong
# register bank, or fail to resolve the changed Swift symbol.
cat > "$build/Fixture.swift" <<'SWIFT'
public func value(_ input: Double) -> Double { input * 2 }
SWIFT
"${swiftc[@]}" -emit-object -o "$build/fixture/CacheFixture.o" \
	-emit-module-path "$build/fixture/CacheFixture.swiftmodule" "$build/Fixture.swift"
cat > "$build/main.odin" <<'ODIN'
package cache_test
foreign import fixture "swift:fixture/CacheFixture"
main :: proc() { assert(fixture.value(20.5) == 41.0) }
ODIN
compile changed

# A broken module is an error, never a reason to reuse an old declaration.
printf 'invalid module\n' > "$build/fixture/CacheFixture.swiftmodule"
if "$ODIN" build "$build/main.odin" -file -out:"$build/broken" > "$build/broken.log" 2>&1; then
	echo "Expected a corrupt Swift module to be rejected" >&2
	exit 1
fi
grep -q 'Swift import:' "$build/broken.log"
test ! -e "$build/broken"
echo "Swift module cache checks passed"
