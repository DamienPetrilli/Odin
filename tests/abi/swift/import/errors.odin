package swift_import_test

foreign import fixture "swift:fixture/SwiftImportFixture"
import swift "core:sys/darwin/Swift"
import cf "core:sys/darwin/CoreFoundation"
import "core:mem"
import "core:strings"
import "core:time"
import "base:intrinsics"

Error_Request :: struct {
	error: fixture.Call_Error,
	result: u64,
	calls: int,
}
error_received :: proc(task: swift.Task, result: u64, error: fixture.Call_Error) {
	request := cast(^Error_Request)context.user_ptr
	swift.task_release(task)
	request.error = error // Transfer the callback's owner beyond the task lifetime.
	request.result = result
	request.calls += 1
}

wait_for_error :: proc(request: ^Error_Request) {
	deadline := time.tick_now()
	for request.calls == 0 && time.tick_since(deadline) < 10*time.Second {
		cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
	}
	assert(request.calls == 1)
}

check_error_inspection :: proc() {
	state := Value_Allocator{backing = context.allocator, remaining = -1}
	context.allocator = {procedure = value_allocator, data = &state}
	_, nil_name := swift.error_type_name(nil)
	_, nil_text := swift.error_description(nil)
	_, nil_value := fixture.PlainFailure_from_error(nil)
	assert(!nil_name && !nil_text && nil_value == .Type_Mismatch && state.allocations == 0)
	assert(swift.error_metadata(nil) == nil)
	request: Error_Request
	context.user_ptr = &request
	baseline := fixture.live_value_count()
	for index in 0..<2 {
		request = {}
		if index == 0 {
			_ = fixture.diagnostic_failure("Detailed UTF-8 error 📚\x00after", error_received) or_else panic("Diagnostic error start")
		} else {
			_ = fixture.bridged_diagnostic_failure(error_received) or_else panic("Bridged error start")
		}
		wait_for_error(&request)
		// Private and bridged errors survive as owned fallback cases.
		copy := fixture.Call_Error_copy(request.error) or_else panic("Unknown error copy")
		fixture.Call_Error_destroy(request.error)
		error := copy.(swift.Unknown_Error).error
		_, err := fixture.PlainFailure_from_error(error)
		assert(err == .Type_Mismatch)
		for _ in 0..<20 {
			name := swift.error_type_name(error) or_else panic("Error type name")
			text := swift.error_description(error) or_else panic("Error description")
			if index == 0 {
				assert(strings.has_suffix(name, "DiagnosticFailure"))
				assert(text == "Detailed UTF-8 error 📚\x00after")
				assert(fixture.live_value_count() == baseline+1)
			} else {
				assert(strings.contains(name, "NSError"))
				assert(strings.contains(text, "SwiftImportFixture") && strings.contains(text, "73"))
			}
			delete(name)
			delete(text)
		}
		state.remaining = 0
		_, name_ok := swift.error_type_name(error)
		_, text_ok := swift.error_description(error)
		assert(!name_ok && !text_ok)
		state.remaining = -1
		text := swift.error_description(error) or_else panic("Retained diagnostic")
		fixture.Call_Error_destroy(copy)
		assert(len(text) > 0 && fixture.live_value_count() == baseline)
		delete(text)
		assert(state.allocations == state.frees)
	}
}

// Borrow the delivered union. Every concrete case is ordinary Odin data.
check_callback_error :: proc(error: fixture.Call_Error, selection: int) {
	if selection < 2 {
		plain := error.(fixture.PlainFailure)
		policies := [fixture.PlainFailure]u64{.Missing = 17, .Denied = 41}
		assert(plain == (selection == 0 ? .Missing : .Denied))
		assert(fixture.plain_failure_code(plain) == policies[plain])
	} else if selection < 4 || selection == 8 {
		failure := error.(fixture.InspectionFailure)
		code := fixture.inspection_failure_code(failure) or_else panic("Error round trip")
		assert(code == (selection == 2 ? 73 : selection == 3 ? 91 : 0))
		if selection == 2 {
			assert(failure.(fixture.InspectionFailure_Message).value_0 == "UTF-8 failure 📚\x00after")
		}
	} else if selection < 7 {
		#assert(!#defined(fixture.EvolvingFailure_Deferred))
		failure := error.(fixture.EvolvingFailure)
		code := fixture.evolving_failure_code(failure) or_else panic("Resilient error round trip")
		when #config(EVOLVED_VALUE_ENUM, false) {
			if selection == 6 {
				_, unknown := failure.(fixture.EvolvingFailure_Unknown)
				assert(unknown && code == 42)
			} else { assert(code == (selection == 5 ? 11 : 73)) }
		} else { assert(code == (selection == 5 ? 11 : 73)) }
	} else if selection == 7 {
		assert(error.(fixture.SoleFailure) == .Rejected)
	} else if selection == 9 {
		failure := error.(fixture.GenericFailure_Value)
		assert((fixture.generic_failure_code(failure) or_else panic("Generic error round trip")) == 73)
	} else if selection == 10 {
		unknown := error.(swift.Unknown_Error)
		name := swift.error_type_name(unknown.error) or_else panic("Unsupported type name")
		defer delete(name)
		assert(strings.has_suffix(name, "UnsupportedFailure"))
	} else { assert(error == nil) }
}

forward_word :: proc(input: u64) -> (word: u64, err: fixture.Call_Error) {
	word = fixture.throwing(input) or_return
	return
}

forward_bounds :: proc(n: u64) -> (count: u64, ready: bool, err: fixture.Call_Error) {
	count, ready = fixture.checked_bounds(n) or_return
	return
}

check_throwing_tuples :: proc() {
	count, ready, err := forward_bounds(max(u64))
	assert(count == max(u64) && ready && err == nil)
	count, ready, err = forward_bounds(0)
	assert(count == 0 && !ready && err.(fixture.PlainFailure) == .Missing)
	fixture.Call_Error_destroy(err)

	byte, flag, half, packed_err := fixture.checked_packed(0xab)
	assert(byte == 0xab && flag && half == 0xfedc && packed_err == nil)
	byte, flag, half, packed_err = fixture.checked_packed(0)
	assert(byte == 0 && !flag && half == 0 && packed_err.(fixture.PlainFailure) == .Denied)
	fixture.Call_Error_destroy(packed_err)

	byte, flag, half, packed_err = fixture.checked_unnamed(0xed)
	assert(byte == 0xed && flag && half == 0x1234 && packed_err == nil)

	words := [3]u64{17, 31, 59}
	first, floating, signed, last, active, wide_err := fixture.checked_wide(words[1:2], false)
	assert(first == 32 && transmute(u64)floating == 1<<63 && signed == min(i64) && last == max(u64) && active && wide_err == nil)
	first, floating, signed, last, active, wide_err = fixture.checked_wide(words[1:2], true)
	assert(first == 0 && transmute(u64)floating == 0 && signed == 0 && last == 0 && !active)
	assert(words == [3]u64{17, 33, 59})
	message := wide_err.(fixture.InspectionFailure).(fixture.InspectionFailure_Message)
	assert(message.value_0 == "wide result" && message.value_1 == 37)
	fixture.Call_Error_destroy(wide_err)
}

check_typed_errors :: proc() {
	check_throwing_tuples()
	assert(fixture.old_name(.Idle) == 17 && fixture.old_name(.Busy) == 31)
	before := fixture.live_value_count()
	for selection in 0..<12 {
		value, err := fixture.checked_failure(u64(selection))
		check_callback_error(err, selection)
		assert(value == (selection == 11 ? 42 : 0))
		fixture.Call_Error_destroy(err)
		assert(fixture.live_value_count() == before)
	}
	{
		original := context.allocator
		context.allocator = mem.nil_allocator()
		_, conversion := fixture.checked_failure(2)
		box := conversion.(swift.Error_Conversion_Failed).error
		context.allocator = original
		payload, err := fixture.InspectionFailure_from_error(box)
		assert(err == nil && payload.(fixture.InspectionFailure_Message).value_1 == 73)
		fixture.InspectionFailure_destroy(payload)
		fixture.Call_Error_destroy(conversion)
	}
	guarded := [4]i16{-7, 1, 2, 9}
	length, write_err := fixture.checked_edit(guarded[1:3], false)
	assert(length == 2 && write_err == nil && guarded == [4]i16{-7, 2, 2, 9})
	length, write_err = fixture.checked_edit(guarded[1:3], true)
	assert(length == 0 && write_err.(fixture.PlainFailure) == .Denied)
	assert(guarded == [4]i16{-7, 3, 2, 9})
	fixture.Call_Error_destroy(write_err)
	length, write_err = fixture.checked_edit(nil, false)
	assert(length == 0 && write_err == nil)
	value: u32 = 0x0123_4567
	read, read_err := fixture.checked_read(&value)
	assert(read == value && read_err == nil)
	for i in 0..<128 {
		word, err := fixture.throwing(u64(i))
		assert(word == u64(i) && err == nil)
		text, text_err := fixture.checked_description(false, u64(i))
		assert(strings.has_prefix(text, "A long Swift-owned text with λ, an emoji 🐶, and a NUL\x00inside.") && text_err == nil)
		delete(text)
		ignored, failed := fixture.checked_description(true, 42)
		assert(ignored == "" && failed.(fixture.PlainFailure) == .Denied)
		fixture.Call_Error_destroy(failed)
		unknown := fixture.check_unknown(true)
		assert(unknown.(swift.Unknown_Error).error != nil && fixture.live_value_count() == before+1)
		fixture.Call_Error_destroy(unknown)
		assert(fixture.live_value_count() == before)
		assert(fixture.check_unknown(false) == nil)
	}
	{
		context.allocator = mem.nil_allocator()
		text, failed := fixture.checked_description(false, 42)
		_, conversion_failed := failed.(swift.Result_Conversion_Failed)
		assert(text == "" && conversion_failed)
		fixture.Call_Error_destroy(failed)
	}
	word, forwarded := forward_word(123)
	assert(word == 123 && forwarded == nil)
	zero, missing := forward_word(max(u64))
	assert(zero == 0 && missing.(fixture.PlainFailure) == .Missing)
	fixture.Call_Error_destroy(missing)
	#assert(intrinsics.type_is_enum(fixture.PlainFailure))
	#assert(intrinsics.type_is_union(fixture.InspectionFailure))
	#assert(intrinsics.type_is_union(fixture.Call_Error))
	state := Value_Allocator{backing = context.allocator, remaining = -1}
	context.allocator = {procedure = value_allocator, data = &state}
	baseline := fixture.live_value_count()
	request: Error_Request
	context.user_ptr = &request
	fixture.Call_Error_destroy(nil)
	assert((fixture.Call_Error_copy(nil) or_else panic("Nil error copy")) == nil)
	// A single payload variant has an extra Odin nil state, never a Swift case.
	_, nil_accepted := fixture.generic_failure_code(nil)
	_, nil_copied := fixture.GenericFailure_Value_copy(nil)
	assert(!nil_accepted && !nil_copied)
	fixture.GenericFailure_Value_destroy(nil)
	for selection in 0..<12 {
		request = {}
		_ = fixture.inspection_failure(u64(selection), error_received) or_else panic("Error start")
		wait_for_error(&request)
		assert((request.error == nil) == (selection == 11))
		assert(request.result == (selection == 11 ? 42 : 0))
		check_callback_error(request.error, selection)
		balance := state.allocations-state.frees
		for remaining in 0..<4 {
			state.remaining = remaining
			copy, ok := fixture.Call_Error_copy(request.error)
			if ok { fixture.Call_Error_destroy(copy) } else { assert(copy == nil) }
			if selection < 2 || selection == 7 || selection == 8 || selection >= 10 { assert(ok) }
			assert(state.allocations-state.frees == balance)
		}
		state.remaining = -1
		copy := fixture.Call_Error_copy(request.error) or_else panic("Independent error copy")
		fixture.Call_Error_destroy(request.error)
		check_callback_error(copy, selection)
		fixture.Call_Error_destroy(copy)
		assert(fixture.live_value_count() == baseline && state.allocations == state.frees)
	}
	// Refuse each allocation in the callback projection, not just explicit copies.
	for selection in ([]int{2, 3, 4, 5, 6, 9}) {
		failures, successes := 0, 0
		for remaining in 0..<5 {
			request = {}
			state.remaining = remaining
			_ = fixture.inspection_failure(u64(selection), error_received) or_else panic("Failing projection start")
			wait_for_error(&request)
			state.remaining = -1
			failed, conversion_failed := request.error.(swift.Error_Conversion_Failed)
			if conversion_failed {
				failures += 1
				assert(failed.error != nil && request.result == 0)
				_, mismatch := fixture.PlainFailure_from_error(failed.error)
				assert(mismatch == .Type_Mismatch)
				copy: fixture.Call_Error
				{
					context.allocator = mem.nil_allocator()
					copy = fixture.Call_Error_copy(request.error) or_else panic("Fallback retain")
				}
				fixture.Call_Error_destroy(request.error)
				// Recover using the retained original, after the callback and its
				// first fallback owner have gone. A later successful copy is usable.
				original := copy.(swift.Error_Conversion_Failed).error
				recovered: fixture.Call_Error
				if selection < 4 {
					recovered = fixture.InspectionFailure_from_error(original) or_else panic("Payload retry")
				} else if selection < 7 {
					recovered = fixture.EvolvingFailure_from_error(original) or_else panic("Resilient retry")
				} else {
					recovered = fixture.GenericFailure_Value_from_error(original) or_else panic("Generic retry")
				}
				fixture.Call_Error_destroy(copy)
				check_callback_error(recovered, selection)
				fixture.Call_Error_destroy(recovered)
			} else {
				successes += 1
				check_callback_error(request.error, selection)
				fixture.Call_Error_destroy(request.error)
			}
			assert(fixture.live_value_count() == baseline && state.allocations == state.frees)
		}
		assert(failures != 0 && successes != 0)
	}
}
