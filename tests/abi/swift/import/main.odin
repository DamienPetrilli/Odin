package swift_import_test

foreign import fixture "swift:fixture/SwiftImportFixture"
import swift "core:sys/darwin/Swift"
import "core:time"
import cf "core:sys/darwin/CoreFoundation"

foreign {
	pthread_main_np :: proc "c" () -> i32 ---
}

GUARD :: u64(0xfedc_ba98_7654_3210)
Request :: struct {
	before: u64,
	expected: u64,
	value: u64,
	calls: int,
	after: u64,
}

Float_Request :: struct {
	before: u64,
	value: f64,
	calls: int,
	after: u64,
}

finished :: proc(request: ^Request, result: u64) {
	assert(pthread_main_np() == 1)
	assert(context.user_ptr == request)
	assert(request.before == GUARD && request.after == GUARD)
	assert(request.calls == 0)
	assert(result == request.expected)
	request.value = result
	request.calls += 1
}

float_finished :: proc(request: ^Float_Request, result: f64) {
	assert(pthread_main_np() == 1)
	assert(context.user_ptr == request)
	assert(request.before == GUARD && request.after == GUARD)
	assert(request.calls == 0)
	assert(result == -40.75)
	request.value = result
	request.calls += 1
}

yielded :: proc(calls: ^int) {
	assert(pthread_main_np() == 1)
	assert(context.user_ptr == calls)
	calls^ += 1
}

// These inputs go out of scope before Swift executes. The request itself
// belongs to main and stays alive until completion.
start :: proc(request: ^Request, value: u64) {
	context.user_ptr = request
	delta := u64(9)
	id, ok := fixture.add_later(value, delta, request, finished)
	assert(ok && id == request)
}

main :: proc() {
	check_values()
	check_strings()
	assert(fixture.add(17, 9) == 26)
	assert(fixture.add(0xffff_ffff_ffff_ffff, 9) == 8)
	assert(fixture.mixed(-41, 0.25) == -40.75)

	requests: [32]Request
	for &request, i in requests {
		value := GUARD + u64(i)
		request = {before = GUARD, expected = value+9, after = GUARD}
		start(&request, value)
		assert(request.calls == 0)
	}
	float_request := Float_Request{before = GUARD, after = GUARD}
	context.user_ptr = &float_request
	_, float_ok := fixture.mixed_later(-41, 0.25, &float_request, float_finished)
	assert(float_ok)
	yield_calls: int
	context.user_ptr = &yield_calls
	_, yield_ok := fixture.yield_once(&yield_calls, yielded)
	assert(yield_ok)
	context.user_ptr = nil

	no_callback: proc(^Request, u64)
	failed_id, failed_ok := fixture.add_later(0, 0, &requests[0], no_callback)
	assert(!failed_ok && failed_id == nil)
	check_ids()
	check_method()

	begin := time.tick_now()
	for {
		complete := float_request.calls == 1 && yield_calls == 1
		for request in requests {
			complete &&= request.calls == 1
		}
		if complete {
			break
		}
		cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
		assert(time.tick_since(begin) < 10*time.Second, "Swift import timed out")
	}
	for request in requests {
		assert(request.value == request.expected)
		assert(request.before == GUARD && request.after == GUARD)
	}
	assert(float_request.value == -40.75)
}

Book_Id :: distinct u64
Payload :: struct {
	id: Book_Id,
	guard: [2]u64,
}

ids: [32]swift.Request_Id
id_calls: [32]int
payload_calls, custom_calls, zero_calls: int

id_finished :: proc(id: swift.Request_Id, result: u64) {
	assert(result < len(ids))
	index := int(result)
	assert(ids[index] == id && id != 0)
	assert(id_calls[index] == 0)
	id_calls[index] += 1
}

payload_finished :: proc(data: Payload, result: u64) {
	assert(data.id == 73 && data.guard == [2]u64{GUARD, GUARD})
	assert(result == 26)
	payload_calls += 1
}

custom_finished :: proc(id: Book_Id, result: u64) {
	assert(id == 73 && result == 26)
	custom_calls += 1
}

zero_finished :: proc(id: u64, result: u64) {
	assert(id == 0 && result == 26)
	zero_calls += 1
}

start_id :: proc(index: int) -> bool {
	id := fixture.add_later(u64(index), 0, id_finished) or_return
	ids[index] = id
	return true
}

failed_start :: proc() -> bool {
	callback: proc(swift.Request_Id, u64)
	id := fixture.add_later(1, 2, callback) or_return
	_ = id
	panic("Failed start did not return")
}

start_payload :: proc() {
	payload := Payload{73, {GUARD, GUARD}}
	id, ok := fixture.add_later(17, 9, payload, payload_finished)
	assert(ok && id == payload)
	payload = {} // The callback receives the copy, after this frame returns.
}

check_ids :: proc() {
	assert(!failed_start())
	for i in 0..<len(ids) {
		assert(start_id(i))
		for j in 0..<i {
			assert(ids[i] != ids[j])
		}
	}
	start_payload()
	custom_id := fixture.add_later(17, 9, Book_Id(73), custom_finished)
	assert(custom_id == 73)
	zero, ok := fixture.add_later(17, 9, u64(0), zero_finished)
	assert(ok && zero == 0) // Zero is a valid caller-supplied ID.
	begin := time.tick_now()
	for {
		complete := payload_calls == 1 && custom_calls == 1 && zero_calls == 1
		for count in id_calls {
			complete &&= count == 1
		}
		if complete {
			break
		}
		cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
		assert(time.tick_since(begin) < 10*time.Second, "Swift IDs timed out")
	}
}

method_id: swift.Request_Id
method_calls: int

method_finished :: proc(id: swift.Request_Id) {
	assert(id == method_id && id != 0)
	method_calls += 1
}

method_custom_finished :: proc(id: Book_Id) {
	assert(id == 73)
	method_calls += 1
}

check_method :: proc() {
	address := fixture.make_counter(73)
	defer fixture.destroy_counter(address)
	receiver := fixture.Counter(rawptr(uintptr(address)))
	id, ok := fixture.Counter_wait(receiver, method_finished)
	assert(ok)
	method_id = id
	custom_id, custom_ok := fixture.Counter_wait(receiver, Book_Id(73), method_custom_finished)
	assert(custom_ok && custom_id == 73)
	failed_id, failed_ok := fixture.Counter_wait(nil, method_finished)
	assert(!failed_ok && failed_id == 0)
	begin := time.tick_now()
	for method_calls != 2 {
		cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
		assert(time.tick_since(begin) < 10*time.Second, "Swift method timed out")
	}
}
