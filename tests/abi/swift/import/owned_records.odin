package swift_import_test

foreign import fixture "swift:fixture/SwiftImportFixture"
import swift "core:sys/darwin/Swift"
import cf "core:sys/darwin/CoreFoundation"
import "core:strings"
import "core:time"

Text_Record_Request :: struct {
	expected: string,
	calls: int,
}
text_record_received :: proc(task: swift.Task, value: fixture.TextRecord, converted: bool) {
	request := cast(^Text_Record_Request)context.user_ptr
	swift.task_release(task)
	assert(converted && value.title == request.expected && value.count == 73 && value.flag)
	defer fixture.TextRecord_destroy(value)
	request.calls += 1
}
wide_text_record_received :: proc(task: swift.Task, value: fixture.WideTextRecord, converted: bool) {
	request := cast(^Text_Record_Request)context.user_ptr
	swift.task_release(task)
	assert(converted && value.title == request.expected && value.subtitle == "second" && value.count == 73 && value.flag)
	defer fixture.WideTextRecord_destroy(value)
	request.calls += 1
}

check_owned_records :: proc() {
	state := Value_Allocator{backing = context.allocator, remaining = -1}
	context.allocator = {procedure = value_allocator, data = &state}
	for text in ([]string{"", "small", "Café 📚 with heap-allocated UTF-8", "before\x00after"}) {
		input := fixture.TextRecord{title = text, count = -73, flag = true}
		adjusted := fixture.TextRecord_adjusted(input, 9) or_else panic("Owned record member")
		assert(adjusted.count == -64 && adjusted.title == text && input.count == -73)
		fixture.TextRecord_destroy(adjusted)
		value := fixture.echo_text_record(input) or_else panic("Owned record")
		assert(value.title == text && value.count == -73 && value.flag)
		copy := fixture.TextRecord_copy(value) or_else panic("Owned record copy")
		fixture.TextRecord_destroy(value)
		assert(copy.title == text)
		changed := fixture.change_text_record(copy) or_else panic("Owned record mutation")
		assert(strings.has_prefix(changed.title, text) && len(changed.title) == len(text)+1)
		assert(changed.count == -72 && !changed.flag && copy.title == text)
		fixture.TextRecord_destroy(changed)
		fixture.TextRecord_destroy(copy)
		wide := fixture.WideTextRecord{true, text, "second", 73}
		wide_copy := fixture.echo_wide_text_record(wide) or_else panic("Indirect owned record")
		assert(wide_copy.title == text && wide_copy.subtitle == "second" && wide_copy.flag && wide_copy.count == 73)
		fixture.WideTextRecord_destroy(wide_copy)
		optional := fixture.optional_text_record(input) or_else panic("Optional owned record")
		assert(optional.(fixture.TextRecord).title == text)
		fixture.Optional_TextRecord_destroy(optional)
		outcome := fixture.echo_text_record_result(fixture.TextRecordResult_Record{input}) or_else panic("Owned record enum payload")
		assert(outcome.(fixture.TextRecordResult_Record).value.title == text)
		fixture.TextRecordResult_destroy(outcome)
		values := fixture.echo_text_records([]fixture.TextRecord{input, input}) or_else panic("Owned record slice")
		assert(len(values) == 2 && values[0].title == text && values[1].title == text)
		fixture.Array_TextRecord_destroy(values)
		assert(state.allocations == state.frees)
	}
	// Each output allocation can fail after earlier fields were converted.
	for remaining in 0..<6 {
		state.remaining = remaining
		value, ok := fixture.echo_wide_text_record({true, "first field", "second field", 73})
		if ok { fixture.WideTextRecord_destroy(value) }
		assert(state.allocations == state.frees)
	}
	state.remaining = -1
	invalid := fixture.WideTextRecord{true, "initialized first field", "\xff", 73}
	_, valid := fixture.echo_wide_text_record(invalid)
	assert(!valid && state.allocations == state.frees)

	request := Text_Record_Request{expected = "async owned UTF-8 📚 remains valid"}
	context.user_ptr = &request
	{
		text := strings.clone(request.expected)
		_ = fixture.echo_text_record_later({text, 73, true}, text_record_received) or_else panic("Async owned record")
		_ = fixture.echo_wide_text_record_later({true, text, "second", 73}, wide_text_record_received) or_else panic("Async indirect owned record")
		_ = fixture.TextRecord_adjusted_later({text, 68, true}, 5, text_record_received) or_else panic("Async owned receiver")
		delete(text) // Swift captures its own values before either start returns.
	}
	deadline := time.tick_now()
	for request.calls != 3 && time.tick_since(deadline) < 10*time.Second {
		cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
	}
	assert(request.calls == 3 && state.allocations == state.frees)
}
