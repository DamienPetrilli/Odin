package swift_import_test

foreign import fixture "swift:fixture/SwiftImportFixture"
import swift "core:sys/darwin/Swift"
import cf "core:sys/darwin/CoreFoundation"
import "core:time"
import "core:strings"

Text_Pair_Request :: struct {
	task:          swift.Task,
	first, second: string,
	calls:         int,
	converted:     bool,
	threw:         bool,
}

text_pair_received :: proc(task: swift.Task, first, second: string, converted: bool) {
	request := cast(^Text_Pair_Request)context.user_ptr
	assert(request.task == task && request.calls == 0)
	swift.task_release(task)
	request.first, request.second = first, second
	request.converted = converted
	request.calls += 1
}

checked_text_pair_received :: proc(task: swift.Task, first: string, size: int, second: string, ready: bool, err: fixture.Async_Error) {
	defer fixture.Async_Error_destroy(err)
	request := cast(^Text_Pair_Request)context.user_ptr
	assert(ready == (err == nil) && size == len(first))
	if request.threw {
		assert(err.(fixture.PlainFailure) == .Denied)
	} else if err != nil {
		_, failed := err.(swift.Result_Conversion_Failed)
		assert(failed)
	}
	text_pair_received(task, first, second, err == nil)
}

check_owned_tuples :: proc() {
	state := Value_Allocator{backing = context.allocator, remaining = -1}
	context.allocator = {procedure = value_allocator, data = &state}
	for text in ([]string{"Café 📚\x00book with shared Swift heap storage", ""}) {
		for throwing in ([]bool{false, true}) {
			for limit in 0..=3 {
				request := Text_Pair_Request{threw = throwing && limit == 3}
				context.user_ptr = &request
				state.remaining = -1
				input := strings.clone(text)
				state.remaining = limit
				ok: bool
				if throwing {
					request.task, ok = fixture.checked_text_pair(input, request.threw, checked_text_pair_received)
				} else {
					request.task, ok = fixture.text_pair_later(input, text_pair_received)
				}
				assert(ok)
				delete(input)
				deadline := time.tick_now()
				for request.calls == 0 && time.tick_since(deadline) < 10*time.Second {
					cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
				}
				assert(request.calls == 1 && request.converted == ((limit >= 2 || text == "") && !request.threw))
				if request.converted {
					assert(request.first == text && request.second == text)
					if len(text) != 0 { assert(raw_data(request.first) != raw_data(request.second)) }
					delete(request.first)
					assert(request.second == text)
					delete(request.second)
				} else {
					assert(raw_data(request.first) == nil && raw_data(request.second) == nil)
				}
				assert(state.allocations == state.frees)
			}
		}
	}
}
