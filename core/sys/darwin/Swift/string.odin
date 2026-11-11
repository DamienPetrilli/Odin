#+build darwin, arm64
package darwin_Swift

import "core:mem"
import NS "core:sys/darwin/Foundation"

// Native register representation, used only by compiler-generated calls.
// Assignments alias its reference. Use string_destroy exactly once per owner.
Native_String :: struct {
	bits: u64,
	object: rawptr,
}

@(private)
foreign {
	@(link_name="$sSS10FoundationE36_unconditionallyBridgeFromObjectiveCySSSo8NSStringCSgFZ")
	string_from_ns :: proc "swift" (value: ^NS.String) -> Native_String ---
	@(link_name="$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF")
	string_to_ns :: proc "swift" (value: Native_String) -> ^NS.String ---
}

@(require_results)
string_from_odin :: proc(value: string) -> (result: Native_String, ok: bool) #optional_ok {
	NS.scoped_autoreleasepool()
	ns := NS.to_ns_string(value)
	if ns == nil {
		return
	}
	defer ns->release()
	return string_from_ns(ns), true
}

// Return an Odin-owned UTF-8 copy, preserving embedded zero bytes. This borrows
// the Swift string; the caller still owns and destroys its native reference.
@(require_results)
string_to_odin :: proc(value: Native_String) -> (result: string, ok: bool) #optional_ok {
	NS.scoped_autoreleasepool()
	ns := string_to_ns(value)
	if ns == nil {
		return
	}
	defer ns->release()
	length := ns->lengthOfBytesUsingEncoding(NS.UTF8StringEncoding)
	if length > NS.UInteger(max(int)) {
		return
	}
	if length == 0 {
		return "", true
	}
	bytes := ns->UTF8String()
	if bytes == nil {
		return
	}
	storage, err := mem.alloc(int(length))
	if err != .None {
		return
	}
	mem.copy(storage, rawptr(bytes), int(length))
	return string((cast([^]byte)storage)[:int(length)]), true
}

string_destroy :: proc(value: ^Native_String) {
	metadata := metadata_from_name("SS")
	value_witnesses(metadata).destroy(value, metadata)
}
