#+build darwin, arm64
package darwin_Swift

@(private)
Enum_Witnesses :: struct {
	using base: Value_Witnesses,
	tag: proc "c" (value, metadata: rawptr) -> u32,
	project: proc "c" (value, metadata: rawptr),
	inject: rawptr,
}

@(private)
foreign {
	@(link_name="swift_getTypeByMangledNameInContext2")
	metadata_from_name_native :: proc "swift" (name: rawptr, length: u64, descriptor, arguments: rawptr) -> rawptr ---
}

// The compiler obtains this complete type name from Swift's metadata probe.
// Generic metadata and witnesses remain Swift's responsibility.
metadata_from_name :: proc(name: string) -> rawptr {
	return metadata_from_name_native(raw_data(name), u64(len(name)), nil, nil)
}

enum_tag :: proc(value, metadata: rawptr) -> (tag: u32, ok: bool) #optional_ok {
	if value == nil || metadata == nil {
		return
	}
	witness := cast(^Enum_Witnesses)value_witnesses(metadata)
	if witness.flags & 0x0020_0000 == 0 {
		return
	}
	return witness.tag(value, metadata), true
}

// Extract a separately owned payload without consuming the original enum.
// The compiler verifies the case and payload metadata. After projection the
// temporary contains only a payload, so taking it leaves uninitialized storage.
@(require_results)
enum_payload_copy :: proc(value, metadata, payload_metadata: rawptr, expected_tag: u32) -> (payload: rawptr, ok: bool) #optional_ok {
	tag := enum_tag(value, metadata) or_return
	if tag != expected_tag {
		return
	}
	payload = value_allocate(payload_metadata) or_return
	copy, copied := value_copy(value, metadata)
	if !copied {
		value_free_uninitialized(payload)
		return nil, false
	}
	witness := cast(^Enum_Witnesses)value_witnesses(metadata)
	witness.project(copy, metadata)
	take := cast(proc "c" (destination, source, metadata: rawptr) -> rawptr)value_witnesses(payload_metadata).take
	take(payload, copy, payload_metadata)
	value_free_uninitialized(copy)
	return payload, true
}
