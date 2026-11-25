#+build darwin, arm64
package darwin_Swift

import "base:runtime"
import "core:mem"

// Assignments alias the Swift reference. Destroy each owner exactly once.
Native_String :: runtime.Swift_String

@(private)
foreign {
	// These standard-library ABI entry points copy bytes, not String storage.
	@(link_name="$sSS12_tryFromUTF8ySSSgSRys5UInt8VGFZ")
	string_try_from_utf8 :: proc "swift" (bytes: u64, count: i64) -> Native_String ---
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
		buffer := runtime.swift_string_contiguous_utf8(value)
		length = buffer.count
		bytes = rawptr(uintptr(buffer.bytes))
		if length > 0 && bytes == nil { return }
	} else {
		length = runtime.swift_string_utf8_count(value)
	}
	if length < 0 {
		return
	}
	if length == 0 {
		return "", true
	}
	allocated: []byte
	err: mem.Allocator_Error
	allocator := context.allocator
	if allocator.procedure == value_arena_allocator_proc {
		allocated, err = mem.arena_alloc_bytes_non_zeroed(cast(^mem.Arena)allocator.data, int(length), align_of(u8))
	} else {
		if allocator.procedure == nil { return }
		allocated, err = allocator.procedure(allocator.data, .Alloc_Non_Zeroed, int(length), align_of(u8), nil, 0, #location())
	}
	storage := raw_data(allocated)
	if err != .None || storage == nil {
		return
	}
	if bytes != nil {
		mem.copy_non_overlapping(storage, bytes, int(length))
		return string(storage[:int(length)]), true
	}
	copied := runtime.swift_string_copy_utf8(u64(uintptr(storage)), length, value)
	if copied.is_nil & 1 != 0 || copied.count != length {
		mem.free(storage)
		return
	}
	return string(storage[:int(length)]), true
}

string_destroy :: proc(value: ^Native_String) {
	// Bit 63 of the Darwin arm64 String discriminator denotes immortal storage,
	// including inline strings. Pass every mortal object unchanged to Swift.
	if uintptr(value.object) & 0x8000_0000_0000_0000 == 0 { string_release(value.object) }
}
