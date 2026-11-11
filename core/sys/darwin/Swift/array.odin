#+build darwin, arm64
package darwin_Swift

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

// Copy every input string before returning. Build initialized temporary values
// first so a failed conversion never leaves a partially initialized Swift Array.
@(require_results)
array_from_strings :: proc(values: []string, metadata: rawptr) -> (array: rawptr, ok: bool) #optional_ok {
	storage := value_allocate(metadata) or_return
	strings, err := make([]Native_String, len(values))
	if err != .None {
		value_free_uninitialized(storage)
		return nil, false
	}
	defer delete(strings)
	initialized := 0
	defer if !ok {
		for i in 0..<initialized {
			string_destroy(&strings[i])
		}
		value_free_uninitialized(storage)
	}
	for value, i in values {
		converted, valid := string_from_odin(value)
		if !valid {
			return nil, false
		}
		strings[i] = converted
		initialized += 1
	}
	string_metadata := metadata_from_name("SS")
	allocation := array_allocate_native(i64(len(values)), string_metadata)
	destination := cast([^]Native_String)allocation.elements
	take := cast(proc "c" (destination, source, metadata: rawptr) -> rawptr)value_witnesses(string_metadata).take
	for i in 0..<len(values) {
		take(&destination[i], &strings[i], string_metadata)
	}
	(cast(^rawptr)storage)^ = allocation.storage
	array, ok = storage, true
	return
}
