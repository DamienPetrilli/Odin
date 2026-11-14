package swift_import_test

import "base:intrinsics"
import "core:mem"
import "core:time"
import cf "core:sys/darwin/CoreFoundation"
import swift "core:sys/darwin/Swift"
foreign import fixture "swift:fixture/SwiftImportFixture"

#assert(intrinsics.type_is_enum(fixture.Mode))
#assert(intrinsics.type_is_enum(fixture.SingleCase))
#assert(intrinsics.type_is_enum(fixture.RawCode))
#assert(intrinsics.type_is_enum(fixture.TextCode))
#assert(intrinsics.type_is_enum(fixture.WideCode))
#assert(intrinsics.type_is_union(fixture.ResilientChoice))

plain_enum_calls: int

mode_received :: proc(task: swift.Task, result: fixture.Mode) {
	assert(u64(result) == take_expected(task))
	plain_enum_calls += 1
}

single_case_received :: proc(task: swift.Task, result: fixture.SingleCase) {
	_ = take_expected(task)
	assert(result == .Only)
	plain_enum_calls += 1
}

single_case_arguments_received :: proc(task: swift.Task, result: f64) {
	assert(result == f64(take_expected(task)) + 0.5)
	plain_enum_calls += 1
}

single_case_throwing_received :: proc(task: swift.Task, result: fixture.SingleCase, error: swift.Error) {
	expected := take_expected(task)
	defer swift.error_release(error)
	assert((error == nil) == (expected != 0))
	if error == nil { assert(result == .Only) }
	plain_enum_calls += 1
}

raw_code_received :: proc(task: swift.Task, result: Maybe(fixture.RawCode)) {
	expected := take_expected(task)
	value, present := result.?
	assert(present == (expected != 0))
	if present { assert(fixture.raw_code_value(value) == expected) }
	plain_enum_calls += 1
}

check_plain_enums :: proc() {
	state := Value_Allocator{backing = context.allocator, remaining = 0}
	context.allocator = mem.Allocator{procedure = value_allocator, data = &state}
	assert(fixture.live_value_count() == 0)

	// Native enum values and scalar optionals need no Odin allocation or owner.
	for mode in fixture.Mode {
		assert(fixture.echo_mode(mode) == mode)
		value, present := fixture.optional_mode(mode).?
		assert(present && value == mode)
	}
	assert(fixture.optional_mode(nil) == nil)
	assert(fixture.toggle_mode(.Idle) == .Running && fixture.toggle_mode(.Running) == .Idle)
	assert(fixture.mode_code(.Idle) == 17 && fixture.mode_code(.Running) == 29)
	assert(fixture.raw_code_value(.First) == 10 && fixture.raw_code_value(.Second) == 20)
	assert(fixture.echo_single_case(.Only) == .Only)
	assert(fixture.make_single_case() == .Only)
	single, present := fixture.optional_single_case(fixture.SingleCase.Only).?
	assert(present && single == .Only)
	assert(fixture.optional_single_case(nil) == nil)
	assert(fixture.single_case_arguments(.Only, 17, .Only, 0.5, .Only) == 17.5)
	for value in fixture.RawCode {
		assert(fixture.echo_raw_code(value) == value)
		raw := fixture.raw_code_value(value)
		assert(raw == 10 || raw == 20)
		copy, valid := fixture.RawCode_init_raw_value(raw).?
		assert(valid && copy == value)
	}
	assert(fixture.RawCode_init_raw_value(0) == nil)
	assert(fixture.RawCode_init_raw_value(11) == nil)
	assert(fixture.RawCode_init_raw_value(max(u64)) == nil)
	for value in fixture.WideCode {
		assert(fixture.echo_wide_code(value) == value)
		raw := fixture.wide_code_value(value)
		assert(raw == 1000 + u64(value))
		copy, valid := fixture.WideCode_init_raw_value(raw).?
		assert(valid && copy == value)
	}
	assert(fixture.WideCode_init_raw_value(999) == nil)
	assert(fixture.WideCode_init_raw_value(1257) == nil)
	assert(state.allocations == 0)
	// Invalid Odin casts must not become invalid Swift values or start a task.
	rejected, started := fixture.mode_later(fixture.Mode(2), mode_received)
	assert(!started && rejected == nil)
	rejected, started = fixture.single_case_later(fixture.SingleCase(1), single_case_received)
	assert(!started && rejected == nil)
	state.remaining = -1

	for text, index in ([]string{"", "Café 📚", "other"}) {
		optional := fixture.TextCode_init_raw_value(text) or_else panic("Raw String initializer")
		value, valid := optional.?
		expected := [3]fixture.TextCode{.Empty, .Book, .Other}
		assert(valid && value == expected[index])
		copy := fixture.text_code_value(value) or_else panic("Raw String result")
		assert(copy == text)
		delete(copy)
	}
	missing := fixture.TextCode_init_raw_value("missing") or_else panic("Failable String initializer")
	assert(missing == nil)

	choice := fixture.echo_resilient_choice(fixture.ResilientChoice_Second{}) or_else panic("Resilient enum")
	_, second := choice.(fixture.ResilientChoice_Second)
	assert(second)
	fixture.ResilientChoice_destroy(choice)

	for input in ([]fixture.ModePayload{
		fixture.ModePayload_Named{.Running, "owned text alongside a native enum: Café 📚"},
		fixture.ModePayload_Single{.Only, "owned text alongside a zero-sized Swift value"},
	}) {
		result := fixture.echo_mode_payload(input) or_else panic("Enum in owned payload")
		copy := fixture.ModePayload_copy(result) or_else panic("Independent payload")
		fixture.ModePayload_destroy(result)
		switch item in copy {
		case fixture.ModePayload_Named:
			assert(item.value_0 == .Running && item.value_1 == input.(fixture.ModePayload_Named).value_1)
		case fixture.ModePayload_Single:
			assert(item.value_0 == .Only && item.value_1 == input.(fixture.ModePayload_Single).value_1)
		case fixture.ModePayload_Empty:
			panic("Unexpected empty payload")
		}
		fixture.ModePayload_destroy(copy)
		state.remaining = 0
		_, ok := fixture.echo_mode_payload(input)
		assert(!ok)
		state.remaining = -1
	}

	// Both Swift initializer rejection and post-call conversion failure must
	// release the initialized reference-counted field exactly once.
	none := fixture.FailableValue_init("") or_else panic("Absent owned initializer")
	assert(none == nil && fixture.live_value_count() == 0)
	text := "A failable initializer with native String ownership: Café 📚"
	optional := fixture.FailableValue_init(text) or_else panic("Present owned initializer")
	value, valid := optional.?
	assert(valid && fixture.live_value_count() == 1)
	kept := fixture.FailableValue_copy(value) or_else panic("Owned initializer copy")
	fixture.Optional_FailableValue_destroy(optional)
	copy := fixture.FailableValue_text(kept) or_else panic("Owned initializer text")
	assert(copy == text && fixture.live_value_count() == 1)
	delete(copy)
	fixture.FailableValue_destroy(kept)
	assert(fixture.live_value_count() == 0)
	for remaining in 0..<3 {
		state.remaining = remaining
		result, ok := fixture.FailableValue_init(text)
		if ok { fixture.Optional_FailableValue_destroy(result) }
		assert(fixture.live_value_count() == 0 && state.allocations == state.frees)
	}
	state.remaining = -1

	task := fixture.mode_later(.Running, mode_received) or_else panic("Async native enum")
	track_task(task, u64(fixture.Mode.Running))
	task = fixture.single_case_later(.Only, single_case_received) or_else panic("Async zero-sized enum")
	track_task(task)
	task = fixture.single_case_arguments_later(.Only, 29, .Only, 0.5, .Only, single_case_arguments_received) or_else panic("Async zero-sized arguments")
	track_task(task, 29)
	for value in ([]u64{0, 1}) {
		task = fixture.single_case_throwing(value, single_case_throwing_received) or_else panic("Throwing zero-sized result")
		track_task(task, value)
	}
	for raw in ([]u64{0, 10, 20}) {
		task = fixture.raw_code_later(raw, raw_code_received) or_else panic("Async optional enum")
		track_task(task, raw)
	}
	begin := time.tick_now()
	for plain_enum_calls != 8 {
		cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
		assert(time.tick_since(begin) < 10*time.Second)
	}
	assert(fixture.live_value_count() == 0 && state.allocations == state.frees)
}
