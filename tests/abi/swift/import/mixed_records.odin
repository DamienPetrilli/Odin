package swift_import_test

foreign import fixture "swift:fixture/SwiftImportFixture"
import "core:time"
import cf "core:sys/darwin/CoreFoundation"
import swift "core:sys/darwin/Swift"

mixed_record_calls: int

bool_triple_received :: proc(task: swift.Task, value: fixture.BoolTriple) {
	assert(take_expected(task) == 9 && value == fixture.BoolTriple{true, false, true})
	mixed_record_calls += 1
}

bool_tail_received :: proc(task: swift.Task, value: fixture.BoolTail) {
	assert(take_expected(task) == 9 && value == fixture.BoolTail{-73, true})
	mixed_record_calls += 1
}

bool_mixed_received :: proc(task: swift.Task, value: fixture.BoolMixed) {
	assert(take_expected(task) == 9 && value == fixture.BoolMixed{true, false, -73, 0.5, true})
	mixed_record_calls += 1
}

bool_wide_received :: proc(task: swift.Task, value: fixture.BoolWide) {
	assert(take_expected(task) == 9 && value == fixture.BoolWide{true, -73, max(uint), 0.5, 41, false})
	mixed_record_calls += 1
}

bool_tails_received :: proc(task: swift.Task, values: []fixture.BoolTail, converted: bool) {
	assert(take_expected(task) == 9 && converted && len(values) == 1)
	assert(values[0] == fixture.BoolTail{-73, true})
	delete(values)
	mixed_record_calls += 1
}

bool_mixed_checked :: proc(task: swift.Task, value: fixture.BoolMixed, error: fixture.Async_Error) {
	failed := take_expected(task) == 1
	assert((error != nil) == failed)
	if failed {
		assert(value == fixture.BoolMixed{})
	} else {
		assert(value == fixture.BoolMixed{true, false, -73, 0.5, true})
	}
	fixture.Async_Error_destroy(error)
	mixed_record_calls += 1
}

check_mixed_records :: proc() {
	#assert(size_of(fixture.BoolOnly) == 1 && align_of(fixture.BoolOnly) == 1)
	#assert(size_of(fixture.BoolTriple) == 3 && size_of(fixture.BoolRun) == 9)
	#assert(size_of(fixture.BoolHead) == 16 && offset_of(fixture.BoolHead, count) == 8)
	#assert(size_of(fixture.BoolTail) == 16 && offset_of(fixture.BoolTail, flag) == 8)
	#assert(size_of(fixture.BoolMixed) == 32 && offset_of(fixture.BoolMixed, c) == 24)
	#assert(size_of(fixture.BoolWide) == 48 && offset_of(fixture.BoolWide, end) == 40)
	// The same packed-byte lowering handles four nested Optional tags.
	M1 :: Maybe(u64)
	M2 :: Maybe(M1)
	M3 :: Maybe(M2)
	M4 :: Maybe(M3)
	for input in ([]M4{nil, M3(nil), M3(M2(nil)), M3(M2(M1(nil))), M3(M2(M1(u64(73))))}) {
		assert(fixture.deep_optional(input) == input)
	}
	state := Value_Allocator{backing = context.allocator, remaining = -1}
	context.allocator = {procedure = value_allocator, data = &state}
	for flag in ([]bool{false, true}) {
		assert(fixture.echo_bool_only({flag}) == fixture.BoolOnly{flag})
		assert(fixture.echo_bool_head({flag, min(int)}) == fixture.BoolHead{flag, min(int)})
		assert(fixture.echo_bool_tail({max(int), flag}) == fixture.BoolTail{max(int), flag})
	}
	for mask in 0..<512 {
		value := fixture.BoolRun{mask&1 != 0, mask&2 != 0, mask&4 != 0, mask&8 != 0, mask&16 != 0, mask&32 != 0, mask&64 != 0, mask&128 != 0, mask&256 != 0}
		result := fixture.echo_bool_run(value)
		assert(result == value)
		bytes := (cast([^]u8)&result)[:size_of(result)]
		for byte in bytes { assert(byte == 0 || byte == 1) }
		triple := fixture.BoolTriple{value.a, value.b, value.c}
		assert(fixture.echo_bool_triple(triple) == triple)
		assert(fixture.optional_bool_triple(triple).(fixture.BoolTriple) == triple)
	}
	mixed := fixture.BoolMixed{true, false, -73, 0.5, true}
	wide := fixture.BoolWide{true, -73, max(uint), 0.5, 41, false}
	tail := fixture.BoolTail{-73, true}
	assert(fixture.echo_bool_mixed(mixed) == mixed)
	assert(fixture.flip_bool_mixed(mixed) == fixture.BoolMixed{false, true, -72, 0.75, false})
	assert(fixture.echo_bool_wide(wide) == wide)
	assert(fixture.optional_bool_tail(tail).(fixture.BoolTail) == tail)
	assert(fixture.optional_bool_mixed(mixed).(fixture.BoolMixed) == mixed)
	assert(fixture.optional_bool_wide(wide).(fixture.BoolWide) == wide)
	assert(fixture.optional_bool_triple(nil) == nil && fixture.optional_bool_tail(nil) == nil)
	assert(fixture.optional_bool_mixed(nil) == nil && fixture.optional_bool_wide(nil) == nil)
	result := fixture.echo_bool_record_result(fixture.BoolRecordResult_Value{mixed})
	assert(result.(fixture.BoolRecordResult_Value).value == mixed)
	assert(state.allocations == 0)

	for count in ([]int{0, 1, 2, 3, 7, 8, 9, 31, 32, 33, 1024}) {
		triples := make([]fixture.BoolTriple, count)
		tails := make([]fixture.BoolTail, count)
		mixed_values := make([]fixture.BoolMixed, count)
		wide_values := make([]fixture.BoolWide, count)
		for index in 0..<count {
			triples[index] = {index&1 != 0, index&2 != 0, index&4 != 0}
			tails[index] = {index, index&1 != 0}
			mixed_values[index] = {true, false, index, 0.5, index&1 != 0}
			wide_values[index] = {false, index, max(uint), 0.5, -index, true}
		}
		before := state.allocations
		a := fixture.echo_bool_triples(triples) or_else panic("Bool triple array")
		b := fixture.echo_bool_tails(tails) or_else panic("Bool tail array")
		c := fixture.echo_bool_mixeds(mixed_values) or_else panic("Mixed Bool array")
		d := fixture.echo_bool_wides(wide_values) or_else panic("Wide Bool array")
		assert(state.allocations == before+(count == 0 ? 0 : 4))
		for index in 0..<count {
			assert(a[index] == triples[index] && b[index] == tails[index])
			assert(c[index] == mixed_values[index] && d[index] == wide_values[index])
		}
		if count != 0 { b[0].flag = !tails[0].flag; assert(b[0].flag != tails[0].flag) }
		delete(a)
		delete(b)
		delete(c)
		delete(d)
		delete(triples)
		delete(tails)
		delete(mixed_values)
		delete(wide_values)
	}
	assert(state.allocations == state.frees)
	state.remaining = 0
	failed, ok := fixture.echo_bool_tails([]fixture.BoolTail{tail})
	assert(!ok && failed == nil)
	state.remaining = -1

	task := fixture.echo_bool_triple_later({true, false, true}, bool_triple_received) or_else panic("Async Bool triple")
	track_task(task, 9)
	task = fixture.echo_bool_tail_later(tail, bool_tail_received) or_else panic("Async Bool tail")
	track_task(task, 9)
	task = fixture.echo_bool_mixed_later(mixed, bool_mixed_received) or_else panic("Async mixed record")
	track_task(task, 9)
	task = fixture.echo_bool_wide_later(wide, bool_wide_received) or_else panic("Async indirect record")
	track_task(task, 9)
	input := []fixture.BoolTail{tail}
	task = fixture.echo_bool_tails_later(input, bool_tails_received) or_else panic("Async padded array")
	track_task(task, 9)
	input[0].flag = false
	for flag in ([]bool{false, true}) {
		task = fixture.checked_bool_mixed_later(mixed, flag, bool_mixed_checked) or_else panic("Async checked record")
		track_task(task, u64(flag))
	}
	mixed.a = false
	wide.flag = false
	deadline := time.tick_now()
	for mixed_record_calls != 7 {
		assert(time.tick_since(deadline) < 5*time.Second)
		_ = cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
	}
	assert(state.allocations == state.frees && fixture.live_value_count() == 0)
}
