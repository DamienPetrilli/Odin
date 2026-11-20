package swift_names_test

foreign import fixture "swift:fixture/SwiftNamesFixture"
import swift "core:sys/darwin/Swift"
import cf "core:sys/darwin/CoreFoundation"
import "core:time"

error_calls: int
private_error :: proc(task: swift.Task, value: u64, error: fixture.Async_Error) {
	defer fixture.Async_Error_destroy(error)
	unknown := error.(swift.Unknown_Error)
	assert(unknown.error != nil && value == 0)
	error_calls += 1
}

main :: proc() {
	assert(fixture.select_first(40) == 41)
	assert(fixture.select_last(40) == 42)
	assert(fixture.target_value(42) == 42)
	when ODIN_PLATFORM_SUBTARGET == .iPhone || ODIN_PLATFORM_SUBTARGET == .iPhoneSimulator {
		missing, ok := fixture.controller_address_presenting_options(nil, controller_received)
		assert(!ok && missing == nil)
		default_task := fixture.controller_address(controller_received) or_else panic("Default start")
		swift.task_release(default_task)
		start := time.tick_now()
		for controller_calls == 0 && time.tick_since(start) < 10*time.Second {
			cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
		}
		assert(controller_calls == 1 && controller_result == 0)
		test_controller(false)
		test_controller(true)
	}
	task := fixture.fail_without_public_error(private_error) or_else panic("Private error start")
	swift.task_release(task)
	deadline := time.tick_now()
	for error_calls == 0 && time.tick_since(deadline) < 10*time.Second {
		cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
	}
	assert(error_calls == 1)
	assert(fixture.len_(40) == 42)
	assert(fixture.f64_(12.0) == 12.5)
	item := fixture.Item_init(31) or_else panic("Named helper alias")
	defer fixture.Item_destroy(item)
	assert(fixture.Item_copy_amount(item, 11) == 42)
	copied := fixture.Item_copy(item) or_else panic("Owned copy")
	defer fixture.Item_destroy(copied)
	assert(fixture.Item_value(copied) == 31)
	assert(fixture.actual_scalar(41) == 42)
	assert(fixture.actual_flag(false) && !fixture.actual_flag(true))
	assert(fixture.actual_int(min(int)) == min(int))
	assert(fixture.actual_uint(max(uint)) == max(uint))
	assert(fixture.uint_(max(uint)) == max(uint))
	signed := fixture.Int_init(min(int)) or_else panic("Named Int")
	defer fixture.Int_destroy(signed)
	assert(fixture.Int_value(signed) == min(int))
	unsigned := fixture.UInt_init(max(uint)) or_else panic("Named UInt")
	defer fixture.UInt_destroy(unsigned)
	assert(fixture.UInt_value(unsigned) == max(uint))
	value := fixture.named_value(73) or_else panic("Named UInt64")
	defer fixture.UInt64_destroy(value)
	assert(fixture.UInt64_value(value) == 73)
	outcome := fixture.named_outcome(91) or_else panic("Named outcome")
	defer fixture.Outcome_destroy(outcome)
	payload := outcome.(fixture.Outcome_Value)
	assert(fixture.UInt64_value(payload.value) == 91)
	values := fixture.scalar_words([]u64{10, 20, 30}) or_else panic("Scalar array")
	defer delete(values)
	assert(len(values) == 3 && values[0] == 11 && values[2] == 31)
}
