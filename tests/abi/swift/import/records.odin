package swift_import_test

foreign import fixture "swift:fixture/SwiftImportFixture"
import swift "core:sys/darwin/Swift"
import "core:mem"
import "core:time"
import cf "core:sys/darwin/CoreFoundation"

record_calls: int
record_received :: proc(task: swift.Task, value: fixture.ArrayRecord) {
	assert(take_expected(task) == 9)
	assert(value == fixture.ArrayRecord{9, 0.5, 10})
	record_calls += 1
}
wide_received :: proc(task: swift.Task, value: fixture.WideRecord) {
	assert(take_expected(task) == 9)
	assert(value == fixture.WideRecord{9, -73, 0.5, 10, 11})
	record_calls += 1
}
records_received :: proc(task: swift.Task, values: []fixture.ArrayRecord, converted: bool) {
	assert(take_expected(task) == 9)
	assert(converted && len(values) == 1 && values[0] == fixture.ArrayRecord{9, 0.5, 10})
	delete(values)
	record_calls += 1
}

check_records :: proc() {
	#assert(size_of(fixture.ArrayRecord) == 24 && align_of(fixture.ArrayRecord) == 8)
	#assert(offset_of(fixture.ArrayRecord, fraction) == 8)
	#assert(size_of(fixture.WideRecord) == 40)
	#assert(size_of(fixture.ArrayEmpty) == 0)
	state := Value_Allocator{backing = context.allocator, remaining = -1}
	context.allocator = mem.Allocator{procedure = value_allocator, data = &state}
	assert(fixture.direct_value({73}).value == 73)
	assert(fixture.DirectValue_init(73).value == 73)
	value := fixture.ArrayRecord{9, 0.5, 10}
	assert(fixture.echo_record(value) == value)
	changed := fixture.increment_record(value, 3)
	assert(changed == fixture.ArrayRecord{12, 0.75, 13})
	changed.first = 73
	assert(fixture.echo_record(changed).first == 73 && value.first == 9)
	wide := fixture.WideRecord{9, -73, 0.5, 10, 11}
	assert(fixture.echo_wide(wide) == wide)
	_ = fixture.echo_empty({})
	assert(state.allocations == 0)
	assert(fixture.optional_record(nil) == nil)
	optional := fixture.optional_record(value)
	assert(optional.(fixture.ArrayRecord) == value)
	result := fixture.echo_record_result(fixture.RecordResult_Record{value})
	assert(result.(fixture.RecordResult_Record).value == value)
	assert(state.allocations == 0)

	for count in ([]u64{0, 1, 2, 7, 8, 9, 16, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 1023, 1024, 1025, 1365, 1366, 16384}) {
		before := state.allocations
		values := fixture.make_records(count) or_else panic("Inline records")
		assert(state.allocations == before+(count == 0 ? 0 : 1))
		copy := fixture.Array_ArrayRecord_copy(values) or_else panic("Inline record copy")
		if count != 0 {
			assert(uintptr(&values[0]) == uintptr(raw_data(values)))
			values[0].first = 100
			assert(copy[0].first == 0)
		}
		echo := fixture.echo_records(values) or_else panic("Inline record round trip")
		assert(len(echo) == len(values))
		for item, index in echo { assert(item == values[index]) }
		changed := fixture.increment_records(values, 3) or_else panic("Swift record mutation")
		for item, index in changed {
			assert(item.first == values[index].first+3 && item.last == values[index].last+3)
			assert(item.fraction == values[index].fraction+0.25)
		}
		delete(changed)
		delete(echo)
		delete(copy)
		delete(values)
	}
	// Different record widths exercise short copies, partial blocks and large
	// outputs without relying on the byte size of ArrayRecord.
	for count in ([]int{1, 12, 13, 63, 64, 65, 819, 820, 4095, 4096, 4097}) {
		narrow := make([]fixture.DirectValue, count)
		wide_values := make([]fixture.WideRecord, count)
		for &item, index in narrow { item = {u64(index)} }
		for &item, index in wide_values { item = {u64(index), -73, 0.5, u64(index)+1, u64(index)+2} }
		narrow_copy := fixture.echo_direct_values(narrow) or_else panic("One-field record array")
		wide_copy := fixture.echo_wide_records(wide_values) or_else panic("Five-field record array")
		for item, index in narrow_copy { assert(item == narrow[index]) }
		for item, index in wide_copy { assert(item == wide_values[index]) }
		delete(wide_copy)
		delete(narrow_copy)
		delete(wide_values)
		delete(narrow)
	}
	{
		context.allocator = {}
		missing, ok := fixture.make_records(1)
		assert(!ok && missing == nil)
		empty, empty_ok := fixture.make_records(0)
		assert(empty_ok && empty == nil)
	}
	state.remaining = 0
	failed, ok := fixture.make_records(1)
	assert(!ok && failed == nil)
	assert(fixture.echo_record(value) == value)
	state.remaining = -1
	assert(state.allocations == state.frees)

	owned := fixture.make_owned_record("Café 📚 and dynamically copied storage") or_else panic("Owned frozen record")
	text := fixture.owned_record_text(owned) or_else panic("Owned record text")
	fixture.Array_OwnedRecord_destroy(owned)
	assert(text == "Café 📚 and dynamically copied storage")
	delete(text)
	hidden := fixture.make_hidden_record(73) or_else panic("Hidden layout")
	assert(fixture.hidden_record_sum(hidden) == 147)
	fixture.Array_HiddenRecord_destroy(hidden)
	assert(state.allocations == state.frees)

	task := fixture.echo_record_later(value, record_received) or_else panic("Async inline record")
	track_task(task, 9)
	task = fixture.echo_wide_later(wide, wide_received) or_else panic("Async indirect record")
	track_task(task, 9)
	input := []fixture.ArrayRecord{value}
	task = fixture.echo_records_later(input, records_received) or_else panic("Async inline slice")
	track_task(task, 9)
	input[0].first = 999
	value.first = 999
	wide.first = 999
	deadline := time.tick_now()
	for record_calls != 3 {
		assert(time.tick_since(deadline) < 5*time.Second)
		_ = cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
	}
	assert(state.allocations == state.frees)
}
