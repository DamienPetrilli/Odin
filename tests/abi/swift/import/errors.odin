package swift_import_test

foreign import fixture "swift:fixture/SwiftImportFixture"
import swift "core:sys/darwin/Swift"
import cf "core:sys/darwin/CoreFoundation"
import "core:mem"
import "core:strings"
import "core:time"
import "base:intrinsics"

Error_Request :: struct {
	error: fixture.Async_Error,
	result: u64,
	calls: int,
}
error_received :: proc(task: swift.Task, result: u64, error: fixture.Async_Error) {
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
		copy := fixture.Async_Error_copy(request.error) or_else panic("Unknown error copy")
		fixture.Async_Error_destroy(request.error)
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
		fixture.Async_Error_destroy(copy)
		assert(len(text) > 0 && fixture.live_value_count() == baseline)
		delete(text)
		assert(state.allocations == state.frees)
	}
}

// Borrow the delivered union. Every concrete case is ordinary Odin data.
check_callback_error :: proc(error: fixture.Async_Error, selection: int) {
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

check_typed_errors :: proc() {
	#assert(intrinsics.type_is_enum(fixture.PlainFailure))
	#assert(intrinsics.type_is_union(fixture.InspectionFailure))
	#assert(intrinsics.type_is_union(fixture.Async_Error))
	state := Value_Allocator{backing = context.allocator, remaining = -1}
	context.allocator = {procedure = value_allocator, data = &state}
	baseline := fixture.live_value_count()
	request: Error_Request
	context.user_ptr = &request
	fixture.Async_Error_destroy(nil)
	assert((fixture.Async_Error_copy(nil) or_else panic("Nil error copy")) == nil)
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
			copy, ok := fixture.Async_Error_copy(request.error)
			if ok { fixture.Async_Error_destroy(copy) } else { assert(copy == nil) }
			if selection < 2 || selection == 7 || selection == 8 || selection >= 10 { assert(ok) }
			assert(state.allocations-state.frees == balance)
		}
		state.remaining = -1
		copy := fixture.Async_Error_copy(request.error) or_else panic("Independent error copy")
		fixture.Async_Error_destroy(request.error)
		check_callback_error(copy, selection)
		fixture.Async_Error_destroy(copy)
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
				copy: fixture.Async_Error
				{
					context.allocator = mem.nil_allocator()
					copy = fixture.Async_Error_copy(request.error) or_else panic("Fallback retain")
				}
				fixture.Async_Error_destroy(request.error)
				// Recover using the retained original, after the callback and its
				// first fallback owner have gone. A later successful copy is usable.
				original := copy.(swift.Error_Conversion_Failed).error
				recovered: fixture.Async_Error
				if selection < 4 {
					recovered = fixture.InspectionFailure_from_error(original) or_else panic("Payload retry")
				} else if selection < 7 {
					recovered = fixture.EvolvingFailure_from_error(original) or_else panic("Resilient retry")
				} else {
					recovered = fixture.GenericFailure_Value_from_error(original) or_else panic("Generic retry")
				}
				fixture.Async_Error_destroy(copy)
				check_callback_error(recovered, selection)
				fixture.Async_Error_destroy(recovered)
			} else {
				successes += 1
				check_callback_error(request.error, selection)
				fixture.Async_Error_destroy(request.error)
			}
			assert(fixture.live_value_count() == baseline && state.allocations == state.frees)
		}
		assert(failures != 0 && successes != 0)
	}
}
