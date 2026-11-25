#+build darwin, arm64
package darwin_Swift

import "base:intrinsics"
import "core:mem"
import "core:sync"

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
arena_value_header: Value_Allocation

// Select an arena for Swift intermediates destroyed together at the end of
// a scope. Its Swift owners must be destroyed before reusing the arena.
value_arena_allocator :: proc(arena: ^mem.Arena) -> mem.Allocator {
	return {procedure = value_arena_allocator_proc, data = arena}
}

@(private)
value_arena_allocator_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	return mem.arena_allocator_proc(data, mode, size, alignment, old, old_size, loc)
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
	if allocator.procedure == value_arena_allocator_proc {
		return allocate_value_storage(metadata, allocator, true)
	}
	return allocate_value_storage(metadata, allocator, false)
}

@(private)
allocate_value_storage :: proc(metadata: rawptr, allocator: mem.Allocator, $in_arena: bool) -> (value: rawptr, ok: bool) #optional_ok {
	if metadata == nil {
		return
	}
	witness := value_witnesses(metadata)
	alignment := max(uint(witness.flags & 0xff) + 1, uint(align_of(Value_Allocation)))
	header_size := alignment if in_arena else mem.align_forward_uint(size_of(Value_Allocation) + size_of(rawptr), alignment)
	if witness.stride < witness.size || witness.stride == 0 ||
	   witness.stride > uint(max(int))-header_size || alignment & (alignment-1) != 0 {
		return
	}
	allocation: rawptr
	err: mem.Allocator_Error
	when in_arena {
		allocation, err = mem.arena_alloc_non_zeroed(cast(^mem.Arena)allocator.data, int(header_size + witness.stride), int(alignment))
	} else {
		allocation, err = mem.alloc(int(header_size + witness.stride), int(alignment), allocator)
	}
	if err != .None || allocation == nil {
		return
	}
	header := &arena_value_header
	when !in_arena {
		header = cast(^Value_Allocation)allocation
		header.allocator = allocator
	}
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
	if header == &arena_value_header { return }
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
	witness := value_witnesses(metadata)
	if witness.flags & 0x10000 != 0 { witness.destroy(value, metadata) }
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
value_metadata :: proc($T: typeid) -> rawptr where T == bool || T == int || T == uint || T == u64 || T == i64 || T == f64 || T == string {
	return array_element_metadata(T)
}

@(private)
Value_Batch :: struct {
	allocator: mem.Allocator,
	remaining: int,
	header: Value_Allocation,
}

@(private)
value_batch_release :: proc(batch: ^Value_Batch, count: int, loc := #caller_location) {
	if intrinsics.atomic_sub(&batch.remaining, count) == count { mem.free(batch, batch.allocator, loc) }
}

// Values in a batch share the ordinary allocation header. Its saved allocator
// releases one slot; the last independently destroyed slot releases the block.
// This changes allocation granularity, not Swift ownership or Odin assignment.
@(private)
value_batch_free :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	if mode != .Free { return nil, .Mode_Not_Implemented }
	if old_memory == nil { return nil, .None }
	batch := cast(^Value_Batch)data
	value_batch_release(batch, 1, loc)
	return nil, .None
}

// Allocate a slice of typed addresses and one block of uninitialized value
// slots. A non-nil source initializes each slot from contiguous native values
// in the same pass; otherwise the caller must initialize every slot. Taking
// consumes the source values on success. Both allocations finish before any
// value is copied or taken, so allocation failure leaves the source unchanged.
// Swift initialization witnesses do not return recoverable allocation failures.
@(require_results)
value_allocate_many :: proc(count: int, metadata: rawptr, $T: typeid, allocator := context.allocator, source: rawptr = nil, take_source := false) -> (result: []T, ok: bool) where intrinsics.type_is_pointer(T) #optional_ok {
	if count < 0 || metadata == nil { return }
	if count == 0 { return nil, true }
	witness := value_witnesses(metadata)
	alignment := max(uint(witness.flags & 0xff)+1, uint(align_of(Value_Allocation)), uint(align_of(Value_Batch)))
	prefix := mem.align_forward_uint(size_of(rawptr), alignment)
	begin := mem.align_forward_uint(size_of(Value_Batch), alignment)
	if alignment & (alignment-1) != 0 || witness.stride == 0 || witness.stride < witness.size ||
	   witness.stride > uint(max(int))-prefix-alignment { return }
	stride := mem.align_forward_uint(prefix+witness.stride, alignment)
	if uint(count) > (uint(max(int))-begin)/stride || count > max(int)/size_of(T) { return }
	// Sizes and alignments are checked above; dispatch directly to the
	// supplied allocator without repeating those checks for each block.
	if allocator.procedure == nil { return }
	pointer_bytes, err := allocator.procedure(allocator.data, .Alloc_Non_Zeroed, count*size_of(T), align_of(T), nil, 0, #location())
	if err != .None || raw_data(pointer_bytes) == nil { return }
	values := (cast([^]T)raw_data(pointer_bytes))[:count]
	defer if !ok { delete(values, allocator) }
	if count == 1 {
		// One value needs the ordinary saved allocator, not a batch counter.
		// Keep it separate from the slice so either can outlive the other.
		header_size := mem.align_forward_uint(size_of(Value_Allocation)+size_of(rawptr), alignment)
		bytes, error := allocator.procedure(allocator.data, .Alloc_Non_Zeroed, int(header_size+witness.stride), int(alignment), nil, 0, #location())
		if error != .None || raw_data(bytes) == nil { return }
		header := cast(^Value_Allocation)raw_data(bytes)
		header.allocator = allocator
		value := rawptr(uintptr(header)+uintptr(header_size))
		(cast(^^Value_Allocation)(uintptr(value)-size_of(rawptr)))^ = header
		values[0] = cast(T)value
		if source != nil {
			initialize := witness.copy
			if take_source { initialize = cast(type_of(initialize))witness.take }
			initialize(value, source, metadata)
		}
		return values, true
	}
	bytes, error := allocator.procedure(allocator.data, .Alloc_Non_Zeroed, int(begin+uint(count)*stride), int(alignment), nil, 0, #location())
	allocation := raw_data(bytes)
	if error != .None || allocation == nil { return }
	batch := cast(^Value_Batch)allocation
	batch.allocator = allocator
	batch.remaining = count
	batch.header.allocator = {procedure = value_batch_free, data = batch}
	initialize_value := witness.copy
	if take_source { initialize_value = cast(type_of(initialize_value))witness.take }
	native_stride := witness.stride
	address := uintptr(allocation)+uintptr(begin+prefix)
	native := uintptr(source)
	if source != nil {
		for &value in values {
			(cast(^^Value_Allocation)(address-size_of(rawptr)))^ = &batch.header
			value = cast(T)rawptr(address)
			initialize_value(rawptr(address), rawptr(native), metadata)
			address += uintptr(stride)
			native += uintptr(native_stride)
		}
	} else {
		for &value in values {
			(cast(^^Value_Allocation)(address-size_of(rawptr)))^ = &batch.header
			value = cast(T)rawptr(address)
			address += uintptr(stride)
		}
	}
	return values, true
}

@(require_results)
value_copy_many :: proc(values: []$T, metadata: rawptr, allocator := context.allocator) -> (result: []T, ok: bool) where intrinsics.type_is_pointer(T) #optional_ok {
	for value in values { if value == nil { return } }
	result = value_allocate_many(len(values), metadata, T, allocator) or_return
	if len(values) != 0 {
		copy_value := value_witnesses(metadata).copy
		for value, index in values { copy_value(rawptr(result[index]), rawptr(value), metadata) }
	}
	return result, true
}

// Release consecutive slots from the same backing block together. A slice may
// contain moved slots, independent copies or values from different batches.
// Destruction precedes the final slot release; concurrent owners keep their
// remaining slots alive. Scan and destroy in one pass, bounding every pointer
// access by the slice length. This does not release the slice allocation itself.
value_destroy_many :: proc(values: []$T, metadata: rawptr) where intrinsics.type_is_pointer(T) {
	witness := value_witnesses(metadata)
	destroy_value := witness.destroy
	non_trivial := witness.flags & 0x10000 != 0
	pointers := raw_data(values)
	index := 0
	for index < len(values) {
		value := pointers[index]
		if value == nil { index += 1; continue }
		header := (cast(^^Value_Allocation)(uintptr(value)-size_of(rawptr)))^
		if header.allocator.procedure != value_batch_free {
			if non_trivial { destroy_value(rawptr(value), metadata) }
			if header != &arena_value_header { mem.free(header, header.allocator) }
			index += 1
			continue
		}
		batch := cast(^Value_Batch)header.allocator.data
		end := index+1
		if non_trivial {
			destroy_value(rawptr(value), metadata)
			for end < len(values) {
				next := pointers[end]
				if next == nil || (cast(^^Value_Allocation)(uintptr(next)-size_of(rawptr)))^ != header { break }
				destroy_value(rawptr(next), metadata)
				end += 1
			}
		} else {
			for end < len(values) {
				next := pointers[end]
				if next == nil || (cast(^^Value_Allocation)(uintptr(next)-size_of(rawptr)))^ != header { break }
				end += 1
			}
		}
		value_batch_release(batch, end-index)
		index = end
	}
}

// Caller-owned scratch for a synchronous native value. Check the runtime layout
// before borrowing this buffer; larger future values retain the allocation path.
// Never copy a pointer into this storage into an asynchronous task capture.
Value_Temporary :: struct #align(16) {
	bytes: [64]u8,
}

@(require_results)
value_temporary :: proc(temporary: ^Value_Temporary, metadata: rawptr) -> (value: rawptr, ok: bool) #optional_ok {
	if temporary == nil || metadata == nil { return }
	witness := value_witnesses(metadata)
	alignment := uint(witness.flags & 0xff)+1
	if witness.stride >= witness.size && witness.stride > 0 &&
	   witness.stride <= size_of(Value_Temporary) && alignment <= align_of(Value_Temporary) &&
	   alignment & (alignment-1) == 0 {
		return temporary, true
	}
	return value_allocate(metadata)
}

// Storage only: deinitialize the native value first if it still owns a value.
value_temporary_free :: proc(temporary: ^Value_Temporary, value: rawptr) {
	if value != rawptr(temporary) {
		value_free_uninitialized(value)
	}
}

// Only the scoped value arena reserves storage before it knows the enum tag.
// If it is full the ordinary projection can still deliver an empty optional.
@(require_results)
optional_owner_reserve :: #force_inline proc(metadata: rawptr) -> (value: rawptr, ok: bool) #optional_ok {
	if context.allocator.procedure != value_arena_allocator_proc { return }
	return allocate_value_storage(metadata, context.allocator, true)
}

// Swift.Optional is a single-payload enum. Once Swift identifies .some,
// the payload is already initialized at the start of its allocation.
optional_owner_project :: proc(storage, metadata: rawptr, some: u32, $T: typeid) -> Maybe(T) where intrinsics.type_is_pointer(T) {
	tag, valid := enum_tag(storage, metadata)
	assert(valid)
	if tag != some {
		value_free_uninitialized(storage)
		return nil
	}
	return T(storage)
}

// Complete Swift metadata and value witnesses are immutable.
Value_Layout :: struct {
	metadata: rawptr,
	destroy: proc "c" (value, metadata: rawptr),
	inline_temporary: bool,
}

value_layout :: proc "contextless" (metadata: rawptr) -> Value_Layout {
	if metadata == nil { return {} }
	witness := value_witnesses(metadata)
	alignment := uint(witness.flags & 0xff)+1
	fits := witness.stride >= witness.size && witness.stride > 0 &&
	        witness.stride <= size_of(Value_Temporary) && alignment <= align_of(Value_Temporary) &&
	        alignment & (alignment-1) == 0
	// Swift ABI ValueWitnessFlags::IsNonPOD: POD destruction is a no-op.
	destroy := witness.destroy
	if witness.flags & 0x10000 == 0 { destroy = nil }
	return {metadata, destroy, fits}
}

@(private)
Value_Layout_Cache :: struct {
	once:   sync.Once,
	layout: Value_Layout,
}

// One layout per concrete accessor, including when Swift owns the entry point.
value_layout_for :: #force_inline proc "contextless" ($accessor: proc "swift" (request: u64) -> Metadata_Response) -> Value_Layout {
	@(static) cache: Value_Layout_Cache
	sync.once_do(&cache.once, proc "contextless" () { cache.layout = value_layout(accessor(0).type) })
	return cache.layout
}

@(require_results)
value_temporary_from_layout :: #force_inline proc(temporary: ^Value_Temporary, layout: Value_Layout) -> (value: rawptr, ok: bool) #optional_ok {
	if temporary == nil { return }
	if layout.inline_temporary { return temporary, true }
	return #force_no_inline value_allocate(layout.metadata)
}

value_deinitialize_from_layout :: #force_inline proc(value: rawptr, layout: Value_Layout) {
	if layout.destroy != nil { layout.destroy(value, layout.metadata) }
}
