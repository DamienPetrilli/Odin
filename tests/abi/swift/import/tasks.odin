package swift_import_test

import "base:runtime"
import "base:intrinsics"
import "core:time"
import swift "core:sys/darwin/Swift"
import cf "core:sys/darwin/CoreFoundation"
foreign import fixture "swift:fixture/SwiftImportFixture"

foreign {
	pthread_create :: proc "c" (thread: ^rawptr, attributes: rawptr, entry: proc "c" (rawptr) -> rawptr, data: rawptr) -> i32 ---
	pthread_join :: proc "c" (thread: rawptr, result: ^rawptr) -> i32 ---
}

lifetime_calls: int
saved_task: swift.Task
suspended_task: swift.Task
race_tasks: [256]swift.Task
race_calls: [256]int

cancelled :: proc(task: swift.Task, state: u64) {
	assert(state == 1 && swift.task_is_cancelled(task))
	assert(task == saved_task)
	lifetime_calls += 1
}

released :: proc(task: swift.Task, result: u64) {
	assert(result == 26)
	assert(!swift.task_is_cancelled(task))
	// The caller already released its reference. Execution still keeps this
	// borrowed reference valid, and we can retain it beyond the callback.
	saved_task = swift.task_retain(task)
	lifetime_calls += 1
}

suspended :: proc(task: swift.Task, result: u64) {
	assert(task == suspended_task && result == 73)
	assert(swift.task_is_cancelled(task))
	assert(fixture.cancellation_handled() == 1)
	assert(fixture.live_value_count() == 0)
	lifetime_calls += 1
}

cancel_error :: proc(task: swift.Task, value: fixture.Value, error: swift.Error) {
	assert(swift.task_is_cancelled(task) && value == nil && error != nil)
	swift.error_release(error)
	assert(fixture.live_value_count() == 0)
	lifetime_calls += 1
}

race_finished :: proc(task: swift.Task, result: u64) {
	assert(result < len(race_tasks))
	i := int(result)
	assert(task == race_tasks[i] && intrinsics.atomic_load(&race_calls[i]) == 0)
	// addLater does not cooperate with cancellation: success is still delivered.
	intrinsics.atomic_store(&race_calls[i], 1)
	swift.task_release(task) // Drop the start's reference during completion.
}

cancel_worker :: proc "c" (_: rawptr) -> rawptr {
	context = runtime.default_context()
	for task, i in race_tasks {
		// Half the cancels race with the callback dropping its reference or
		// occur after completion. The worker's own retain protects both cases.
		if i % 2 == 0 {
			for intrinsics.atomic_load(&race_calls[i]) == 0 {
				time.sleep(time.Microsecond)
			}
		}
		// This worker owns an independent reference, so it may race with
		// completion releasing the main thread's reference.
		swift.task_cancel(task)
		swift.task_cancel(task)
		swift.task_release(task)
	}
	return nil
}

pump_until :: proc(expected: int) {
	begin := time.tick_now()
	for lifetime_calls != expected {
		cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.001, false)
		assert(time.tick_since(begin) < 10*time.Second, "Task lifetime timed out")
	}
}

check_tasks :: proc() {
	assert(swift.task_retain(nil) == nil && !swift.task_is_cancelled(nil))
	swift.task_cancel(nil)
	swift.task_release(nil)

	// Cancel before the main executor starts the native function.
	task := fixture.cancellation_state(cancelled)
	assert(task != nil && !swift.task_is_cancelled(task))
	saved_task = swift.task_retain(task)
	assert(saved_task == task)
	swift.task_release(task)
	swift.task_cancel(saved_task)
	swift.task_cancel(saved_task)
	assert(swift.task_is_cancelled(saved_task))
	pump_until(1)
	// Retention keeps the native object valid after its execution completes.
	swift.task_cancel(saved_task)
	swift.task_release(saved_task)
	saved_task = nil

	task = fixture.add_later(17, 9, released)
	assert(task != nil)
	swift.task_release(task)
	pump_until(2)
	assert(saved_task != nil && !swift.task_is_cancelled(saved_task))
	swift.task_release(saved_task)
	saved_task = nil

	// Retaining a task must not keep its copied inputs alive after completion.
	value := fixture.Value_init(73) or_else panic("Cancellation value")
	suspended_task = fixture.wait_for_cancellation(value, suspended)
	assert(suspended_task != nil)
	fixture.Value_destroy(value)
	begin := time.tick_now()
	for fixture.cancellation_started() == 0 {
		cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.001, false)
		assert(time.tick_since(begin) < 10*time.Second)
	}
	assert(fixture.live_value_count() == 1 && lifetime_calls == 2)
	swift.task_cancel(suspended_task)
	pump_until(3)
	assert(fixture.live_value_count() == 0)
	swift.task_release(suspended_task)
	suspended_task = nil

	value = fixture.Value_init(73) or_else panic("Cancellation value")
	task = fixture.cancellation_error(value, cancel_error)
	assert(task != nil)
	fixture.Value_destroy(value)
	swift.task_cancel(task)
	swift.task_release(task)
	pump_until(4)

	for &slot, i in race_tasks {
		slot = fixture.add_later(u64(i), 0, race_finished)
		assert(slot != nil)
		owned := swift.task_retain(slot)
		assert(owned == slot)
	}
	worker: rawptr
	assert(pthread_create(&worker, nil, cancel_worker, nil) == 0)
	begin = time.tick_now()
	for {
		complete := true
		for i in 0..<len(race_calls) { complete &&= intrinsics.atomic_load(&race_calls[i]) == 1 }
		if complete { break }
		cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.001, false)
		assert(time.tick_since(begin) < 10*time.Second)
	}
	assert(pthread_join(worker, nil) == 0)
	// Neither address nor pointees are inspected after the final release.
	race_tasks = {}
	assert(fixture.live_value_count() == 0)
}
