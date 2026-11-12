#+build darwin, arm64
package darwin_Swift

import "core:mem"

// Native register representation, used only by compiler-generated calls.
// Assignments alias its reference. Use string_destroy exactly once per owner.
Native_String :: struct {
	bits: u64,
	object: rawptr,
}

@(private)
UTF8_Copy_Result :: struct {
	count: i64,
	is_nil: u8,
}

@(private)
foreign {
	// These standard-library ABI entry points copy bytes, not String storage.
	@(link_name="$sSS12_tryFromUTF8ySSSgSRys5UInt8VGFZ")
	string_try_from_utf8 :: proc "swift" (bytes: u64, count: i64) -> Native_String ---
	@(link_name="$sSS8UTF8ViewV5countSivg")
	string_utf8_count :: proc "swift" (value: Native_String) -> i64 ---
	@(link_name="$ss11_StringGutsV8copyUTF84intoSiSgSrys5UInt8VG_tF")
	string_copy_utf8 :: proc "swift" (bytes: u64, capacity: i64, value: Native_String) -> UTF8_Copy_Result ---
	@(link_name="swift_bridgeObjectRelease")
	string_release :: proc "c" (object: rawptr) ---
}

@(require_results)
string_from_odin :: proc(value: string) -> (result: Native_String, ok: bool) #optional_ok {
	// Swift validates and copies the borrowed bytes into an owned String.
	// Optional<String> uses a null object word for nil on this target.
	result = string_try_from_utf8(u64(uintptr(raw_data(value))), i64(len(value)))
	return result, result.object != nil
}

// Return an Odin-owned UTF-8 copy, preserving embedded zero bytes. This borrows
// the Swift string; the caller still owns and destroys its native reference.
@(require_results)
string_to_odin :: proc(value: Native_String) -> (result: string, ok: bool) #optional_ok {
	// String, its UTF8View and _StringGuts share the same frozen representation.
	// Both entry points borrow it; neither returns a pointer into Swift storage.
	length := string_utf8_count(value)
	if length < 0 {
		return
	}
	if length == 0 {
		return "", true
	}
	storage, err := mem.alloc(int(length))
	if err != .None || storage == nil {
		return
	}
	copied := string_copy_utf8(u64(uintptr(storage)), length, value)
	if copied.is_nil & 1 != 0 || copied.count != length {
		mem.free(storage)
		return
	}
	return string((cast([^]byte)storage)[:int(length)]), true
}

string_destroy :: proc(value: ^Native_String) {
	// This is the native String destructor. Swift handles tagged, native and
	// foreign storage; the object word must not be masked or dereferenced here.
	string_release(value.object)
}
