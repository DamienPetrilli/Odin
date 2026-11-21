package swift_import_test

import "base:runtime"
import "core:mem"
import "core:time"
import cf "core:sys/darwin/CoreFoundation"
import swift "core:sys/darwin/Swift"
foreign import fixture "swift:fixture/SwiftImportFixture"

value_array_calls: int

value_array_received :: proc(task: swift.Task, values: []fixture.Value, error: fixture.Call_Error) {
	expected := take_expected(task)
	defer fixture.Call_Error_destroy(error)
	if expected == 0 {
		assert(error != nil && values == nil)
	} else if expected == 1 {
		_, failed := error.(swift.Result_Conversion_Failed)
		assert(failed && values == nil)
	} else {
		assert(error == nil && len(values) == 3)
		for value, index in values { assert(fixture.Value_value(value) == expected+u64(index)) }
		fixture.Array_Value_destroy(values)
	}
	value_array_calls += 1
}

lookup_array_received :: proc(task: swift.Task, values: []fixture.Lookup, converted: bool) {
	_ = take_expected(task)
	assert(converted && len(values) == 3)
	assert(values[2].(fixture.Lookup_Rejected).message == "Café 📚 and an owned array payload")
	fixture.Array_Lookup_destroy(values)
	value_array_calls += 1
}

value_array_destroy_worker :: proc "c" (data: rawptr) -> rawptr {
	context = runtime.default_context()
	fixture.Value_destroy((cast(^fixture.Value)data)^)
	return nil
}

check_value_arrays :: proc() {
	state := Value_Allocator{backing = context.allocator, remaining = -1}
	context.allocator = mem.Allocator{procedure = value_allocator, data = &state}
	assert(fixture.live_value_count() == 0)
	for count in ([]u64{0, 1, 3, 65}) {
		values := fixture.make_values(count) or_else panic("Imported array")
		assert(len(values) == int(count))
		assert(state.allocations-state.frees == (count == 0 ? 0 : 2))
		copy := fixture.Array_Value_copy(values) or_else panic("Independent array")
		changed := fixture.increment_values(values, 9) or_else panic("Mutation round trip")
		fixture.Array_Value_destroy(values)
		for value, index in changed { assert(fixture.Value_value(value) == 26+u64(index)) }
		for value, index in copy { assert(fixture.Value_value(value) == 17+u64(index)) }
		fixture.Array_Value_destroy(changed)
		fixture.Array_Value_destroy(copy)
		assert(fixture.live_value_count() == 0 && state.allocations == state.frees)
	}
	// The input array temporarily retains the value. Its last use is the
	// Swift call. The Odin output allocator should see the sole owner again.
	item := fixture.Value_init(17) or_else panic("Input lifetime")
	assert(fixture.Value_unique_lifetime(item))
	_, valid_label := fixture.summarize_values([]fixture.Value{item}, "\xff")
	assert(!valid_label && fixture.Value_unique_lifetime(item))
	state.unique_input = item
	counts := fixture.summarize_values([]fixture.Value{item}, "count") or_else panic("Counts")
	assert(len(counts) == 1 && fixture.Value_value(counts[0]) == 1)
	fixture.Array_Value_destroy(counts)
	state.remaining = 0
	failed_counts, counts_ok := fixture.summarize_values([]fixture.Value{item}, "count")
	assert(!counts_ok && failed_counts == nil)
	state.remaining = -1
	state.unique_input = nil
	fixture.Value_destroy(item)
	assert(fixture.live_value_count() == 0 && state.allocations == state.frees)

	// Single-element output keeps a standalone owner after deleting its slice.
	single := fixture.make_values(1) or_else panic("Single owner")
	single_value := single[0]
	delete(single)
	{
		context.allocator = mem.panic_allocator()
		fixture.Value_increment(single_value, 5)
		assert(fixture.Value_value(single_value) == 22)
		fixture.Value_destroy(single_value)
	}
	assert(fixture.live_value_count() == 0 && state.allocations == state.frees)
	for remaining in 0..<2 {
		state.remaining = remaining
		failed, ok := fixture.make_values(1)
		assert(!ok && failed == nil)
		assert(fixture.live_value_count() == 0 && state.allocations == state.frees)
	}
	state.remaining = -1
	{
		context.allocator = {}
		missing, ok := fixture.make_values(1)
		assert(!ok && missing == nil && fixture.live_value_count() == 0)
	}
	// An owned return may share its native array with Swift. Never take those
	// elements or change the source count, even when output allocation fails.
	fixture.prepare_shared_values(3)
	shared_output := fixture.get_shared_values() or_else panic("Shared native result")
	fixture.Value_increment(shared_output[0], 100)
	assert(fixture.Value_value(shared_output[0]) == 117)
	assert(fixture.shared_values_sum() == 54)
	fixture.Array_Value_destroy(shared_output)
	assert(fixture.live_value_count() == 3)
	for remaining in 0..<2 {
		state.remaining = remaining
		failed, ok := fixture.get_shared_values()
		assert(!ok && failed == nil && fixture.shared_values_sum() == 54)
		assert(fixture.live_value_count() == 3 && state.allocations == state.frees)
	}
	state.remaining = -1
	fixture.clear_shared_values()
	assert(fixture.live_value_count() == 0)

	weak := fixture.make_weak_values(3) or_else panic("Native weak take")
	assert(fixture.live_value_count() == 1)
	for value in weak { assert(fixture.WeakValue_alive(value) == 1) }
	fixture.clear_weak_lifetime()
	assert(fixture.live_value_count() == 0)
	for value in weak { assert(fixture.WeakValue_alive(value) == 0) }
	fixture.Array_WeakValue_destroy(weak)
	assert(state.allocations == state.frees)

	// A retained element is independent of the output slice and native array.
	values := fixture.make_values(3) or_else panic("Owned elements")
	kept := fixture.Value_copy(values[1]) or_else panic("Keep element")
	fixture.Array_Value_destroy(values)
	assert(fixture.Value_value(kept) == 18)
	fixture.Value_destroy(kept)
	// Moving one element out does not keep the Odin slice allocation alive.
	values = fixture.make_values(3) or_else panic("Moved element source")
	kept = values[2]
	values[2] = nil
	fixture.Array_Value_destroy(values)
	assert(fixture.Value_value(kept) == 19 && fixture.live_value_count() == 1)
	{
		context.allocator = mem.panic_allocator()
		fixture.Value_destroy(kept)
	}
	assert(state.allocations == state.frees)
	// Reorder slots from two batches and one standalone copy before destruction.
	a := fixture.make_values(3) or_else panic("First batch")
	b := fixture.make_values(2) or_else panic("Second batch")
	one := fixture.Value_copy(a[0]) or_else panic("Standalone copy")
	mixed := make([]fixture.Value, 7)
	mixed[0], mixed[1], mixed[2], mixed[3] = a[0], b[0], one, a[1]
	mixed[4], mixed[5], mixed[6] = nil, b[1], a[2]
	delete(a)
	delete(b)
	fixture.Array_Value_destroy(mixed)
	assert(fixture.live_value_count() == 0 && state.allocations == state.frees)
	// Fail each output/copy allocation; partial elements and native arrays die.
	for remaining in 0..<2 {
		state.remaining = remaining
		failed, ok := fixture.make_values(3)
		assert(!ok && failed == nil)
		assert(fixture.live_value_count() == 0 && state.allocations == state.frees)
	}
	state.remaining = -1
	values = fixture.make_values(3) or_else panic("Copy source")
	outstanding := state.allocations-state.frees
	for remaining in 0..<2 {
		state.remaining = remaining
		failed, ok := fixture.Array_Value_copy(values)
		assert(!ok && failed == nil)
		assert(fixture.live_value_count() == 3 && state.allocations-state.frees == outstanding)
	}
	state.remaining = -1
	// Invalid later input rolls back the native initialized prefix.
	invalid := []fixture.Value{values[0], nil, values[2]}
	state.remaining = 0
	total := fixture.sum_values(values) or_else panic("No temporary Odin allocation")
	assert(total == 54)
	_, converted := fixture.sum_values(invalid)
	assert(!converted && fixture.live_value_count() == 3)
	fixture.Array_Value_destroy(values)
	state.remaining = -1
	assert(fixture.live_value_count() == 0 && state.allocations == state.frees)

	for count in ([]u64{0, 1, 8, 65}) {
		records := fixture.make_records(count) or_else panic("Frozen records")
		echo := fixture.echo_records(records) or_else panic("Frozen round trip")
		fixture.Array_ArrayRecord_destroy(records)
		sum := fixture.sum_records(echo) or_else panic("Frozen stride")
		assert(sum == count*(count+1))
		grown := fixture.append_records(echo, count) or_else panic("Imported array growth")
		assert(len(grown) == int(2*count) && fixture.sum_records(grown) == 2*count*(count+1))
		fixture.Array_ArrayRecord_destroy(grown)
		fixture.Array_ArrayRecord_destroy(echo)
		empty := fixture.empty_records(count) or_else panic("Zero-sized values")
		assert(len(empty) == int(count))
		n := fixture.count_empty_records(empty) or_else panic("Zero-sized stride")
		assert(n == count)
		fixture.Array_ArrayEmpty_destroy(empty)
		aligned := fixture.make_aligned(count) or_else panic("Aligned values")
		assert(len(aligned) == int(count) && fixture.sum_aligned(aligned) == count*count)
		for value in aligned { assert(uintptr(value)%16 == 0) }
		fixture.Array_ArrayAligned_destroy(aligned)
	}
	input := []fixture.Lookup{fixture.Lookup_Found{42}, fixture.Lookup_Missing{}, fixture.Lookup_Rejected{7, "Café 📚 and an owned array payload"}}
	lookups := fixture.echo_lookups(input) or_else panic("Union array")
	cloned := fixture.Array_Lookup_copy(lookups) or_else panic("Union array copy")
	fixture.Array_Lookup_destroy(lookups)
	assert(cloned[0].(fixture.Lookup_Found).value == 42)
	assert(cloned[2].(fixture.Lookup_Rejected).message == input[2].(fixture.Lookup_Rejected).message)
	fixture.Array_Lookup_destroy(cloned)
	for remaining in 0..<2 {
		state.remaining = remaining
		failed, ok := fixture.echo_lookups(input)
		assert(!ok && failed == nil && state.allocations == state.frees)
	}
	state.remaining = -1
	bad_input := []fixture.Lookup{input[2], fixture.Lookup_Rejected{11, "\xff"}}
	bad_output, bad_ok := fixture.echo_lookups(bad_input)
	assert(!bad_ok && bad_output == nil && state.allocations == state.frees)
	value := fixture.Value_init(73) or_else panic("Optional element")
	optionals := fixture.echo_optional_values([]Maybe(fixture.Value){nil, value, nil}) or_else panic("Optional array")
	fixture.Value_destroy(value)
	assert(optionals[0] == nil && optionals[2] == nil)
	assert(fixture.Value_value(optionals[1].(fixture.Value)) == 73)
	fixture.Array_Optional_Value_destroy(optionals)
	outcomes := fixture.future_outcomes() or_else panic("Resilient enum array")
	echo := fixture.echo_outcomes(outcomes) or_else panic("Future array round trip")
	fixture.Array_ValueOutcome_destroy(outcomes)
	when #config(EVOLVED_VALUE_ENUM, false) {
		_, unknown := echo[0].(fixture.ValueOutcome_Unknown)
		assert(unknown && fixture.read_outcome(echo[0]) == 33)
	}
	fixture.Array_ValueOutcome_destroy(echo)
	values = fixture.make_values(3) or_else panic("Nested array")
	batch := fixture.echo_batch(fixture.ValueBatch_Values{values}) or_else panic("Array in enum")
	fixture.Array_Value_destroy(values)
	batch_copy := fixture.ValueBatch_copy(batch) or_else panic("Array payload copy")
	fixture.ValueBatch_destroy(batch)
	fixture.ValueBatch_destroy(batch_copy)
	assert(fixture.live_value_count() == 0 && state.allocations == state.frees)

	for amount in ([]u64{0, 9}) {
		values = fixture.make_values(3) or_else panic("Async input")
		task := fixture.increment_values_later(values, amount, value_array_received) or_else panic("Async array start")
		track_task(task, amount == 0 ? 0 : 26)
		fixture.Value_increment(values[0], 100)
		fixture.Array_Value_destroy(values)
	}
	deadline := time.tick_now()
	for value_array_calls != 2 {
		assert(time.tick_since(deadline) < 5*time.Second)
		_ = cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
	}
	values = fixture.make_values(3) or_else panic("Failed completion input")
	task := fixture.increment_values_later(values, 9, value_array_received) or_else panic("Failed completion start")
	track_task(task, 1)
	fixture.Array_Value_destroy(values)
	state.remaining = 0
	for value_array_calls != 3 {
		assert(time.tick_since(deadline) < 5*time.Second)
		_ = cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
	}
	state.remaining = -1
	owned_input := fixture.Array_Lookup_copy(input) or_else panic("Owned async enum input")
	task = fixture.echo_lookups_later(owned_input, lookup_array_received) or_else panic("Async enum array")
	track_task(task)
	fixture.Array_Lookup_destroy(owned_input)
	for value_array_calls != 4 {
		assert(time.tick_since(deadline) < 5*time.Second)
		_ = cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
	}
	assert(fixture.live_value_count() == 0 && state.allocations == state.frees)
	{
		context.allocator = state.backing
		shared := fixture.make_values(8) or_else panic("Concurrent destruction")
		workers: [8]rawptr
		for &worker, index in workers { assert(pthread_create(&worker, nil, value_array_destroy_worker, &shared[index]) == 0) }
		for worker in workers { assert(pthread_join(worker, nil) == 0) }
		delete(shared)
	}
	assert(fixture.live_value_count() == 0)
}
