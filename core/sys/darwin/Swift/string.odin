#+build darwin, arm64
package darwin_Swift

import "core:mem"

// Native register representation, used only by compiler-generated calls.
// Assignments alias its reference. Use string_destroy exactly once per owner.
Native_String :: struct {
	bits: u64,
	object: rawptr,
}

#assert(size_of(Native_String) == 16 && offset_of(Native_String, object) == 8)

@(private)
UTF8_Buffer :: struct {
	bytes: u64,
	count: i64,
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
	@(link_name="$ss11_StringGutsV29_largeContiguousUTF8CodeUnitsSRys5UInt8VGvg")
	string_contiguous_utf8 :: proc "swift" (value: Native_String) -> UTF8_Buffer ---
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
	// Swift's frozen 64-bit String ABI stores small UTF-8 inline, with its byte
	// count in the low nibble of the discriminator. Darwin arm64 is little endian.
	// Large contiguous strings expose a borrowed buffer through Swift's getter;
	// keep their owner alive until the copy completes. Foreign strings use Swift's
	// transcoding path below. Never decode or dereference the object pointer.
	inline_value: Native_String
	flags := uintptr(value.object)
	length: i64
	bytes: rawptr
	if flags & 0x2000_0000_0000_0000 != 0 {
		length = i64((flags >> 56) & 0xf)
		if length == 0 { return "", true }
		inline_value = value
		bytes = &inline_value
	} else if flags & 0x1000_0000_0000_0000 == 0 {
		buffer := string_contiguous_utf8(value)
		length = buffer.count
		bytes = rawptr(uintptr(buffer.bytes))
		if length > 0 && bytes == nil { return }
	} else {
		length = string_utf8_count(value)
	}
	if length < 0 {
		return
	}
	if length == 0 {
		return "", true
	}
	allocated, err := mem.alloc_bytes_non_zeroed(int(length))
	storage := raw_data(allocated)
	if err != .None || storage == nil {
		return
	}
	if bytes != nil {
		mem.copy_non_overlapping(storage, bytes, int(length))
		return string(storage[:int(length)]), true
	}
	copied := string_copy_utf8(u64(uintptr(storage)), length, value)
	if copied.is_nil & 1 != 0 || copied.count != length {
		mem.free(storage)
		return
	}
	return string(storage[:int(length)]), true
}

string_destroy :: proc(value: ^Native_String) {
	// This is the native String destructor. Swift handles tagged, native and
	// foreign storage; the object word must not be masked or dereferenced here.
	string_release(value.object)
}
