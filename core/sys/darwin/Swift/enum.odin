#+build darwin, arm64
package darwin_Swift

import "base:intrinsics"

@(private)
Enum_Witnesses :: struct {
	using base: Value_Witnesses,
	tag: proc "c" (value, metadata: rawptr) -> u32,
	project: proc "c" (value, metadata: rawptr),
	inject: proc "c" (value: rawptr, tag: u32, metadata: rawptr),
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

// Complete concrete metadata is canonical and lives for the process lifetime.
// Concurrent first lookups may publish the same result; acquire/release makes
// the initialized metadata visible without repeating demangling on each call.
metadata_from_name_cached :: proc(cache: ^rawptr, name: string) -> rawptr {
	metadata := intrinsics.atomic_load_explicit(cache, .Acquire)
	if metadata == nil {
		metadata = metadata_from_name(name)
		intrinsics.atomic_store_explicit(cache, metadata, .Release)
	}
	return metadata
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

// The importer has already checked the enum metadata and selected its case.
// Project and inject operate destructively on the same native storage.
enum_project :: proc(value, metadata: rawptr) {
	witness := cast(^Enum_Witnesses)value_witnesses(metadata)
	assert(witness.flags & 0x0020_0000 != 0)
	witness.project(value, metadata)
}

enum_inject :: proc(value, metadata: rawptr, tag: u32) {
	witness := cast(^Enum_Witnesses)value_witnesses(metadata)
	assert(witness.flags & 0x0020_0000 != 0)
	witness.inject(value, tag, metadata)
}

@(private)
Tuple_Metadata :: struct {
	kind, count: uint,
	labels: rawptr,
}

@(private)
Tuple_Element :: struct {
	metadata: rawptr,
	offset: uint,
}

@(private)
foreign {
	@(link_name="swift_getTupleTypeMetadata")
	tuple_metadata_native :: proc "swift" (request, flags: u64, elements: [^]rawptr, labels, witnesses: rawptr) -> Metadata_Response ---
}

// Associated-value labels do not affect layout. Ask Swift for an unlabeled
// tuple's complete metadata rather than reconstructing resilient field offsets.
tuple_metadata :: proc(elements: []rawptr) -> rawptr {
	assert(len(elements) >= 2 && len(elements) <= 0xffff)
	return tuple_metadata_native(0, u64(len(elements)), raw_data(elements), nil, nil).type
}

tuple_element :: proc(value, metadata: rawptr, index: int) -> rawptr {
	tuple := cast(^Tuple_Metadata)metadata
	assert(tuple.kind == 0x301 && uint(index) < tuple.count)
	elements := cast([^]Tuple_Element)(uintptr(metadata) + size_of(Tuple_Metadata))
	return rawptr(uintptr(value) + uintptr(elements[index].offset))
}
