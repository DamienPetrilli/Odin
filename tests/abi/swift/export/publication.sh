#!/usr/bin/env bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
: "${ODIN:=$here/../../../../odin}"
build=$(mktemp -d "${TMPDIR:-/tmp}/odin swift publish.XXXXXXXX")
trap 'chflags -R nouchg "$build"; rm -rf -- "$build"' EXIT
mkdir "$build/one" "$build/two" "$build/out"
cd "$build/out"
files=(OdinVersion.swiftmodule OdinVersion.swiftinterface libVersion.a)
for version in one two; do
	cat > "$build/$version/api.odin" <<ODIN
package version
@(export)
${version} :: proc "swift" () -> u64 { return 42 }
ODIN
done

publish() {
	"$ODIN" build "$build/$1" -build-mode:static -minimum-os-version:15.0 -out:"$PWD/${2:-libVersion.a}"
}

check_client() {
	local version=$1
	printf 'import OdinVersion\nprecondition(%s() == 42)\n' "$version" > "$build/main.swift"
	xcrun swiftc -target arm64-apple-macosx15.0 -I . "$build/main.swift" libVersion.a -o "$build/client"
	"$build/client"
}

publish one
shasum "${files[@]}" > "$build/old"
for name in "${files[@]}"; do
	chflags uchg "$name"
	if publish two > "$build/rejected" 2>&1; then exit 1; fi
	chflags nouchg "$name"
	grep -Fq 'cannot publish' "$build/rejected"
	shasum -c "$build/old"
	check_client one
done
for name in "${files[@]:0:2}"; do
	if publish two "$name" > "$build/rejected" 2>&1; then exit 1; fi
	grep -Fq 'cannot stage' "$build/rejected"
	shasum -c "$build/old"
done
ln OdinVersion.swiftmodule alias.a
if publish two alias.a > "$build/rejected" 2>&1; then exit 1; fi
grep -Fq 'refer to the same file' "$build/rejected"
publish two
check_client two
publish one & first=$!
publish two & second=$!
wait "$first"
wait "$second"
if grep -Eq 'func `?one`?\(' OdinVersion.swiftinterface; then winner=one; else winner=two; fi
check_client "$winner"
rm OdinVersion.swiftmodule
check_client "$winner"
