#+build darwin, arm64
package darwin_Swift

import "core:mem"

// Returned by a Swift metadata accessor. A blocking request of zero asks for
// complete metadata, including the layout and value witnesses.
Metadata_Response :: struct {
	type: rawptr,
	state: u64,
}

@(private)
Value_Witnesses :: struct {
	copy_buffer: rawptr,
	destroy: proc "c" (value, metadata: rawptr),
	copy: proc "c" (destination, source, metadata: rawptr) -> rawptr,
	assign_copy: rawptr,
	take: rawptr,
	assign_take: rawptr,
	get_single_payload_tag: rawptr,
	store_single_payload_tag: rawptr,
	size: uint,
	stride: uint,
	flags: u32,
	extra_inhabitants: u32,
}

@(private)
Value_Allocation :: struct {
	allocator: mem.Allocator,
}

@(private)
value_witnesses :: proc "contextless" (metadata: rawptr) -> ^Value_Witnesses {
	return (cast(^^Value_Witnesses)(uintptr(metadata) - size_of(rawptr)))^
}

// Allocate uninitialized Swift storage using its runtime layout. The hidden
// allocation header remembers the allocator; destruction need not happen in
// the Odin context which created the value. This does not initialize a value.
@(require_results)
value_allocate :: proc(metadata: rawptr, allocator := context.allocator) -> (value: rawptr, ok: bool) #optional_ok {
	if metadata == nil {
		return
	}
	witness := value_witnesses(metadata)
	alignment := max(uint(witness.flags & 0xff) + 1, uint(align_of(Value_Allocation)))
	header_size := mem.align_forward_uint(size_of(Value_Allocation) + size_of(rawptr), alignment)
	if witness.stride < witness.size || witness.stride == 0 ||
	   witness.stride > uint(max(int))-header_size || alignment & (alignment-1) != 0 {
		return
	}
	allocation, err := mem.alloc(int(header_size + witness.stride), int(alignment), allocator)
	if err != .None {
		return
	}
	header := cast(^Value_Allocation)allocation
	header.allocator = allocator
	value = rawptr(uintptr(allocation) + uintptr(header_size))
	(cast(^^Value_Allocation)(uintptr(value) - size_of(rawptr)))^ = header
	return value, true
}

// Release storage which was never initialized (for example, a throwing result).
// The pointer must have been returned by value_allocate or value_copy.
value_free_uninitialized :: proc(value: rawptr) {
	if value == nil {
		return
	}
	header := (cast(^^Value_Allocation)(uintptr(value) - size_of(rawptr)))^
	mem.free(header, header.allocator)
}

// Initialize a distinct owned value with Swift's copy operation. A plain Odin
// assignment of a typed Swift address only aliases it; it does not call this.
@(require_results)
value_copy :: proc(source, metadata: rawptr, allocator := context.allocator) -> (value: rawptr, ok: bool) #optional_ok {
	if source == nil || metadata == nil {
		return
	}
	value = value_allocate(metadata, allocator) or_return
	value_witnesses(metadata).copy(value, source, metadata)
	return value, true
}

// Destroy an initialized owned value, then release its allocation. Borrowed
// addresses and aliases must not be destroyed independently.
value_destroy :: proc(value, metadata: rawptr) {
	if value == nil {
		return
	}
	value_witnesses(metadata).destroy(value, metadata)
	value_free_uninitialized(value)
}

// Operations on initialized inline storage. Unlike value_destroy, these do
// not free storage; the importer owns the surrounding native temporary.
value_deinitialize :: proc(value, metadata: rawptr) {
	value_witnesses(metadata).destroy(value, metadata)
}

value_initialize_copy :: proc(destination, source, metadata: rawptr) {
	value_witnesses(metadata).copy(destination, source, metadata)
}

// Consume the source even if allocating the independent owner fails. This
// lets a projected enum clean up each field exactly once during a partial take.
@(require_results)
value_take :: proc(source, metadata: rawptr, allocator := context.allocator) -> (value: rawptr, ok: bool) #optional_ok {
	value, ok = value_allocate(metadata, allocator)
	if !ok {
		value_deinitialize(source, metadata)
		return
	}
	take := cast(proc "c" (destination, source, metadata: rawptr) -> rawptr)value_witnesses(metadata).take
	take(value, source, metadata)
	return
}

// Fixed standard-library metadata shared by scalar and tuple projections.
value_metadata :: proc($T: typeid) -> rawptr where T == u64 || T == i64 || T == f64 || T == string {
	return array_element_metadata(T)
}
