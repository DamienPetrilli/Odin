#+build darwin, arm64
package darwin_Swift

import "base:intrinsics"
import "base:runtime"

// The companion symbol for a Swift async procedure supplies the size of the
// context it expects, which can vary with the library version.
Async_Descriptor :: runtime.Swift_Async_Descriptor
Async_Context :: runtime.Swift_Async_Frame

Async_Method :: proc "swift/async" (#swift_async async_ctx: ^Async_Context, #swift_self receiver: rawptr)
Async_Result_Method :: proc "swift/async" (result: rawptr, #swift_async async_ctx: ^Async_Context, #swift_self receiver: rawptr)
@(private)
Completion_Invoker :: proc (user_data, completion: rawptr)

async_call :: proc {
	async_call_void,
	async_call_result,
}

// Start a non-throwing Swift method on the main executor. The caller owns the
// receiver, any uninitialized result storage, and user data. Keep them alive
// through the callback, which runs on the main executor with a copy of the
// caller's Odin context. The values referenced by that context must also stay
// valid through completion. A false return means no callback will run.
@(require_results)
async_call_void :: proc(
	method: Async_Method,
	descriptor: ^Async_Descriptor,
	receiver: rawptr,
	user_data: $T,
	completion: proc(user_data: T),
) -> bool where intrinsics.type_is_pointer(T) {
	return start(rawptr(method), descriptor, receiver, nil, user_data, rawptr(completion), completion_invoker(T))
}

@(require_results)
async_call_result :: proc(
	method: Async_Result_Method,
	descriptor: ^Async_Descriptor,
	receiver, result: rawptr,
	user_data: $T,
	completion: proc(user_data: T),
) -> bool where intrinsics.type_is_pointer(T) {
	if result == nil {
		return false
	}
	return start(rawptr(method), descriptor, receiver, result, user_data, rawptr(completion), completion_invoker(T))
}

@(private)
completion_invoker :: proc($T: typeid) -> Completion_Invoker {
	return proc(user_data, completion: rawptr) {
		(cast(proc(user_data: T))completion)(cast(T)user_data)
	}
}

@(private)
Task_Context :: struct {
	using base: Async_Context,
	method:       rawptr,
	context_size: u64,
	receiver:     rawptr,
	result:       rawptr,
	user_data:    rawptr,
	completion:   rawptr,
	invoke:       Completion_Invoker,
	odin_context: runtime.Context,
}

@(private)
Task_Resume :: proc "swift/async" (#swift_async async_ctx: ^Async_Context, #swift_self error: rawptr)

@(private)
start :: proc(
	method: rawptr,
	descriptor: ^Async_Descriptor,
	receiver, result, user_data: rawptr,
	completion: rawptr,
	invoke: Completion_Invoker,
) -> bool {
	if method == nil || descriptor == nil || descriptor.context_size < size_of(Async_Context) || receiver == nil || completion == nil {
		return false
	}

	discard_result :: 1 << 14
	task := runtime.swift_async_create(discard_result, nil, nil, rawptr(task_entry), nil, size_of(Task_Context))
	// The runtime initializes the header. The rest of the frame holds our data.
	async_ctx := cast(^Task_Context)task.frame
	async_ctx.method = method
	async_ctx.context_size = u64(descriptor.context_size)
	async_ctx.receiver = receiver
	async_ctx.result = result
	async_ctx.user_data = user_data
	async_ctx.completion = completion
	async_ctx.invoke = invoke
	async_ctx.odin_context = context
	// Transfer the task's owned reference to execution. The Swift runtime
	// releases it when the task's final continuation runs.
	runtime.swift_async_enqueue(task.task, runtime.swift_async_main_executor())
	return true
}

@(private)
task_entry :: proc "swift/async" (#swift_async async_ctx: ^Async_Context, #swift_self _: rawptr) {
	task := cast(^Task_Context)async_ctx
	child := runtime.swift_async_alloc(task.context_size)
	child.parent = async_ctx
	child.resume = rawptr(method_resumed)
	if task.result == nil {
		#must_tail (cast(Async_Method)task.method)(child, task.receiver)
		return
	}
	#must_tail (cast(Async_Result_Method)task.method)(task.result, child, task.receiver)
}

@(private)
method_resumed :: proc "swift/async" (#swift_async child: ^Async_Context) {
	parent := child.parent
	// Restore the parent in the async context slot before freeing the child.
	intrinsics.swift_async_context_addr()^ = parent
	runtime.swift_async_dealloc(child)
	executor := runtime.swift_async_main_executor()
	#must_tail runtime.swift_async_switch(parent, rawptr(complete_on_main), executor.identity, executor.implementation)
}

@(private)
complete_on_main :: proc "swift/async" (#swift_async async_ctx: ^Async_Context) {
	task := cast(^Task_Context)async_ctx
	context = task.odin_context
	task.invoke(task.user_data, task.completion)
	#must_tail (cast(Task_Resume)async_ctx.resume)(async_ctx, nil)
}
