package swift_import_test

foreign import fixture "swift:fixture/SwiftImportFixture"
import swift "core:sys/darwin/Swift"
import "core:time"
import cf "core:sys/darwin/CoreFoundation"

foreign {
	pthread_main_np :: proc "c" () -> i32 ---
	alarm :: proc "c" (seconds: u32) -> u32 ---
}

GUARD :: u64(0xfedc_ba98_7654_3210)

// Application-owned data keyed by a native handle. No generated correlation ID
// or user payload is stored in the Swift task. Starts and callbacks here share
// the main thread, so registration precedes callback delivery.
expected_values: map[swift.Task]u64

track_task :: proc(task: swift.Task, expected: u64 = 0) {
	assert(task != nil)
	_, found := expected_values[task]
	assert(!found)
	expected_values[task] = expected
}

take_expected :: proc(task: swift.Task) -> u64 {
	expected, found := expected_values[task]
	assert(found)
	delete_key(&expected_values, task)
	// Drop the start's owned reference. Execution still protects the borrowed
	// callback handle until the callback and root continuation return.
	swift.task_release(task)
	return expected
}

Request :: struct {
	before: u64,
	task: swift.Task,
	expected: u64,
	value: u64,
	calls: int,
	after: u64,
}

finished :: proc(task: swift.Task, result: u64) {
	request := cast(^Request)context.user_ptr
	assert(pthread_main_np() == 1)
	assert(task == request.task)
	assert(request.before == GUARD && request.after == GUARD)
	assert(request.calls == 0 && result == request.expected)
	request.value = result
	request.calls += 1
}

float_calls, yield_calls: int
float_finished :: proc(task: swift.Task, result: f64) {
	assert(pthread_main_np() == 1 && result == -40.75)
	assert(take_expected(task) == 0)
	float_calls += 1
}
yielded :: proc(task: swift.Task) {
	assert(pthread_main_np() == 1)
	assert(take_expected(task) == 0)
	yield_calls += 1
}

start :: proc(request: ^Request, value: u64) -> bool {
	context.user_ptr = request
	delta := u64(9)
	task := fixture.add_later(value, delta, finished) or_return
	request.task = task
	return true
}

failed_start :: proc() -> bool {
	callback: proc(swift.Task, u64)
	task := fixture.add_later(1, 2, callback) or_return
	_ = task
	panic("Rejected start did not return")
}

main :: proc() {
	// Bound the entire process, including worker joins and runtime callbacks.
	_ = alarm(60)
	defer alarm(0)
	expected_values = make(map[swift.Task]u64)
	defer delete(expected_values)
	check_array_concurrency()
	check_values()
	check_projected_enums()
	check_plain_enums()
	check_strings()
	check_arrays()
	check_tasks()
	assert(fixture.add(17, 9) == 26)
	assert(fixture.add(0xffff_ffff_ffff_ffff, 9) == 8)
	assert(fixture.mixed(-41, 0.25) == -40.75)
	assert(!failed_start())

	requests: [32]Request
	for &request, i in requests {
		value := GUARD + u64(i)
		request = {before = GUARD, expected = value+9, after = GUARD}
		assert(start(&request, value))
		assert(request.calls == 0)
		for j in 0..<i { assert(request.task != requests[j].task) }
	}
	task := fixture.mixed_later(-41, 0.25, float_finished)
	track_task(task)
	task = fixture.yield_once(yielded)
	track_task(task)
	check_method()

	begin := time.tick_now()
	for {
		complete := float_calls == 1 && yield_calls == 1
		for request in requests { complete &&= request.calls == 1 }
		if complete { break }
		cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
		assert(time.tick_since(begin) < 10*time.Second, "Swift import timed out")
	}
	for request in requests {
		assert(request.value == request.expected)
		assert(request.before == GUARD && request.after == GUARD)
		swift.task_release(request.task)
	}
	assert(len(expected_values) == 0)
}

method_calls: int
method_finished :: proc(task: swift.Task) {
	assert(take_expected(task) == 73)
	method_calls += 1
}

check_method :: proc() {
	address := fixture.make_counter(73)
	defer fixture.destroy_counter(address)
	receiver := fixture.Counter(rawptr(uintptr(address)))
	task := fixture.Counter_wait(receiver, method_finished)
	track_task(task, 73)
	failed, ok := fixture.Counter_wait(nil, method_finished)
	assert(!ok && failed == nil)
	begin := time.tick_now()
	for method_calls != 1 {
		cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
		assert(time.tick_since(begin) < 10*time.Second, "Swift method timed out")
	}
}
