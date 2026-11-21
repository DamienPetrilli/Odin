#+build darwin, arm64
package darwin_Swift

import "base:intrinsics"
@(require)
import "core:mem"

@(private)
Array_Allocation :: struct {
	storage, elements: rawptr,
}

@(private)
foreign {
	@(link_name="$ss27_allocateUninitializedArrayySayxG_BptBwlF")
	array_allocate_native :: proc "swift" (count: i64, element: rawptr) -> Array_Allocation ---
	@(link_name="$sSayxSicig")
	array_get_native :: proc "swift" (#swift_result result: rawptr, index: i64, array, element: rawptr) ---
	@(link_name="$sSa5countSivg")
	array_count_native :: proc "swift" (array, element: rawptr) -> i64 ---
	@(link_name="$sSayxGSlsMc")
	array_collection_descriptor: u8
	swift_isUniquelyReferenced_nonNull_native :: proc "c" (object: rawptr) -> bool ---
	swift_getWitnessTable :: proc "c" (descriptor, metadata, arguments: rawptr) -> rawptr ---
	_swiftEmptySetSingleton: u8
}

array_count :: proc(value, element_metadata: rawptr) -> int {
	return int(array_count_native((cast(^rawptr)value)^, element_metadata))
}

// Initializes result with an owned element. Bounds are checked before Swift
// receives the index; result remains uninitialized on failure.
array_get :: proc(result, value, element_metadata: rawptr, index: int) -> bool {
	if value == nil || index < 0 || index >= array_count(value, element_metadata) {
		return false
	}
	array_get_native(result, i64(index), (cast(^rawptr)value)^, element_metadata)
	return true
}

array_collection_witness :: proc(metadata: rawptr) -> rawptr {
	return swift_getWitnessTable(&array_collection_descriptor, metadata, nil)
}

empty_set :: proc "contextless" () -> rawptr {
	return &_swiftEmptySetSingleton
}

// Native Array value, used by compiler-generated calls. Assignment aliases its
// storage; array_destroy drops one owned reference. This is not an Odin slice.
Native_Array :: struct {
	storage: rawptr,
}

@(private)
foreign {
	@(link_name="$ss29_deallocateUninitializedArrayyySayxGnlF")
	array_deallocate_uninitialized :: proc "swift" (array, element: rawptr) ---
	@(link_name="$sSa24_baseAddressIfContiguousSpyxGSgvg")
	array_base_address :: proc "swift" (array, element: rawptr) -> u64 ---
	@(link_name="swift_bridgeObjectRelease")
	array_release :: proc "c" (storage: rawptr) ---
	@(link_name="$ss6UInt64VN")
	array_u64_metadata: u8
	@(link_name="$ss5Int64VN")
	array_i64_metadata: u8
	@(link_name="$sSdN")
	array_f64_metadata: u8
	@(link_name="$sSSN")
	array_string_metadata: u8
	@(link_name="$sSiN")
	array_int_metadata: u8
	@(link_name="$sSuN")
	array_uint_metadata: u8
	@(link_name="$sSbN")
	array_bool_metadata: u8
}

@(private)
array_element_metadata :: proc($T: typeid) -> rawptr where T == bool || T == u64 || T == i64 || T == int || T == uint || T == f64 || T == string {
	when T == u64 { return &array_u64_metadata }
	else when T == i64 { return &array_i64_metadata }
	else when T == f64 { return &array_f64_metadata }
	else when T == string { return &array_string_metadata }
	else when T == int { return &array_int_metadata }
	else when T == uint { return &array_uint_metadata }
	else { return &array_bool_metadata }
}

// _ContiguousArrayStorage and its _ArrayBody are fixed-layout ABI types. The
// supported value elements are all 8-byte aligned. Cache the metadata supplied
// by Swift's allocator only after checking its actual header and tail offset.
// The first allocation (and an unrecognized layout) uses the runtime helper.
@(private)
Array_Storage :: struct {
	metadata, references: rawptr,
	count: i64,
	capacity_and_flags: u64,
}

#assert(size_of(Array_Storage) == 32 && align_of(Array_Storage) == 8)
#assert(offset_of(Array_Storage, count) == 16)
#assert(offset_of(Array_Storage, capacity_and_flags) == 24)

@(private)
array_storage_types: [6]rawptr
@(private)
array_buffer_types: [6]rawptr
@(private)
array_body_metadata: rawptr

@(private)
array_element_index :: proc($T: typeid) -> int {
	when T == u64 { return 0 }
	else when T == i64 { return 1 }
	else when T == f64 { return 2 }
	else when T == string { return 3 }
	else when T == int { return 4 }
	else { return 5 }
}

@(private)
foreign {
	swift_allocObject :: proc "c" (metadata: rawptr, size, alignment_mask: uint) -> rawptr ---
	// ManagedBufferPointer<(UInt64, UInt64), Element> stores the same native
	// object reference. Its byte-capacity getter borrows it without mutation.
	@(link_name="$ss20ManagedBufferPointerV16_capacityInBytesSivg")
	array_allocated_bytes :: proc "swift" (storage, header, element: rawptr) -> i64 ---
	_swiftEmptyArrayStorage: u8
}

@(private)
array_allocate :: proc(count: int, $T: typeid) -> Array_Allocation {
	index := array_element_index(T)
	stride := size_of(T)
	when T == string { stride = size_of(Native_String) }
	metadata := intrinsics.atomic_load(&array_storage_types[index])
	body_metadata := intrinsics.atomic_load(&array_body_metadata)
	if metadata == nil || body_metadata == nil {
		allocation := array_allocate_native(i64(count), array_element_metadata(T))
		// Never interpret the candidate header unless the native tail offset
		// agrees. Metadata has process lifetime; concurrent discoveries agree.
		if uintptr(allocation.elements)-uintptr(allocation.storage) == size_of(Array_Storage) {
			header := cast(^Array_Storage)allocation.storage
			if header.count == i64(count) && header.capacity_and_flags & 1 == 0 &&
			   header.capacity_and_flags >> 1 >= u64(count) {
				body := metadata_from_name("s6UInt64V_ABt")
				if body != nil { intrinsics.atomic_store(&array_body_metadata, body) }
				intrinsics.atomic_store(&array_storage_types[index], header.metadata)
				intrinsics.atomic_store(&array_buffer_types[index], header.metadata)
			}
		}
		return allocation
	}
	storage := cast(^Array_Storage)swift_allocObject(metadata, uint(size_of(Array_Storage)+count*stride), align_of(Array_Storage)-1)
	// Ask Swift for the actual allocation size, as its array constructor does.
	// Advertising only the requested count would force premature array growth.
	capacity := count
	allocated := array_allocated_bytes(storage, body_metadata, array_element_metadata(T))
	if allocated >= i64(size_of(Array_Storage)+count*stride) {
		capacity = (int(allocated)-size_of(Array_Storage))/stride
	}
	storage.count = i64(count)
	storage.capacity_and_flags = u64(capacity) << 1
	return {storage, rawptr(uintptr(storage)+size_of(Array_Storage))}
}

// Initialize directly in Swift-owned storage. On failure, destroy exactly the
// initialized prefix, then use Swift's uninitialized-array deallocation entry.
// The borrowed Odin input can be changed or freed after this returns.
@(require_results)
array_from_odin :: proc(values: []$T) -> (result: Native_Array, ok: bool) where T == u64 || T == i64 || T == int || T == uint || T == f64 || T == string #optional_ok {
	if len(values) == 0 { return Native_Array{&_swiftEmptyArrayStorage}, true }
	stride := size_of(T)
	when T == string { stride = size_of(Native_String) }
	if len(values) < 0 || len(values) > (max(int)-size_of(Array_Storage))/stride {
		return
	}
	allocation := array_allocate(len(values), T)
	when T == string {
		destination := cast([^]Native_String)allocation.elements
		initialized := 0
		for value, i in values {
			converted, valid := string_from_odin(value)
			if !valid {
				for j in 0..<initialized { string_destroy(&destination[j]) }
				array_deallocate_uninitialized(allocation.storage, array_element_metadata(T))
				return
			}
			destination[i] = converted
			initialized += 1
		}
	} else {
		mem.copy_non_overlapping(allocation.elements, raw_data(values), len(values)*size_of(T))
	}
	return Native_Array{allocation.storage}, true
}

// Return an independent Odin-owned slice. Strings also own their UTF-8 bytes:
// delete each string, then delete the slice, using the allocation context.
// Scalar/String arrays have native contiguous storage. Access remains borrowed
// through this copy; no buffer pointer escapes and the Swift value stays owned.
@(require_results)
array_to_odin :: proc(value: Native_Array, $T: typeid) -> (result: []T, ok: bool) where T == u64 || T == i64 || T == int || T == uint || T == f64 || T == string #optional_ok {
	if value.storage == nil { return }
	if value.storage == &_swiftEmptyArrayStorage { return nil, true }
	index := array_element_index(T)
	header := cast(^Array_Storage)value.storage
	metadata := intrinsics.atomic_load(&array_buffer_types[index])
	count: i64
	elements: rawptr
	if metadata != nil && header.metadata == metadata {
		count = header.count
		elements = rawptr(uintptr(value.storage)+size_of(Array_Storage))
	} else {
		element_metadata := array_element_metadata(T)
		count = array_count_native(value.storage, element_metadata)
		elements = rawptr(uintptr(array_base_address(value.storage, element_metadata)))
		if uintptr(elements)-uintptr(value.storage) == size_of(Array_Storage) && header.count == count {
			// This cache permits borrowing only. A static array's metadata must
			// never be used to allocate dynamic storage.
			intrinsics.atomic_store(&array_buffer_types[index], header.metadata)
		}
	}
	if count < 0 || count > i64(max(int)/size_of(T)) { return }
	if count == 0 { return nil, true }
	if elements == nil { return }
	// Keep bulk copies naturally aligned on Darwin, including with Odin's
	// allocation header. Every element is initialized below, so do not zero.
	bytes, err := mem.alloc_bytes_non_zeroed(int(count)*size_of(T), max(16, align_of(T)))
	if err != .None || raw_data(bytes) == nil { return }
	storage := (cast([^]T)raw_data(bytes))[:int(count)]
	when T == string {
		source := cast([^]Native_String)elements
		initialized := 0
		for &element, i in storage {
			converted, valid := string_to_odin(source[i])
			if !valid {
				for j in 0..<initialized { delete(storage[j]) }
				delete(storage)
				return
			}
			element = converted
			initialized += 1
		}
	} else {
		mem.copy_non_overlapping(raw_data(storage), elements, int(count)*size_of(T))
	}
	return storage, true
}

array_destroy :: proc(value: Native_Array) {
	if value.storage != &_swiftEmptyArrayStorage { array_release(value.storage) }
}

// Compiler-generated imported-value arrays use native runtime stride and
// alignment, including resilient elements. A cache belongs to one element type.
Array_Value_Cache :: struct {
	storage, buffer: rawptr,
}

Array_Value_Buffer :: struct {
	value: Native_Array,
	elements: rawptr,
	count, stride: int,
}

@(require_results)
array_value_allocate :: proc(count: int, metadata: rawptr, cache: ^Array_Value_Cache) -> (result: Array_Value_Buffer, ok: bool) #optional_ok {
	if count < 0 || metadata == nil { return }
	witness := value_witnesses(metadata)
	alignment := max(int(witness.flags & 0xff)+1, align_of(Array_Storage))
	offset := mem.align_forward_int(size_of(Array_Storage), alignment)
	if witness.stride == 0 || witness.stride < witness.size ||
	   witness.stride > uint(max(int)-offset) || alignment & (alignment-1) != 0 { return }
	stride := int(witness.stride)
	if count > (max(int)-offset)/stride { return }
	if count == 0 { return {{&_swiftEmptyArrayStorage}, nil, 0, stride}, true }
	storage_type := intrinsics.atomic_load(&cache.storage)
	body_metadata := intrinsics.atomic_load(&array_body_metadata)
	allocation: Array_Allocation
	if storage_type == nil || body_metadata == nil {
		allocation = array_allocate_native(i64(count), metadata)
		if uintptr(allocation.elements)-uintptr(allocation.storage) == uintptr(offset) {
			header := cast(^Array_Storage)allocation.storage
			if header.count == i64(count) && header.capacity_and_flags & 1 == 0 &&
			   header.capacity_and_flags >> 1 >= u64(count) {
				body := metadata_from_name("s6UInt64V_ABt")
				if body != nil { intrinsics.atomic_store(&array_body_metadata, body) }
				intrinsics.atomic_store(&cache.storage, header.metadata)
				intrinsics.atomic_store(&cache.buffer, header.metadata)
			}
		}
	} else {
		storage := cast(^Array_Storage)swift_allocObject(storage_type, uint(offset+count*stride), uint(alignment-1))
		capacity := count
		allocated := array_allocated_bytes(storage, body_metadata, metadata)
		if allocated >= i64(offset+count*stride) { capacity = (int(allocated)-offset)/stride }
		storage.count = i64(count)
		storage.capacity_and_flags = u64(capacity) << 1
		allocation = {storage, rawptr(uintptr(storage)+uintptr(offset))}
	}
	return {{allocation.storage}, allocation.elements, count, stride}, true
}

// Borrow only while the caller retains the native array. No native element is
// consumed or mutated by projection, since Swift may share the same storage.
@(require_results)
array_value_buffer :: proc(value: Native_Array, metadata: rawptr, cache: ^Array_Value_Cache) -> (result: Array_Value_Buffer, ok: bool) #optional_ok {
	if value.storage == nil || metadata == nil { return }
	witness := value_witnesses(metadata)
	if witness.stride == 0 || witness.stride < witness.size || witness.stride > uint(max(int)) { return }
	stride := int(witness.stride)
	if value.storage == &_swiftEmptyArrayStorage { return {value, nil, 0, stride}, true }
	alignment := int(witness.flags & 0xff)+1
	if alignment & (alignment-1) != 0 { return }
	offset := mem.align_forward_int(size_of(Array_Storage), max(alignment, align_of(Array_Storage)))
	header := cast(^Array_Storage)value.storage
	count: i64
	elements: rawptr
	if cached := intrinsics.atomic_load(&cache.buffer); cached != nil && header.metadata == cached {
		count = header.count
		elements = rawptr(uintptr(value.storage)+uintptr(offset))
	} else {
		count = array_count_native(value.storage, metadata)
		elements = rawptr(uintptr(array_base_address(value.storage, metadata)))
		if uintptr(elements)-uintptr(value.storage) == uintptr(offset) && header.count == count {
			intrinsics.atomic_store(&cache.buffer, header.metadata)
		}
	}
	if count < 0 || count > i64((max(int)-offset)/stride) || (count != 0 && elements == nil) { return }
	return {value, elements, int(count), stride}, true
}

array_value_element :: proc(buffer: Array_Value_Buffer, index: int) -> rawptr {
	assert(index >= 0 && index < buffer.count)
	return rawptr(uintptr(buffer.elements)+uintptr(index*buffer.stride))
}

// Abandon a partially initialized native allocation. The initialized prefix is
// destroyed explicitly; the runtime rollback must not destroy it a second time.
array_value_abort :: proc(buffer: Array_Value_Buffer, initialized: int, metadata: rawptr) {
	assert(initialized >= 0 && initialized <= buffer.count)
	for index in 0..<initialized {
		value_deinitialize(array_value_element(buffer, index), metadata)
	}
	array_deallocate_uninitialized(buffer.value.storage, metadata)
}

// The importer proves plain frozen record layouts before using these helpers.
// Verify the runtime witnesses too: POD permits copying bytes and no destruction.
@(private)
array_trivial_layout :: proc(metadata: rawptr, $T: typeid, native_size: int) -> bool {
	if metadata == nil { return false }
	witness := value_witnesses(metadata)
	return witness.flags & 0x10000 == 0 && 0 <= native_size && native_size <= size_of(T) && witness.size == uint(native_size) &&
	       witness.stride == max(1, size_of(T)) && witness.flags & 0xff == align_of(T)-1
}

@(require_results)
array_from_trivial :: proc(values: []$T, metadata: rawptr, cache: ^Array_Value_Cache, native_size := size_of(T), copy_fields: proc(destination: [^]T, source: []T) = nil) -> (result: Native_Array, ok: bool) #optional_ok {
	if !array_trivial_layout(metadata, T, native_size) { return }
	buffer := array_value_allocate(len(values), metadata, cache) or_return
	when size_of(T) != 0 {
		if len(values) != 0 {
			if copy_fields != nil {
				copy_fields(cast([^]T)buffer.elements, values)
			} else {
				mem.copy_non_overlapping(buffer.elements, raw_data(values), len(values)*size_of(T))
			}
		}
	}
	return buffer.value, true
}

@(require_results)
array_to_trivial :: proc(value: Native_Array, metadata: rawptr, cache: ^Array_Value_Cache, $T: typeid, native_size := size_of(T)) -> (result: []T, ok: bool) #optional_ok {
	if !array_trivial_layout(metadata, T, native_size) { return }
	buffer := array_value_buffer(value, metadata, cache) or_return
	if buffer.count == 0 { return nil, true }
	when size_of(T) == 0 {
		values, err := non_zero_make([]T, buffer.count)
		return values, err == nil
	} else {
		// Keep small records inline, use bounded blocks for medium copies,
		// and leave large transfers to the platform bulk-copy routine.
		byte_count := buffer.count*size_of(T)
		// Use stronger alignment for vector and large bulk copies, retaining
		// the caller's allocator and ordinary slice deletion.
		alignment := max(byte_count <= 32768 ? 16 : 64, align_of(T))
		allocator := context.allocator
		if allocator.procedure == nil { return }
		bytes, err := allocator.procedure(allocator.data, .Alloc_Non_Zeroed, byte_count, alignment, nil, 0, #location())
		if err != nil || raw_data(bytes) == nil { return }
		values := (cast([^]T)raw_data(bytes))[:buffer.count]
		if byte_count <= 512 {
			source := cast([^]T)buffer.elements
			for &value, index in values { value = source[index] }
		} else if byte_count <= 32768 {
			destination := raw_data(bytes)
			source := cast([^]byte)buffer.elements
			copied := 0
			for byte_count-copied >= 64 {
				mem.copy_non_overlapping(&destination[copied], &source[copied], 64)
				copied += 64
			}
			mem.copy_non_overlapping(&destination[copied], &source[copied], byte_count-copied)
		} else {
			mem.copy_non_overlapping(raw_data(values), buffer.elements, byte_count)
		}
		return values, true
	}
}

// A resilient element remains a typed native value address, with independently
// owned Swift contents. Batch the Odin storage instead of allocating per slot.
@(require_results)
array_to_values :: proc(value: Native_Array, metadata: rawptr, cache: ^Array_Value_Cache, $T: typeid) -> (result: []T, ok: bool) where intrinsics.type_is_pointer(T) #optional_ok {
	buffer := array_value_buffer(value, metadata, cache) or_return
	return value_allocate_many(buffer.count, metadata, T, source = buffer.elements)
}

// Convert an owned native result which the caller releases immediately after
// this call. Take elements only from the exact native allocation type when
// Swift reports one strong owner; shared/foreign storage is copied. Do not use
// this for a borrowed array: array_to_values preserves its initialized contents.
@(require_results)
array_take_values :: proc(value: Native_Array, metadata: rawptr, cache: ^Array_Value_Cache, $T: typeid) -> (result: []T, ok: bool) where intrinsics.type_is_pointer(T) #optional_ok {
	buffer := array_value_buffer(value, metadata, cache) or_return
	if buffer.count == 0 { return nil, true }
	storage_type := intrinsics.atomic_load(&cache.storage)
	if storage_type == nil {
		// Discover dynamic native storage independently of the borrowed-buffer
		// cache, which may describe static or foreign storage. No live elements.
		probe := array_value_allocate(1, metadata, cache) or_return
		array_value_abort(probe, 0, metadata)
		storage_type = intrinsics.atomic_load(&cache.storage)
	}
	header := cast(^Array_Storage)value.storage
	take_source := storage_type != nil && header.metadata == storage_type && swift_isUniquelyReferenced_nonNull_native(value.storage)
	result = value_allocate_many(buffer.count, metadata, T, source = buffer.elements, take_source = take_source) or_return
	if take_source {
		// The take witness consumed every element. Releasing the array must
		// free its storage without destroying those elements again.
		header.count = 0
	}
	return result, true
}

@(require_results)
array_from_values :: proc(values: []$T, metadata: rawptr, cache: ^Array_Value_Cache) -> (result: Native_Array, ok: bool) where intrinsics.type_is_pointer(T) #optional_ok {
	buffer := array_value_allocate(len(values), metadata, cache) or_return
	initialized := 0
	defer if !ok { array_value_abort(buffer, initialized, metadata) }
	copy_value := value_witnesses(metadata).copy
	for value, index in values {
		if value == nil { return }
		copy_value(array_value_element(buffer, index), rawptr(value), metadata)
		initialized += 1
	}
	return buffer.value, true
}
