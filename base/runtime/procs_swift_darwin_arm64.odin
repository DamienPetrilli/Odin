#+build darwin, arm64
package runtime

import "base:intrinsics"

// Internal support for compiler-generated Swift async imports. The capture
// contains plain copied values, with alignment at most eight bytes.
Swift_Async_Frame :: struct {
	parent: ^Swift_Async_Frame,
	resume: rawptr,
}

Swift_Async_Descriptor :: struct {
	entry_offset: i32,
	context_size: u32,
}

Swift_Async_Task_Frame :: struct {
	using base: Swift_Async_Frame,
	descriptor: ^Swift_Async_Descriptor,
	invoke: proc(rawptr),
	odin_context: Context,
}

Swift_Async_Task_And_Frame :: struct {
	task: rawptr,
	frame: ^Swift_Async_Task_Frame,
}

Swift_Async_Executor :: struct {
	identity, implementation: u64,
}

foreign {
	@(link_name="swift_retain")
	swift_async_retain :: proc "c" (task: rawptr) -> rawptr ---
	@(link_name="swift_task_getCurrent")
	swift_async_current :: proc "swift" () -> rawptr ---
	@(link_name="swift_task_create_common")
	swift_async_create :: proc "swift" (flags: u64, options, future_type, entry, capture: rawptr, context_size: u64) -> Swift_Async_Task_And_Frame ---
	@(link_name="swift_task_alloc")
	swift_async_alloc :: proc "swift" (size: u64) -> ^Swift_Async_Frame ---
	@(link_name="swift_task_dealloc")
	swift_async_dealloc :: proc "swift" (frame: ^Swift_Async_Frame) ---
	@(link_name="swift_task_getMainExecutor")
	swift_async_main_executor :: proc "swift" () -> Swift_Async_Executor ---
	@(link_name="swift_task_enqueueTaskOnExecutor")
	swift_async_enqueue :: proc "swift" (task: rawptr, executor: Swift_Async_Executor) ---
	@(link_name="swift_task_switch")
	swift_async_switch :: proc "swift/async" (#swift_async frame: ^Swift_Async_Frame, resume: rawptr, identity, implementation: u64) ---
}

swift_async_payload :: proc "contextless" (frame: rawptr) -> rawptr {
	return rawptr(uintptr(frame) + size_of(Swift_Async_Task_Frame))
}

swift_async_start :: proc(entry, descriptor, capture: rawptr, capture_size: int, invoke: proc(rawptr), completion: rawptr) -> rawptr {
	desc := cast(^Swift_Async_Descriptor)descriptor
	if completion == nil || desc == nil || desc.context_size < size_of(Swift_Async_Frame) {
		return nil
	}
	discard_result :: 1 << 14
	size := u64(size_of(Swift_Async_Task_Frame) + capture_size)
	task := swift_async_create(discard_result, nil, nil, entry, nil, size)
	task.frame.descriptor = desc
	task.frame.invoke = invoke
	task.frame.odin_context = context
	mem_copy_non_overlapping(swift_async_payload(task.frame), capture, capture_size)
	// Execution consumes one reference. Keep the creation reference for the
	// caller, independently of completion and the lifetime of captured values.
	// Retain before enqueue: another thread may run the task immediately.
	swift_async_retain(task.task)
	swift_async_enqueue(task.task, swift_async_main_executor())
	return task.task
}

swift_async_prepare :: proc "contextless" (parent, resume: rawptr) -> rawptr {
	task := cast(^Swift_Async_Task_Frame)parent
	child := swift_async_alloc(u64(task.descriptor.context_size))
	child.parent = &task.base
	child.resume = resume
	return child
}

swift_async_complete :: proc "swift/async" (#swift_async frame: rawptr) {
	child := cast(^Swift_Async_Frame)frame
	parent := child.parent
	intrinsics.swift_async_context_addr()^ = parent
	swift_async_dealloc(child)
	executor := swift_async_main_executor()
	#must_tail swift_async_switch(parent, rawptr(swift_async_invoke), executor.identity, executor.implementation)
}

swift_async_invoke :: proc "swift/async" (#swift_async frame: ^Swift_Async_Frame) {
	task := cast(^Swift_Async_Task_Frame)frame
	context = task.odin_context
	task.invoke(swift_async_payload(task))
	Resume :: proc "swift/async" (#swift_async frame: ^Swift_Async_Frame, #swift_self error: rawptr)
	#must_tail (cast(Resume)frame.resume)(frame, nil)
}
