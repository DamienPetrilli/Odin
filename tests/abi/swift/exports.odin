package swift_abi

foreign import fixture "Fixture.o"

Reading :: struct {
	page:     i64,
	progress: f64,
}

#assert(size_of(Reading) == 16)
#assert(size_of([2]Reading) == 32)
#assert(align_of(Reading) == 8)
#assert(offset_of(Reading, page) == 0)
#assert(offset_of(Reading, progress) == 8)

foreign fixture {
	@(link_name="$s15SwiftABIFixture9addScalarySds5Int64V_SdtF")
	add_scalar :: proc "swift" (whole: i64, fraction: f64) -> f64 ---

	@(link_name="$s15SwiftABIFixture7advanceyAA7ReadingVs5Int64V_ADSdtF")
	advance :: proc "swift" (pages: i64, reading: Reading, fraction: f64) -> Reading ---

	@(link_name="$s15SwiftABIFixture13changeInPlaceySpyAA7ReadingVGAE_s5Int64VSdtF")
	change_in_place :: proc "swift" (reading: ^Reading, pages: i64, fraction: f64) -> ^Reading ---

	@(link_name="$s15SwiftABIFixture9fillBytesys5Int64VSpys5UInt8VG_ADtF")
	fill_bytes :: proc "swift" (output: [^]u8, capacity: i64) -> i64 ---
}

@(export)
odin_swift_abi_add_scalar :: proc "swift" (whole: i64, fraction: f64) -> f64 {
	return f64(whole) + fraction
}

@(export)
odin_swift_abi_advance :: proc "swift" (pages: i64, reading: Reading, fraction: f64) -> Reading {
	return {page = reading.page + pages, progress = reading.progress + fraction}
}

@(export)
odin_swift_abi_change_in_place :: proc "swift" (reading: ^Reading, pages: i64, fraction: f64) -> ^Reading {
	reading^ = odin_swift_abi_advance(pages, reading^, fraction)
	return reading
}

@(export)
odin_swift_abi_fill_bytes :: proc "swift" (output: [^]u8, capacity: i64) -> i64 {
	if capacity < 3 {
		return 0
	}
	output[0] = 13
	output[1] = 29
	output[2] = 61
	return 3
}

@(export)
odin_swift_abi_check_imports :: proc "swift" () -> i64 {
	if add_scalar(41, 0.5) != 41.5 {
		return 1
	}

	advance_reading := advance
	original := Reading{page = 41, progress = 0.25}
	reading := advance_reading(5, original, 0.125)
	if reading != (Reading{page = 46, progress = 0.375}) || original != (Reading{page = 41, progress = 0.25}) {
		return 2
	}

	before := Reading{page = 111, progress = 0.75}
	after := Reading{page = 222, progress = 1.25}
	records := [3]Reading{before, original, after}
	middle := &records[1]
	if change_in_place(middle, 5, 0.125) != middle || records != ([3]Reading{before, reading, after}) {
		return 3
	}

	initial := [6]u8{0xa5, 255, 255, 255, 255, 0x5a}
	bytes := initial
	output := raw_data(bytes[1:5])
	if fill_bytes(output, 0) != 0 || fill_bytes(output, 2) != 0 || bytes != initial {
		return 4
	}
	if fill_bytes(output, 4) != 3 || bytes != ([6]u8{0xa5, 13, 29, 61, 255, 0x5a}) {
		return 5
	}
	return 0
}
