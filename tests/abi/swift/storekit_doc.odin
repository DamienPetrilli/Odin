// Check the published module identity in the documentation index.
package storekit_doc_test

import doc "core:odin/doc-format"
import "core:os"
import "core:strings"

main :: proc() {
	data, err := os.read_entire_file(os.args[1], context.allocator)
	assert(err == nil)
	defer delete(data)
	h, read_err := doc.read_from_bytes(data)
	assert(read_err == .None)
	found := false
	for p in doc.from_array(&h.base, h.pkgs) {
		if strings.has_prefix(doc.from_string(&h.base, p.fullpath), "swift:StoreKit/arm64-apple-macosx") {
			assert(doc.from_string(&h.base, p.name) == "StoreKit")
			found = true
			break
		}
	}
	assert(found, "Missing StoreKit module in the documentation index")
}
