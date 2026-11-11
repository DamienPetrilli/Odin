package swift_import_test

import "core:mem"
import "core:strings"
import "core:time"
import cf "core:sys/darwin/CoreFoundation"
import swift "core:sys/darwin/Swift"
foreign import fixture "swift:fixture/SwiftImportFixture"

string_calls: int
collection_calls: int
actor_calls: int

COLLECTION_TEXT :: "A longer UTF-8 string: 日本語, café, and 🦉\x00tail"

string_counted :: proc(expected, count: u64) {
	assert(count == expected && pthread_main_np() == 1)
	string_calls += 1
}

string_received :: proc(id: swift.Request_Id) {
	assert(id != 0 && pthread_main_np() == 1)
	string_calls += 1
}

check_strings :: proc() {
	state := Value_Allocator{backing = context.allocator, remaining = -1}
	context.allocator = mem.Allocator{procedure = value_allocator, data = &state}
	samples := []string{
		"", "hello", "a\x00b", "é", "e\u0301", "日本語 🦉",
		"A string longer than Swift's inline storage: café, books, and 🦉",
	}
	for sample in samples {
		expected := strings.concatenate({"[", sample, "]"})
		result := fixture.decorate(sample) or_else panic("String conversion")
		assert(result == expected && len(result) == len(sample)+2)
		delete(result)
		delete(expected)
		count := fixture.utf8_count(sample) or_else panic("String argument")
		assert(count == u64(len(sample)))
		value := fixture.TextValue_init(sample) or_else panic("String field")
		result = fixture.TextValue_text(value) or_else panic("String getter")
		fixture.TextValue_destroy(value)
		assert(result == sample)
		delete(result)
		outcome := fixture.text_outcome(sample) or_else panic("String enum")
		result = fixture.TextOutcome_get_text(outcome) or_else panic("String payload")
		fixture.TextOutcome_destroy(outcome)
		assert(result == sample)
		delete(result)

		// The caller may overwrite and free its UTF-8 immediately after start.
		// The Swift task must own independent text through suspension.
		input := strings.clone(sample)
		id, ok := fixture.utf8_count_later(input, u64(len(sample)), string_counted)
		assert(ok && id == u64(len(sample)))
		if len(input) != 0 { mem.set(raw_data(input), 0xff, len(input)) }
		delete(input)
	}
	assert(fixture.receive_text("hello"))
	_, started := fixture.receive_text_later("hello", string_received)
	assert(started)
	for invalid in ([]string{"\xff", "\xc0\x80", "\xed\xa0\x80", "\xf0\x9f"}) {
		text, ok := fixture.decorate(invalid)
		assert(!ok && len(text) == 0)
		assert(!fixture.receive_text(invalid))
		bad_id, bad_started := fixture.utf8_count_later(invalid, u64(99), string_counted)
		assert(!bad_started && bad_id == 0)
	}
	state.remaining = 0
	text, ok := fixture.decorate("allocation failure")
	assert(!ok && len(text) == 0)
	state.remaining = -1
	begin := time.tick_now()
	for string_calls != len(samples)+1 {
		cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
		assert(time.tick_since(begin) < 10*time.Second)
	}
	assert(state.allocations == state.frees)
	check_collections()
}

texts_received :: proc(expected: u64, values: fixture.Array_TextValue, error: swift.Error) {
	defer swift.error_release(error)
	if expected == 0 {
		assert(values == nil && error != nil)
	} else {
		assert(error == nil && fixture.Array_TextValue_count(values) == 1)
		value := fixture.Array_TextValue_get(values, 0) or_else panic("Array element")
		fixture.Array_TextValue_destroy(values)
		text := fixture.TextValue_text(value) or_else panic("Array element text")
		fixture.TextValue_destroy(value)
		assert(text == COLLECTION_TEXT)
		delete(text)
	}
	collection_calls += 1
}

echo_received :: proc(id: swift.Request_Id, values: fixture.Array_String) {
	assert(id != 0 && fixture.Array_String_count(values) == 1)
	text := fixture.Array_String_get(values, 0) or_else panic("String array element")
	fixture.Array_String_destroy(values)
	assert(text == COLLECTION_TEXT)
	delete(text)
	collection_calls += 1
}

accepted_text :: proc(expected: u64, outcome: fixture.ValueOutcome, error: swift.Error) {
	assert(pthread_main_np() == 1)
	defer swift.error_release(error)
	if expected == 0 {
		assert(outcome == nil && error != nil)
	} else {
		assert(error == nil)
		value := fixture.ValueOutcome_get_accepted(outcome) or_else panic("Main actor result")
		fixture.ValueOutcome_destroy(outcome)
		assert(fixture.Value_value(value) == expected)
		fixture.Value_destroy(value)
	}
	actor_calls += 1
}

isolated_finished :: proc(id: swift.Request_Id, result: u64) {
	assert(id != 0 && result == 1 && pthread_main_np() == 1)
	actor_calls += 1
}

check_collections :: proc() {
	state := Value_Allocator{backing = context.allocator, remaining = -1}
	context.allocator = mem.Allocator{procedure = value_allocator, data = &state}
	inputs := []string{"", "hello", COLLECTION_TEXT}
	values := fixture.echo_texts(inputs) or_else panic("Array input")
	assert(fixture.Array_String_count(values) == len(inputs))
	for expected, i in inputs {
		text := fixture.Array_String_get(values, i) or_else panic("Array element")
		assert(text == expected)
		delete(text)
	}
	for index in ([2]int{-1, len(inputs)}) {
		text, found := fixture.Array_String_get(values, index)
		assert(!found && len(text) == 0)
	}
	fixture.Array_String_destroy(values)
	for remaining in 0..<3 {
		state.remaining = remaining
		failed, ok := fixture.echo_texts(inputs)
		assert(!ok && failed == nil && state.allocations == state.frees)
	}
	state.remaining = -1
	invalid, valid := fixture.echo_texts([]string{COLLECTION_TEXT, "\xff"})
	assert(!valid && invalid == nil && state.allocations == state.frees)
	input := strings.clone(COLLECTION_TEXT)
	names := []string{input}
	_, ok := fixture.TextValue_lookup(names, u64(1), texts_received)
	assert(ok)
	_, ok = fixture.echo_texts_later(names, echo_received)
	assert(ok)
	mem.set(raw_data(input), 0xff, len(input))
	delete(input)
	names[0] = "overwritten"
	_, ok = fixture.TextValue_lookup(nil, u64(0), texts_received)
	assert(ok)
	for text in ([]string{"", COLLECTION_TEXT}) {
		value := fixture.TextValue_init(text) or_else panic("Text initialization")
		_, ok = fixture.TextValue_accept(value, u64(len(text)), accepted_text)
		assert(ok)
		fixture.TextValue_destroy(value)
	}
	_, ok = fixture.isolated(isolated_finished)
	assert(ok)
	begin := time.tick_now()
	for collection_calls != 3 || actor_calls != 3 {
		cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
		assert(time.tick_since(begin) < 10*time.Second)
	}
	assert(fixture.live_value_count() == 0 && state.allocations == state.frees)
}
