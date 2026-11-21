package swift_import_test

import "core:encoding/uuid"
import "core:mem"
import "core:time"
import "core:strings"
import "core:math"
import cf "core:sys/darwin/CoreFoundation"
import swift "core:sys/darwin/Swift"
foreign import fixture "swift:fixture/SwiftImportFixture"

set_calls: int
set_completed :: proc(task: swift.Task, count: u64) {
	assert(count == 2)
	assert(fixture.live_value_count() == 0)
	// Release the owned reference returned by the successful start.
	swift.task_release(task)
	set_calls += 1
}
empty_set_completed :: proc(task: swift.Task, count: u64) {
	assert(count == 0)
	swift.task_release(task)
	set_calls += 1
}

set_cancelled :: proc(task: swift.Task, _: u64, err: fixture.Call_Error) {
	assert(err != nil && swift.task_is_cancelled(task))
	fixture.Call_Error_destroy(err)
	assert(fixture.live_value_count() == 0)
	// Release the owned reference returned by the successful start.
	swift.task_release(task)
	set_calls += 1
}
wait_for_sets :: proc(expected: int) {
	begin := time.tick_now()
	for set_calls != expected {
		cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.001, false)
		assert(time.tick_since(begin) < 10*time.Second)
	}
}

check_sets :: proc() {
	state := Value_Allocator{backing = context.allocator, remaining = -1}
	context.allocator = mem.Allocator{procedure = value_allocator, data = &state}
	assert((fixture.set_count(nil) or_else panic("Empty Set")) == 0)
	assert(fixture.set_defaults() == 0)
	assert((fixture.set_defaults([]u64{7, 7, 9}) or_else panic("Explicit Set")) == 2)
	for count in ([]int{0, 1, 2, 8, 64, 1024}) {
		values := make([]u64, count)
		for &item, index in values { item = u64(index % 7) }
		assert((fixture.set_count(values) or_else panic("Set count")) == u64(min(count, 7)))
		unique := fixture.set_words(values) or_else panic("Set members")
		assert(len(unique) == min(count, 7))
		for item, index in unique { assert(item == u64(index)) }
		for item, index in values { assert(item == u64(index % 7)) }
		delete(unique)
		delete(values)
	}
	// Randomized values and all-equal input exercise collisions/probing across
	// allocation boundaries. Swift compares membership, then grows/removes.
	for count in ([]int{1, 2, 3, 7, 8, 31, 32, 47, 48, 63, 64, 95, 96, 127, 128, 1024}) {
		values := make([]u64, count)
		for distribution in 0..<3 {
			state: u64 = 12345
			for &value in values {
				state = state*6364136223846793005 + 1442695040888963407
				value = distribution == 0 ? state : distribution == 1 ? state%17 : 42
			}
			assert(fixture.set_check_words(values, values) or_else panic("Swift Set membership/growth"))
		}
		delete(values)
	}
	ints := fixture.set_ints([]int{max(int), min(int), 0, min(int)}) or_else panic("Int Set")
	assert(len(ints) == 3 && ints[0] == min(int) && ints[1] == 0 && ints[2] == max(int))
	delete(ints)
	uints := fixture.set_uints([]uint{max(uint), 0, max(uint)}) or_else panic("UInt Set")
	assert(len(uints) == 2 && uints[0] == 0 && uints[1] == max(uint))
	delete(uints)
	int64s := fixture.set_int64s([]i64{max(i64), min(i64), 0, min(i64)}) or_else panic("Int64 Set")
	assert(len(int64s) == 3 && int64s[0] == min(i64) && int64s[1] == 0 && int64s[2] == max(i64))
	delete(int64s)
	// Swift keeps the first equal value (-0 here), but NaNs are unequal to
	// themselves and must remain separate members. Preserve all payload bits.
	negative_zero := transmute(f64)u64(0x8000000000000000)
	nan := transmute(f64)u64(0x7ff8000000000042)
	bits := fixture.set_double_bits([]f64{negative_zero, 0, math.INF_F64, math.INF_F64, nan, nan}) or_else panic("IEEE Double Set")
	assert(len(bits) == 4 && bits[0] == 0x7ff0000000000000 && bits[1] == 0x7ff8000000000042 && bits[2] == bits[1] && bits[3] == 0x8000000000000000)
	delete(bits)
	// Swift's canonically equivalent Strings compare equal despite different UTF-8.
	assert((fixture.set_text_count([]string{"é", "e\u0301", "other", "other"}) or_else panic("String Set")) == 2)
	assert((fixture.set_modes([]fixture.Mode{.Idle, .Running, .Idle}) or_else panic("Enum Set")) == 2)
	assert((fixture.set_text_cases([]fixture.SetText{fixture.SetText_Name{"same"}, fixture.SetText_Name{"same"}, fixture.SetText_Empty{}}) or_else panic("Union Set")) == 2)
	assert((fixture.set_doubles([]f64{0, -0.0, 1.5, 1.5}) or_else panic("Double Set")) == 2)
	assert((fixture.set_int_first([]int{min(int)}) or_else panic("Int singleton")) == min(int))
	assert((fixture.set_uint_first([]uint{max(uint)}) or_else panic("UInt singleton")) == max(uint))
	assert((fixture.set_int64_first([]i64{min(i64)}) or_else panic("Int64 singleton")) == min(i64))
	assert((fixture.set_double_first([]f64{-1.5}) or_else panic("Double singleton")) == -1.5)
	id := uuid.Identifier{15 = 42}
	assert((fixture.set_identifier_count([]uuid.Identifier{id, id, {}}) or_else panic("UUID Set")) == 2)
	records := []fixture.SetRecord{{7, 1}, {7, 2}, {9, 1}}
	keys := fixture.set_record_keys(records) or_else panic("Custom Hashable Set")
	assert(len(keys) == 2 && keys[0] == 7 && keys[1] == 9)
	assert(records[0].ignored == 1 && records[1].ignored == 2)
	delete(keys)
	assert((fixture.set_record_first(records[:2]) or_else panic("First equal member")) == 1)
	for mode in 0..<2 {
		assert(fixture.live_value_count() == 0)
		values := make([]fixture.SetTracked, 3)
		for &item, i in values { item = fixture.SetTracked_init(u64(i%2)) or_else panic("Owned Set element") }
		assert(fixture.live_value_count() == 3)
		assert((fixture.set_tracked_count(values) or_else panic("Owned Set")) == 2)
		assert(fixture.live_value_count() == 3)
		owner := fixture.SetOwner_init(values) or_else panic("Set owner initializer")
		assert(fixture.SetOwner_count(owner) == 2)
		fixture.SetOwner_destroy(owner)
		assert(fixture.live_value_count() == 3)
		_, converted := fixture.set_tracked_count([]fixture.SetTracked{values[0], nil})
		assert(!converted && fixture.live_value_count() == 3)
		_, converted = fixture.set_then_outcome(values, nil)
		assert(!converted && fixture.live_value_count() == 3)
		_, converted = fixture.set_then_outcome_later(values, nil, set_completed)
		assert(!converted && fixture.live_value_count() == 3)
		callback: proc(swift.Task, u64)
		failed, started := fixture.set_tracked_later(values, callback)
		assert(!started && failed == nil && fixture.live_value_count() == 3)
		task: swift.Task
		if mode == 1 {
			task = fixture.set_tracked_cancelled(values, set_cancelled) or_else panic("Cancellable Set")

		} else {
			task = fixture.set_tracked_later(values, set_completed) or_else panic("Async Set")
		}
		for &item in values { fixture.SetTracked_destroy(item); item = nil }
		delete(values)
		if mode == 1 { swift.task_cancel(task) }
		wait_for_sets(mode+1)
		assert(fixture.live_value_count() == 0)
	}
	text := strings.clone("long text copied into Swift before the async call returns")
	inputs := []string{text, text, "other"}
	_ = fixture.set_text_later(inputs, set_completed) or_else panic("Async string Set")
	delete(text)
	for &item in inputs { item = "changed" }
	wait_for_sets(3)
	words := make([]u64, 1024)
	for &word, i in words { word = u64(i%2) }
	_ = fixture.set_words_later(words, set_completed) or_else panic("Async scalar Set")
	delete(words)
	wait_for_sets(4)
	_ = fixture.set_defaults_later(empty_set_completed) or_else panic("Default Set")
	_ = fixture.set_defaults_later(nil, empty_set_completed) or_else panic("Empty Set")
	_ = fixture.set_defaults_later([]u64{7, 7, 9}, set_completed) or_else panic("Explicit Set")
	wait_for_sets(7)
	assert(state.allocations == state.frees)
}
