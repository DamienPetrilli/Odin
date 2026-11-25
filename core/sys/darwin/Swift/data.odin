#+build darwin, arm64
package darwin_Swift

import "core:mem"

// Two opaque register words of an owned Darwin Foundation.Data result.
Native_Data :: struct {
	first, second: u64,
}

foreign import foundation "system:Foundation.framework"

@(private)
foreign foundation {
	@(link_name="$s10Foundation4DataVN")
	data_metadata: u8
	@(link_name="$s10Foundation4DataV5countSivg")
	data_count :: proc "swift" (first, second: u64) -> int ---
	@(link_name="$s10Foundation4DataV9copyBytes2to5countySpys5UInt8VG_SitF")
	data_copy :: proc "swift" (dst: [^]u8, count: int, first, second: u64) ---
}

// Consume the Swift result on every path. Foundation handles discontiguous,
// inline and sliced storage; the caller owns the resulting Odin allocation.
@(require_results)
data_take :: proc(value: ^Native_Data) -> (bytes: []u8, ok: bool) #optional_ok {
	defer value_deinitialize(value, &data_metadata)
	count := data_count(value.first, value.second)
	if count == 0 { return nil, true }
	if count < 0 { return }
	allocated, err := mem.alloc_bytes_non_zeroed(count)
	if err != .None || raw_data(allocated) == nil { return nil, false }
	bytes = allocated
	data_copy(raw_data(bytes), count, value.first, value.second)
	return bytes, true
}
