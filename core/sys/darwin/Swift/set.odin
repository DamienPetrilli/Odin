#+build darwin, arm64
package darwin_Swift

import "base:intrinsics"

// Native storage used by generated Set input conversions. Assignment aliases;
// set_destroy releases one owned reference. Application inputs are Odin slices.
Native_Set :: struct {
	storage: rawptr,
}

@(private)
Set_Table :: struct {
	words: [^]u64,
	mask: int,
}

// __RawSetStorage is fixed-layout ABI storage. Swift allocates the object,
// initializes its seed and empty occupancy words, and owns its final destruction.
@(private)
Set_Storage :: struct {
	metadata, references: rawptr,
	count, capacity: int,
	scale, reserved_scale: i8,
	extra: i16,
	age: i32,
	seed: int,
	elements: rawptr,
}

#assert(size_of(Set_Storage) == 56 && align_of(Set_Storage) == 8)

@(private)
foreign {
	@(link_name="$ss10_NativeSetV8capacityAByxGSi_tcfC")
	set_allocate :: proc "swift" (count: int, metadata, witness: rawptr) -> rawptr ---
	@(link_name="$sSh7_nativeShyxGs10_NativeSetVyxGn_tcfC")
	set_take :: proc "swift" (storage, metadata, witness: rawptr) -> rawptr ---
	@(link_name="$ss10_NativeSetV9hashTables05_HashD0Vvg")
	set_table :: proc "swift" (storage, metadata, witness: rawptr) -> Set_Table ---
	@(link_name="$ss10_NativeSetV9_elementsSpyxGvg")
	set_elements :: proc "swift" (storage, metadata, witness: rawptr) -> rawptr ---
	@(link_name="$ss15__RawSetStorageC6_countSivpWvd")
	set_count_offset: uintptr
	@(link_name="$ss15__RawSetStorageC5_seedSivpWvd")
	set_seed_offset: uintptr
	@(link_name="$sSHMp")
	set_hashable_protocol: u8
	swift_conformsToProtocol :: proc "c" (metadata, descriptor: rawptr) -> rawptr ---
	@(link_name="swift_release")
	set_release_native :: proc "c" (storage: rawptr) ---
}

// Resolve the actual Swift conformance once; Odin equality and hashing must
// not substitute for it. Metadata and conformance have process lifetime.
Set_Conformance :: struct {
	element, witness: rawptr,
}

set_conformance :: proc "contextless" (metadata: rawptr) -> Set_Conformance {
	if metadata == nil { return {} }
	return {metadata, swift_conformsToProtocol(metadata, &set_hashable_protocol)}
}

// Each generated cache belongs to one concrete element type. Concurrent first
// callers may resolve the same process-lifetime witness.
set_conformance_cached :: #force_inline proc "contextless" (cache: ^rawptr, metadata: rawptr) -> Set_Conformance {
	if witness := intrinsics.atomic_load_explicit(cache, .Acquire); witness != nil {
		return {metadata, witness}
	}
	conformance := set_conformance(metadata)
	if conformance.witness != nil {
		intrinsics.atomic_store_explicit(cache, conformance.witness, .Release)
	}
	return conformance
}

// Only generated bindings whose SDK lowering passed the storage/ABI checks use
// this path. The hash and equality procedures are concrete Swift entry points.
// All writes are into a fresh, unpublished Swift allocation; no borrowed input
// or shared/COW storage is mutated. A failed layout check leaves it empty and
// releases it before the importer falls back to the native literal constructor.
@(require_results)
set_from_scalars :: proc(values: []$T, conformance: Set_Conformance, $hash: $H, $equal: $E) -> (result: Native_Set, ok: bool) where T == u64 || T == i64 || T == int || T == uint || T == f64 #optional_ok {
	if len(values) <= 0 || len(values) > max(int)/32 || conformance.witness == nil { return }
	if set_count_offset != offset_of(Set_Storage, count) || set_seed_offset != offset_of(Set_Storage, seed) { return }
	storage := set_allocate(len(values), conformance.element, conformance.witness)
	table := set_table(storage, conformance.element, conformance.witness)
	elements := set_elements(storage, conformance.element, conformance.witness)
	valid := uintptr(table.words)-uintptr(storage) == size_of(Set_Storage) && table.mask > 0 && table.mask < max(int)/16
	if valid {
		buckets := table.mask+1
		words := (buckets+63)/64
		valid = buckets & table.mask == 0 && uintptr(elements)-uintptr(table.words) == uintptr(words*size_of(u64))
	}
	header := cast(^Set_Storage)storage
	if valid {
		valid = header.count == 0 && header.capacity >= len(values) && header.capacity <= table.mask &&
		        header.scale > 0 && header.scale < 63 && (int(1) << uint(header.scale))-1 == table.mask && header.elements == elements
	}
	if !valid {
		set_release_native(storage)
		return
	}
	destination := cast([^]T)elements
	seed := header.seed
	count := 0
	// Swift's frozen hash-table representation uses one occupancy bit per
	// bucket and linear probing. Preserve unused high bits in its final word.
	for value in values {
		bucket := hash(seed, value) & table.mask
		found := false
		for table.words[bucket >> 6] & (u64(1) << uint(bucket & 63)) != 0 {
			if equal(destination[bucket], value) { found = true; break }
			bucket = (bucket+1) & table.mask
		}
		if !found {
			destination[bucket] = value
			table.words[bucket >> 6] |= u64(1) << uint(bucket & 63)
			count += 1
		}
	}
	header.count = count
	// Consumes the native storage reference. Never release storage separately.
	return {set_take(storage, conformance.element, conformance.witness)}, true
}

set_destroy :: proc(value: Native_Set) {
	if value.storage != nil && value.storage != empty_set() {
		set_release_native(value.storage)
	}
}
