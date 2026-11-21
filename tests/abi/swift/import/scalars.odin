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

check_scalars :: proc() {
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
	deadline := time.tick_now()
	for scalar_calls != expected {
		assert(time.tick_since(deadline) < 5*time.Second)
		_ = cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
	}
}
