#+build darwin, arm64
package runtime

// The Darwin arm64 Swift String register representation.
Swift_String :: struct {
	bits:   u64,
	object: rawptr,
}

#assert(size_of(Swift_String) == 16 && offset_of(Swift_String, object) == 8)

Swift_UTF8_Buffer :: struct {
	bytes: u64,
	count: i64,
}

Swift_UTF8_Copy_Result :: struct {
	count:  i64,
	is_nil: u8,
}

foreign {
	@(link_name="$sSS8UTF8ViewV5countSivg")
	swift_string_utf8_count :: proc "swift" (value: Swift_String) -> i64 ---
	@(link_name="$ss11_StringGutsV8copyUTF84intoSiSgSrys5UInt8VG_tF")
	swift_string_copy_utf8 :: proc "swift" (bytes: u64, capacity: i64, value: Swift_String) -> Swift_UTF8_Copy_Result ---
	@(link_name="$ss11_StringGutsV29_largeContiguousUTF8CodeUnitsSRys5UInt8VGvg")
	swift_string_contiguous_utf8 :: proc "swift" (value: Swift_String) -> Swift_UTF8_Buffer ---
	@(link_name="swift_slowAlloc")
	swift_string_alloc :: proc "c" (size, align_mask: uintptr) -> [^]u8 ---
	@(link_name="swift_slowDealloc")
	swift_string_free :: proc "c" (ptr: rawptr, size, align_mask: uintptr) ---
}

// The native argument remains guaranteed by the Swift caller. Inline bytes
// must refer to the entry's own slot, which outlives the Odin procedure body.
swift_string_borrow :: #force_inline proc "contextless" (value: ^Swift_String) -> string {
	flags := uintptr(value.object)
	if flags & 0x2000_0000_0000_0000 != 0 {
		return string((cast([^]u8)value)[:int((flags >> 56) & 0xf)])
	}
	if flags & 0x1000_0000_0000_0000 == 0 {
		buffer := swift_string_contiguous_utf8(value^)
		return string((cast([^]u8)uintptr(buffer.bytes))[:int(buffer.count)])
	}
	return swift_string_borrow_foreign(value^)
}

@(cold)
swift_string_borrow_foreign :: proc "contextless" (value: Swift_String) -> string {
	length := swift_string_utf8_count(value)
	if length == 0 { return "" }
	bytes := swift_string_alloc(uintptr(length), 0)
	copied := swift_string_copy_utf8(u64(uintptr(bytes)), length, value)
	if copied.is_nil & 1 != 0 || copied.count != length {
		trap()
	}
	return string(bytes[:int(length)])
}

swift_string_end_borrow :: #force_inline proc "contextless" (object: rawptr, borrowed: string) {
	if uintptr(object) & 0x3000_0000_0000_0000 == 0x1000_0000_0000_0000 && len(borrowed) != 0 {
		swift_string_free(raw_data(borrowed), uintptr(len(borrowed)), 0)
	}
}
