package swift_import_test

import "core:mem"
import "core:strings"
import "core:time"
import cf "core:sys/darwin/CoreFoundation"
import swift "core:sys/darwin/Swift"
foreign import fixture "swift:fixture/SwiftImportFixture"

projection_calls: int

lookup_received :: proc(task: swift.Task, result: fixture.Lookup, ok: bool) {
	expected := take_expected(task)
	assert(ok == (expected != 0))
	if ok {
		defer fixture.Lookup_destroy(result)
		item := result.(fixture.Lookup_Rejected)
		assert(item.code == 7 && item.message == "Owned UTF-8 across suspension: Café 📚")
	}
	projection_calls += 1
}

page_received :: proc(task: swift.Task, result: Maybe(u64)) {
	expected := take_expected(task)
	if expected == 0 {
		assert(result == nil)
	} else {
		value, present := result.?
		assert(present && value == expected)
	}
	projection_calls += 1
}

payloads_received :: proc(task: swift.Task, result: fixture.Payloads, ok: bool) {
	expected := take_expected(task)
	assert(ok == (expected != 0))
	if ok {
		defer fixture.Payloads_destroy(result)
		item := result.(fixture.Payloads_Pair)
		assert(fixture.Value_value(item.value_0) == 17 && fixture.Value_value(item.value_1) == 29)
	}
	projection_calls += 1
}

wait_projections :: proc(count: int) {
	begin := time.tick_now()
	for projection_calls != count {
		cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
		assert(time.tick_since(begin) < 10*time.Second)
	}
}

check_projected_enums :: proc() {
	state := Value_Allocator{backing = context.allocator, remaining = -1}
	context.allocator = mem.Allocator{procedure = value_allocator, data = &state}
	assert(fixture.live_value_count() == 0)
	assert(fixture.Namespace_answer() == 42)

	// Trivial optional conversion must not allocate, including nested nil.
	state.remaining = 0
	for input in ([]u64{0, 41, max(u64)}) {
		page: Maybe(u64) = input
		value, present := fixture.next_page(page).?
		assert(present && value == input+1)
	}
	assert(fixture.next_page(nil) == nil)
	assert(fixture.optional_double(f64(1.25)).(f64) == 1.75)
	assert(fixture.optional_double(nil) == nil)
	inner_none: Maybe(u64)
	outer_none: Maybe(Maybe(u64))
	some_none: Maybe(Maybe(u64)) = inner_none
	assert(fixture.nested_optional(outer_none) == nil)
	inner, present := fixture.nested_optional(some_none).?
	assert(present && inner == nil)
	inner_some: Maybe(u64) = u64(73)
	some_some: Maybe(Maybe(u64)) = inner_some
	inner, present = fixture.nested_optional(some_some).?
	assert(present && inner.(u64) == 73)
	assert(state.allocations == 0)
	state.remaining = -1

	for sample in ([]string{"", "Café 📚", "embedded\x00zero"}) {
		input: Maybe(string) = sample
		result := fixture.optional_text(input) or_else panic("Optional text")
		text, found := result.?
		assert(found && text == sample)
		delete(text)
	}
	none := fixture.optional_text(nil) or_else panic("Absent text")
	assert(none == nil)
	words: Maybe([]u64) = []u64{17, 29}
	returned := fixture.optional_words(words) or_else panic("Optional array")
	values, found := returned.?
	assert(found && len(values) == 2 && values[0] == 17 && values[1] == 29)
	delete(values)

	for input, index in ([]fixture.Lookup{fixture.Lookup_Found{42}, fixture.Lookup_Other{42}, fixture.Lookup_Missing{}}) {
		result := fixture.echo_lookup(input) or_else panic("Case identity")
		switch item in result {
		case fixture.Lookup_Found:
			assert(index == 0 && item.value == 42)
		case fixture.Lookup_Other:
			assert(index == 1 && item.value == 42)
		case fixture.Lookup_Missing:
			assert(index == 2)
		case fixture.Lookup_Rejected:
			panic("Unexpected payload")
		}
		fixture.Lookup_destroy(result)
	}
	input: fixture.Lookup = fixture.Lookup_Rejected{7, "Owned UTF-8 across suspension: Café 📚"}
	result := fixture.echo_lookup(input) or_else panic("Named fields")
	kept := fixture.Lookup_copy(result) or_else panic("Explicit ownership")
	fixture.Lookup_destroy(result)
	item := kept.(fixture.Lookup_Rejected)
	assert(item.code == 7 && item.message == input.(fixture.Lookup_Rejected).message)
	fixture.Lookup_destroy(kept)
	state.remaining = 0
	_, converted := fixture.echo_lookup(input)
	assert(!converted && state.allocations == state.frees)
	state.remaining = -1

	left := fixture.Value_init(17) or_else panic("Left value")
	right := fixture.Value_init(29) or_else panic("Right value")
	pair: fixture.Payloads = fixture.Payloads_Pair{left, right}
	for remaining in 0..<3 {
		state.remaining = remaining
		_, copied := fixture.echo_payloads(pair)
		assert(!copied && fixture.live_value_count() == 2)
		assert(state.allocations-state.frees == 2)
	}
	state.remaining = -1
	owned := fixture.echo_payloads(pair) or_else panic("Multiple fields")
	for remaining in 0..<2 {
		state.remaining = remaining
		_, copied := fixture.Payloads_copy(owned)
		assert(!copied && fixture.live_value_count() == 2)
		assert(state.allocations-state.frees == 4)
	}
	state.remaining = -1
	fixture.Payloads_destroy(owned)
	verification := fixture.verification(left) or_else panic("Nested generic error")
	unverified := verification.(fixture.Verification_Value_Unverified)
	failure := unverified.value_1.(fixture.Verification_Value_Failure_Blocked)
	assert(fixture.Value_value(unverified.value_0) == 17 && failure.code == 7 && failure.message == "Verification failed")
	fixture.Verification_Value_destroy(verification)

	// A string-array payload owns every string and its slice. Exercise partial
	// copy and conversion failures, not only the successful recursive cleanup.
	texts: fixture.Payloads = fixture.Payloads_Texts{[]string{"Café 📚", "second owned payload"}}
	owned_texts := fixture.echo_payloads(texts) or_else panic("Array payload")
	for remaining in 0..<3 {
		state.remaining = remaining
		_, copied := fixture.Payloads_copy(owned_texts)
		assert(!copied)
	}
	state.remaining = -1
	copied_texts := fixture.Payloads_copy(owned_texts) or_else panic("Array payload copy")
	fixture.Payloads_destroy(owned_texts)
	assert(copied_texts.(fixture.Payloads_Texts).value[1] == "second owned payload")
	fixture.Payloads_destroy(copied_texts)
	for remaining in 0..<4 {
		state.remaining = remaining
		_, copied := fixture.echo_payloads(texts)
		assert(!copied)
	}
	state.remaining = -1
	assert(state.allocations-state.frees == 2)

	// A later invalid input must release native fields constructed before it.
	invalid: fixture.Payloads = fixture.Payloads_Pair{left, nil}
	_, copied := fixture.echo_payloads(invalid)
	assert(!copied && fixture.live_value_count() == 2)
	assert(state.allocations-state.frees == 2)
	rejected, started := fixture.payloads_later(pair, nil)
	assert(!started && rejected == nil)
	assert(fixture.live_value_count() == 2 && state.allocations-state.frees == 2)

	// Async input text is independent of caller storage before start returns.
	text := strings.clone(input.(fixture.Lookup_Rejected).message)
	async_input: fixture.Lookup = fixture.Lookup_Rejected{7, text}
	task := fixture.lookup_later(async_input, lookup_received) or_else panic("Async enum")
	track_task(task, 1)
	mem.set(raw_data(text), 0xff, len(text))
	delete(text)
	task = fixture.page_later(u64(41), page_received) or_else panic("Async optional")
	track_task(task, 42)
	task = fixture.page_later(nil, page_received) or_else panic("Async absent")
	track_task(task)
	task = fixture.payloads_later(pair, payloads_received) or_else panic("Async payloads")
	track_task(task, 1)
	fixture.Value_destroy(left)
	fixture.Value_destroy(right)
	wait_projections(4)
	assert(fixture.live_value_count() == 0 && state.allocations == state.frees)

	// Start succeeds; allocating the owned result at completion fails.
	task = fixture.lookup_later(input, lookup_received) or_else panic("Conversion failure start")
	track_task(task)
	state.remaining = 0
	wait_projections(5)
	state.remaining = -1
	assert(fixture.live_value_count() == 0 && state.allocations == state.frees)
}
