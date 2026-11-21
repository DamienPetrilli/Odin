package swift_import_test

foreign import fixture "swift:fixture/SwiftImportFixture"
import swift "core:sys/darwin/Swift"
import "core:mem"
import "core:time"
import cf "core:sys/darwin/CoreFoundation"

scalar_calls: int

bool_received :: proc(task: swift.Task, value: bool) {
	assert(value == (take_expected(task) != 0))
	stored := value
	assert((cast(^u8)&stored)^ <= 1)
	scalar_calls += 1
}
int_received :: proc(task: swift.Task, value: int) {
	assert(cast(u64)value == take_expected(task))
	scalar_calls += 1
}
uint_received :: proc(task: swift.Task, value: uint) {
	assert(u64(value) == take_expected(task))
	scalar_calls += 1
}
optional_bool_received :: proc(task: swift.Task, value: Maybe(bool)) {
	expected := take_expected(task)
	if expected == 2 {
		assert(value == nil)
	} else {
		assert(value.(bool) == (expected != 0))
	}
	scalar_calls += 1
}
ints_received :: proc(task: swift.Task, values: []int, converted: bool) {
	assert(take_expected(task) == 0 && converted)
	assert(len(values) == 3 && values[0] == min(int) && values[1] == -73 && values[2] == max(int))
	delete(values)
	scalar_calls += 1
}

scalar_bits :: proc(value: $T) -> u64 {
	when T == f32 {
		return u64(transmute(u32)value)
	} else {
		return u64(value)
	}
}

width_received :: proc(task: swift.Task, value: $T) {
	assert(scalar_bits(value) == take_expected(task))
	scalar_calls += 1
}

check_width :: proc(values: []$T, $echo: $Echo, $later: $Later) -> int {
	for value in values {
		assert(scalar_bits(echo(value)) == scalar_bits(value))
		task := later(value, width_received) or_else panic("Async scalar width")
		track_task(task, scalar_bits(value))
	}
	return len(values)
}

// All tested widths fit in 32 bits. Use a separate task expectation for nil.
OPTIONAL_ABSENT :: u64(1)<<40

optional_width_received :: proc(task: swift.Task, value: Maybe($T)) {
	expected := take_expected(task)
	if expected == OPTIONAL_ABSENT {
		assert(value == nil)
	} else {
		assert(scalar_bits(value.(T)) == expected)
	}
	scalar_calls += 1
}

check_optional_width :: proc(values: []$T, $echo: $Echo, $later: $Later) -> int {
	assert(echo(nil) == nil)
	track_task(later(nil, optional_width_received) or_else panic("Async nil"), OPTIONAL_ABSENT)
	for value in values {
		actual := echo(value)
		assert(scalar_bits(actual.(T)) == scalar_bits(value))
		track_task(later(value, optional_width_received) or_else panic("Async optional"), scalar_bits(value))
	}
	return 1+len(values)
}

tuple_received :: proc(task: swift.Task, count: u64, ready: bool) {
	assert(count == take_expected(task) && ready == (count != 0))
	scalar_calls += 1
}

packed_tuple_received :: proc(task: swift.Task, value: u8, ready: bool, third, fourth, fifth: u8) {
	assert(value == u8(take_expected(task)) && ready == (value != 0))
	assert(third == 0xfe && fourth == 0x41 && fifth == value+1)
	scalar_calls += 1
}

wide_tuple_received :: proc(task: swift.Task, value: u64, weight: f64, low: i64, next: u64, ready: bool) {
	assert(value == take_expected(task) && ready == (value != 0))
	assert(transmute(u64)weight == 1<<63 && low == min(i64) && next == value+13)
	scalar_calls += 1
}

check_large_tuples :: proc() {
	bytes := [3]u8{11, 23, 47}
	a, b, c, d, e := fixture.indirect_tuple(min(int), bytes[1:])
	assert(a == min(int) && b == 2 && c == -2 && d == 23 && e == -4)
	a, b, c, d, e = fixture.indirect_tuple(17, nil)
	assert(a == 17 && b == 0 && c == -2 && d == 0 && e == -4)
	first, truth, third, fourth, fifth := fixture.packed_bytes(0xff)
	assert(first == 0xff && truth && third == 0xfe && fourth == 0x41 && fifth == 0)
}

check_tuple_borrows :: proc() {
	bytes := [4]u8{19, 23, 41, 47}
	needle: u8 = 41
	index, found := fixture.inspect_prefix(bytes[1:3], &needle)
	assert(found && index == 1)
	index, found = fixture.inspect_prefix(nil, &needle)
	assert(!found && index == 0)
	counter: u16 = 0xfffe
	old, count := fixture.edit_prefix(bytes[1:3], &counter)
	assert(old == 23 && count == counter && count == 0xffff)
	assert(bytes == [4]u8{19, 24, 41, 47})
	old, count = fixture.edit_prefix(nil, &counter)
	assert(old == 0 && counter == 0xffff && count == counter)
}

throwing_tuple_received :: proc(task: swift.Task, count: u64, ready: bool, err: fixture.Async_Error) {
	expected := take_expected(task)
	assert(count == expected && ready == (expected != 0))
	if expected == 0 {
		assert(err.(fixture.PlainFailure) == .Missing)
	} else {
		assert(err == nil)
	}
	fixture.Async_Error_destroy(err)
	scalar_calls += 1
}

throwing_packed_received :: proc(task: swift.Task, n: u8, ready: bool, a, b, c: u8, err: fixture.Async_Error) {
	expected := u8(take_expected(task))
	assert(n == expected && ready == (expected != 0))
	if expected == 0 {
		assert(a == 0 && b == 0 && c == 0 && err.(fixture.PlainFailure) == .Denied)
	} else {
		assert(a == 0xfe && b == 0x41 && c == n+1 && err == nil)
	}
	fixture.Async_Error_destroy(err)
	scalar_calls += 1
}

throwing_wide_received :: proc(task: swift.Task, n: u64, weight: f64, low: i64, next: u64, ready: bool, err: fixture.Async_Error) {
	expected := take_expected(task)
	assert(n == expected && ready == (expected != 0))
	if expected == 0 {
		assert(transmute(u64)weight == 0 && low == 0 && next == 0)
		message := err.(fixture.InspectionFailure).(fixture.InspectionFailure_Message)
		assert(message.value_0 == "kept after the Swift task completed" && message.value_1 == 37)
	} else {
		assert(transmute(u64)weight == 1<<63 && low == min(i64) && next == n+13 && err == nil)
	}
	fixture.Async_Error_destroy(err)
	scalar_calls += 1
}

check_scalars :: proc() {
	check_large_tuples()
	check_tuple_borrows()
	lo, hi := fixture.packed_tuple(0xfe, 0xfcba)
	assert(lo == 0xfe && hi == 0xfcba)
	for flag in ([]bool{true, false}) {
		signed, unsigned, enabled, ratio := fixture.mixed_tuple(min(i8), 0xffed, flag, -0.0)
		assert(signed == min(i8) && unsigned == 0xffed && enabled == flag && transmute(u32)ratio == 0x8000_0000)
	}
	lower, upper := fixture.bounds(max(u64))
	assert(lower == max(u64) && upper == 0)
	integer, fraction, bits, whole := fixture.measure_tuple(-17, -0.0, max(uint), min(int))
	assert(integer == -17 && fraction == 0 && bits == max(uint) && whole == min(int))
	mixed_index, weight := fixture.mixed_labels(-3)
	assert(mixed_index == -3 && weight == 0.5)
	#assert(size_of(int) == 8 && size_of(uint) == 8 && size_of(bool) == 1)
	#assert(size_of(fixture.NativeWords) == 16 && offset_of(fixture.NativeWords, unsigned) == 8)
	state := Value_Allocator{backing = context.allocator, remaining = -1}
	context.allocator = mem.Allocator{procedure = value_allocator, data = &state}
	for value in ([]bool{false, true}) {
		assert(fixture.echo_bool(value) == value)
		assert(fixture.flip_bool(value) == !value)
		assert(fixture.optional_bool(value).(bool) == value)
	}
	assert(fixture.optional_bool(nil) == nil)
	for value in ([]int{min(int), -73, -1, 0, max(int)}) {
		assert(fixture.echo_int(value) == value)
		assert(fixture.optional_int(value).(int) == value)
	}
	for value in ([]uint{0, 1, 73, 1<<63, max(uint)}) {
		assert(fixture.echo_uint(value) == value)
		assert(fixture.optional_uint(value).(uint) == value)
	}
	assert(fixture.optional_int(nil) == nil && fixture.optional_uint(nil) == nil)
	words := fixture.NativeWords{min(int), max(uint)}
	assert(fixture.native_words(words) == words)
	assert(fixture.ScalarState_can_proceed())
	samples := [?]f32{0, 1, 2}
	assert(fixture.inspect_buffer(samples[1:]) == uint(uintptr(&samples[1])))
	assert(fixture.inspect_buffer(nil) == 0)
	guarded := [?]i16{-7, 0, 32767, 9}
	assert(fixture.edit_buffer(guarded[1:3]) == 2 && guarded == [4]i16{-7, 1, -32768, 9})
	assert(fixture.edit_buffer(nil) == 0)
	word := u32(0xfedcba98)
	assert(fixture.read_pointer(&word) == word)
	fixture.write_pointer(&samples[1], -1.25)
	assert(samples == [3]f32{0, -1.25, 2})
	assert(state.allocations == 0)
	owner := fixture.ScalarState_init(true, min(int), max(uint)) or_else panic("Scalar getters")
	assert(fixture.ScalarState_ready(owner))
	assert(fixture.ScalarState_signed(owner) == min(int))
	assert(fixture.ScalarState_unsigned(owner) == max(uint))
	fixture.ScalarState_destroy(owner)
	for count in ([]int{0, 1, 3, 1024}) {
		ints := make([]int, count)
		uints := make([]uint, count)
		for index in 0..<count {
			ints[index] = min(int)+index
			uints[index] = max(uint)-uint(index)
		}
		for _ in 0..<2 {
			copied_ints := fixture.native_ints(ints) or_else panic("Int array")
			copied_uints := fixture.native_uints(uints) or_else panic("UInt array")
			assert(len(copied_ints) == count && len(copied_uints) == count)
			for index in 0..<count {
				assert(copied_ints[index] == ints[index] && copied_uints[index] == uints[index])
			}
			if count != 0 {
				copied_ints[0] = 73
				copied_uints[0] = 73
				assert(ints[0] == min(int) && uints[0] == max(uint))
			}
			delete(copied_ints)
			delete(copied_uints)
		}
		delete(ints)
		delete(uints)
	}
	assert(state.allocations == state.frees)
	context.allocator = state.backing

	expected := 0
	for value in ([]u64{0, 255, max(u64)}) {
		pair := fixture.async_tuple(value, tuple_received) or_else panic("Async result pair")
		track_task(pair, value)
		packed := fixture.packed_tuple_later(u8(value), packed_tuple_received) or_else panic("Async packed result")
		track_task(packed, value)
		wide := fixture.wide_tuple_later(value, wide_tuple_received) or_else panic("Async indirect result")
		track_task(wide, value)
		pair = fixture.throwing_tuple(value, throwing_tuple_received) or_else panic("Throwing tuple")
		track_task(pair, value)
		packed = fixture.throwing_packed_tuple(u8(value), throwing_packed_received) or_else panic("Throwing packed tuple")
		track_task(packed, value)
		wide = fixture.throwing_wide_tuple(value, throwing_wide_received) or_else panic("Throwing indirect tuple")
		track_task(wide, value)
		expected += 6
	}

	for value in ([]bool{false, true}) {
		task := fixture.echo_bool_later(value, bool_received) or_else panic("Async Bool")
		track_task(task, u64(value))
		expected += 1
	}
	for value in ([]int{min(int), -73, -1, 0, max(int)}) {
		task := fixture.echo_int_later(value, int_received) or_else panic("Async Int")
		track_task(task, cast(u64)value)
		expected += 1
	}
	for value in ([]uint{0, 1, 73, 1<<63, max(uint)}) {
		task := fixture.echo_uint_later(value, uint_received) or_else panic("Async UInt")
		track_task(task, u64(value))
		expected += 1
	}
	for value, index in ([]Maybe(bool){false, true, nil}) {
		task := fixture.optional_bool_later(value, optional_bool_received) or_else panic("Async optional Bool")
		track_task(task, u64(index))
		expected += 1
	}
	flag := true
	signed := -73
	unsigned := max(uint)
	task := fixture.mixed_scalars_later(flag, signed, unsigned, bool_received) or_else panic("Async scalar capture")
	track_task(task, 1)
	expected += 1
	flag, signed, unsigned = false, 0, 0
	input := []int{min(int), -73, max(int)}
	task = fixture.native_ints_later(input, ints_received) or_else panic("Async Int array")
	track_task(task)
	expected += 1
	input[0] = 0
	expected += check_width([]i8{min(i8), max(i8), 1}, fixture.echo_int8, fixture.echo_int8_later)
	expected += check_width([]u8{min(u8), max(u8), 1}, fixture.echo_uint8, fixture.echo_uint8_later)
	expected += check_width([]i16{min(i16), max(i16), 1}, fixture.echo_int16, fixture.echo_int16_later)
	expected += check_width([]u16{min(u16), max(u16), 1}, fixture.echo_uint16, fixture.echo_uint16_later)
	expected += check_width([]i32{min(i32), max(i32), 1}, fixture.echo_int32, fixture.echo_int32_later)
	expected += check_width([]u32{min(u32), max(u32), 1}, fixture.echo_uint32, fixture.echo_uint32_later)
	expected += check_width([]f32{0, -1.25, transmute(f32)u32(0x80000000), transmute(f32)u32(0x7fc01234)}, fixture.echo_float, fixture.echo_float_later)
	expected += check_optional_width([]i8{0, min(i8), max(i8), 1}, fixture.optional_int8, fixture.optional_int8_later)
	expected += check_optional_width([]u8{min(u8), max(u8), 1}, fixture.optional_uint8, fixture.optional_uint8_later)
	expected += check_optional_width([]i16{0, min(i16), max(i16), 1}, fixture.optional_int16, fixture.optional_int16_later)
	expected += check_optional_width([]u16{min(u16), max(u16), 1}, fixture.optional_uint16, fixture.optional_uint16_later)
	expected += check_optional_width([]i32{0, min(i32), max(i32), 1}, fixture.optional_int32, fixture.optional_int32_later)
	expected += check_optional_width([]u32{min(u32), max(u32), 1}, fixture.optional_uint32, fixture.optional_uint32_later)
	expected += check_optional_width([]f32{0, -1.25, transmute(f32)u32(0x80000000), transmute(f32)u32(0x7fc01234)}, fixture.optional_float, fixture.optional_float_later)
	none: Maybe(i8)
	some_none: Maybe(Maybe(i8)) = none
	assert(fixture.nested_int8(nil) == nil)
	inner, present := fixture.nested_int8(some_none).?
	assert(present && inner == nil)
	some: Maybe(i8) = min(i8)
	inner, present = fixture.nested_int8(Maybe(Maybe(i8))(some)).?
	assert(present && inner.(i8) == min(i8))
	deadline := time.tick_now()
	for scalar_calls != expected {
		assert(time.tick_since(deadline) < 5*time.Second)
		_ = cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
	}
}
