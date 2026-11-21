package swift_import_test

import "core:mem"
import "core:strings"
import "core:time"
import cf "core:sys/darwin/CoreFoundation"
import swift "core:sys/darwin/Swift"
foreign import fixture "swift:fixture/SwiftImportFixture"

Async_String_Kind :: enum {
	Echo,
	Constant,
	Receiver,
	Checked,
	Allocation_Failure,
	Checked_Failure,
	Error,
	Error_Failure,
	Cancel,
	Ignore_Cancel,
	Released,
}

Async_String_Request :: struct {
	task: swift.Task,
	allocator: Value_Allocator,
	kind: Async_String_Kind,
	expected, result: string,
	calls: int,
}

async_string_check :: proc(task: swift.Task, text: string, error: fixture.Call_Error, converted: bool) {
	request := cast(^Async_String_Request)context.user_ptr
	assert(task == request.task && request.calls == 0 && pthread_main_np() == 1)
	assert(context.allocator.data == &request.allocator)
	cancelled := request.kind == .Cancel || request.kind == .Ignore_Cancel
	assert(swift.task_is_cancelled(task) == cancelled)
	if request.kind != .Released { swift.task_release(task) }
	request.task = nil
	expect_error := request.kind == .Error || request.kind == .Error_Failure || request.kind == .Cancel
	_, result_failed := error.(swift.Result_Conversion_Failed)
	assert((error != nil && !result_failed) == expect_error)
	fixture.Call_Error_destroy(error)
	failed := request.kind == .Allocation_Failure || request.kind == .Checked_Failure
	expect_converted := !expect_error && (!failed || len(request.expected) == 0)
	assert(converted == expect_converted)
	if converted {
		assert(text == request.expected && len(text) == len(request.expected))
		request.result = text // Ownership survives the callback and task.
	} else {
		assert(len(text) == 0 && raw_data(text) == nil)
	}
	request.calls += 1
}

async_string_complete :: proc(task: swift.Task, text: string, error: fixture.Call_Error) {
	async_string_check(task, text, error, error == nil)
}

async_string_received :: proc(task: swift.Task, text: string, converted: bool) {
	async_string_check(task, text, nil, converted)
}

start_async_string :: proc(request: ^Async_String_Request, kind: Async_String_Kind, text: string) {
	backing := context.allocator
	input := strings.clone(text)
	defer mem.free(raw_data(input), backing)
	request.kind = kind
	request.expected = text
	request.allocator = {backing = backing, remaining = -1}
	context.allocator = {procedure = value_allocator, data = &request.allocator}
	context.user_ptr = request
	if kind == .Allocation_Failure || kind == .Checked_Failure || kind == .Error_Failure {
		request.allocator.remaining = 0
	}
	ok: bool
	switch kind {
	case .Constant:
		request.expected = "native async string"
		request.task, ok = fixture.text_later(async_string_received)
	case .Receiver:
		value := fixture.TextValue_init(input) or_else panic("String receiver")
		request.task, ok = fixture.TextValue_text_later(value, async_string_received)
		fixture.TextValue_destroy(value)
	case .Checked, .Checked_Failure, .Error, .Error_Failure, .Cancel:
		fail := kind == .Error || kind == .Error_Failure
		request.task, ok = fixture.checked_text_later(input, fail, async_string_complete)
	case .Echo, .Allocation_Failure, .Ignore_Cancel, .Released:
		request.task, ok = fixture.echo_text_later(input, async_string_received)
	}
	assert(ok && request.task != nil)
	if kind == .Cancel || kind == .Ignore_Cancel { swift.task_cancel(request.task) }
	if kind == .Released { swift.task_release(request.task) }
	// The task's input was copied before start returned. Neither this input
	// nor a receiver supplied above remains available when completion runs.
	if len(input) != 0 { mem.set(raw_data(input), 0xff, len(input)) }
}

check_async_strings :: proc() {
	large := strings.repeat("café 日本語 🦉\x00tail", 4096)
	defer delete(large)
	samples := []string{"", "a", "123456789012345", "1234567890123456", "a\x00b", "é", "e\u0301", "日本語 🦉", large}
	requests: [32]Async_String_Request
	count := 0
	for sample in samples {
		start_async_string(&requests[count], .Echo, sample)
		count += 1
	}
	for kind in ([]Async_String_Kind{.Constant, .Receiver, .Checked, .Allocation_Failure, .Checked_Failure, .Error, .Error_Failure, .Cancel, .Ignore_Cancel, .Released}) {
		start_async_string(&requests[count], kind, large)
		count += 1
	}
	// Empty success needs no Odin allocation, even through a throwing ABI.
	for kind in ([]Async_String_Kind{.Allocation_Failure, .Checked_Failure}) {
		start_async_string(&requests[count], kind, "")
		count += 1
	}
	callback: proc(swift.Task, string, bool)
	rejected, ok := fixture.echo_text_later("not started", callback)
	assert(!ok && rejected == nil)
	rejected, ok = fixture.echo_text_later("\xff", async_string_received)
	assert(!ok && rejected == nil)

	begin := time.tick_now()
	for {
		completed := 0
		for request in requests[:count] { completed += request.calls }
		if completed == count { break }
		assert(time.tick_since(begin) < 10*time.Second)
		_ = cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
	}
	assert(fixture.live_value_count() == 0)
	backing := context.allocator
	for &request in requests[:count] {
		assert(request.calls == 1 && request.task == nil)
		if len(request.result) != 0 {
			assert(request.result == request.expected)
			// Send the independently owned output back to Swift after completion.
			assert(fixture.utf8_count(request.result) == u64(len(request.expected)))
			assert(raw_data(request.result) != raw_data(request.expected))
		}
		context.allocator = {procedure = value_allocator, data = &request.allocator}
		delete(request.result)
		assert(request.allocator.allocations == request.allocator.frees)
		context.allocator = backing
	}
}
