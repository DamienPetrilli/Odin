#+build darwin, arm64
package darwin_Swift

import "base:runtime"

// An opaque native Swift task reference. A successful async start returns one
// owned reference. A completion receives a borrowed reference, valid through
// the callback. Copying a Task does not retain it. Identity is the native task
// address, which may be reused after the final release. Results are delivered
// through completion.
Task :: distinct rawptr

@(private)
foreign {
	@(link_name="swift_release")
	task_release_native :: proc "c" (task: Task) ---
	@(link_name="swift_task_cancel")
	task_cancel_native :: proc "swift" (task: Task) ---
	@(link_name="swift_task_isCancelled")
	task_is_cancelled_native :: proc "swift" (task: Task) -> bool ---
}

// Acquire another owned reference to a live task, including a task borrowed
// by a completion. Each owned reference must be released once.
@(require_results)
task_retain :: proc(task: Task) -> Task {
	if task == nil {
		return nil
	}
	return Task(runtime.swift_async_retain(rawptr(task)))
}

// Drop one owned reference. This neither cancels nor waits for the operation.
// Execution keeps the task alive through completion even if the caller releases
// every reference. Borrowed context and mutating receivers must still survive
// completion. Releasing a reference does not clear other copies of its address.
task_release :: proc(task: Task) {
	if task != nil {
		task_release_native(task)
	}
}

// Request cooperative cancellation. The operation may ignore the request or
// finish successfully before observing it. Completion still runs exactly once
// if the operation returns. Cancellation handlers can run synchronously here;
// do not hold locks they may acquire. Each concurrent caller needs a live task
// reference for the duration of the call.
task_cancel :: proc(task: Task) {
	if task != nil {
		task_cancel_native(task)
	}
}

// Cancellation requested, not completion. Nil is not cancelled.
task_is_cancelled :: proc(task: Task) -> bool {
	return task != nil && task_is_cancelled_native(task)
}
