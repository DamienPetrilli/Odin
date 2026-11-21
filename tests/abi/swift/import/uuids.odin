package swift_import_test

foreign import fixture "swift:fixture/SwiftImportFixture"
import "core:encoding/uuid"
import "core:strings"
import "core:time"
import "base:runtime"
import swift "core:sys/darwin/Swift"
import cf "core:sys/darwin/CoreFoundation"

uuid_at_startup := uuid_before_main()
uuid_before_main :: proc "contextless" () -> uuid.Identifier {
	context = runtime.default_context()
	return fixture.echo_identifier(uuid.Identifier{15 = 0xff}) or_else panic("Global UUID")
}

UUID_Request :: struct {
	expected: uuid.Identifier,
	value: uuid.Identifier,
	error: fixture.Call_Error,
	calls: int,
	absent: bool,
}
uuid_received :: proc(task: swift.Task, value: uuid.Identifier) {
	request := cast(^UUID_Request)context.user_ptr
	swift.task_release(task)
	assert(value == request.expected)
	request.value = value
	request.calls += 1
}
optional_uuid_received :: proc(task: swift.Task, value: Maybe(uuid.Identifier)) {
	request := cast(^UUID_Request)context.user_ptr
	swift.task_release(task)
	if request.absent { assert(value == nil) } else { assert(value.(uuid.Identifier) == request.expected) }
	request.calls += 1
}
uuids_received :: proc(task: swift.Task, values: []uuid.Identifier, ok: bool) {
	request := cast(^UUID_Request)context.user_ptr
	swift.task_release(task)
	assert(ok && len(values) == 2 && values[0] == request.expected && values[1] == uuid.Identifier{})
	delete(values)
	request.calls += 1
}
checked_identifier_received :: proc(task: swift.Task, value: uuid.Identifier, err: fixture.Call_Error) {
	request := cast(^UUID_Request)context.user_ptr
	swift.task_release(task)
	request.error = err
	if err == nil { assert(value == request.expected); request.value = value }
	request.calls += 1
}
wait_for_uuid :: proc(request: ^UUID_Request) {
	deadline := time.tick_now()
	for request.calls == 0 && time.tick_since(deadline) < 10*time.Second {
		cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
	}
	assert(request.calls == 1)
}

check_uuids :: proc() {
	#assert(fixture.UUID == uuid.Identifier)
	#assert(size_of(fixture.UUID) == 16)
	assert(uuid_at_startup == uuid.Identifier{15 = 0xff})
	state := Value_Allocator{backing = context.allocator, remaining = -1}
	context.allocator = {procedure = value_allocator, data = &state}
	id := uuid.Identifier{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 254, 255}
	for seed in 0..<256 {
		value: uuid.Identifier
		for &b, index in value { b = u8((seed*31 + index*17)%256) }
		echo := fixture.echo_identifier(value) or_else panic("UUID round trip")
		assert(echo == value)
		reversed := fixture.reverse_identifier(value) or_else panic("UUID modification")
		for b, index in reversed { assert(b == value[15-index]) }
		optional := fixture.echo_optional_identifier(value) or_else panic("UUID optional")
		assert(optional.(uuid.Identifier) == value)
	}
	zero := uuid.Identifier{}
	assert((fixture.echo_identifier(zero) or_else panic("Zero UUID")) == zero)
	assert((fixture.echo_optional_identifier(zero) or_else panic("Present zero UUID")) != nil)
	assert((fixture.echo_optional_identifier(nil) or_else panic("Absent UUID")) == nil)
	text := fixture.identifier_text(id) or_else panic("UUID text")
	assert(text == "00010203-0405-0607-0809-0A0B0C0DFEFF")
	odin_text := uuid.to_string(id) or_else panic("Odin UUID text")
	assert(strings.equal_fold(text, odin_text))
	delete(text)
	delete(odin_text)
	choice := fixture.echo_identifier_choice(fixture.IdentifierChoice_Value{id}) or_else panic("UUID union")
	assert(choice.(fixture.IdentifierChoice_Value).value == id)
	fixture.IdentifierChoice_destroy(choice)
	for count in ([]int{0, 1, 2, 17, 257}) {
		input := make([]uuid.Identifier, count)
		for &value, index in input { value = id; value[0] = u8(index%256) }
		output := fixture.echo_identifiers(input) or_else panic("UUID array")
		assert(len(output) == count)
		for value, index in output { assert(value == input[index]) }
		if count > 0 { output[0][0] = ~output[0][0]; assert(output[0] != input[0]) }
		delete(output)
		for remaining in 0..<4 {
			state.remaining = remaining
			values, ok := fixture.reverse_identifiers(input)
			if ok {
				for value, index in values { for b, byte in value { assert(b == input[index][15-byte]) } }
				delete(values)
			}
		}
		state.remaining = -1
		delete(input)
		assert(state.allocations == state.frees)
	}
	state.remaining = 0
	assert((fixture.echo_identifier(id) or_else panic("Allocation-free UUID")) == id)
	state.remaining = -1
	request := UUID_Request{expected = id}
	context.user_ptr = &request
	_ = fixture.echo_identifier_later(id, uuid_received) or_else panic("Async UUID")
	id = {}
	wait_for_uuid(&request)
	assert(request.value == request.expected)
	request.calls = 0
	_ = fixture.echo_optional_identifier_later(request.expected, optional_uuid_received) or_else panic("Async optional UUID")
	wait_for_uuid(&request)
	request.calls = 0
	request.absent = true
	_ = fixture.echo_optional_identifier_later(nil, optional_uuid_received) or_else panic("Async absent UUID")
	wait_for_uuid(&request)
	request.calls = 0
	_ = fixture.echo_identifiers_later([]uuid.Identifier{request.expected, {}}, uuids_received) or_else panic("Async UUIDs")
	wait_for_uuid(&request)
	for fail in ([]bool{false, true}) {
		request.calls = 0
		_ = fixture.checked_identifier(request.expected, fail, checked_identifier_received) or_else panic("Throwing UUID")
		wait_for_uuid(&request)
		if fail { assert(request.error.(fixture.PlainFailure) == .Denied) } else { assert(request.error == nil) }
		fixture.Call_Error_destroy(request.error)
	}
	request.calls = 0
	task := fixture.cancellable_identifier(request.expected, checked_identifier_received) or_else panic("Cancel UUID")
	swift.task_cancel(task)
	wait_for_uuid(&request)
	assert(request.error != nil)
	fixture.Call_Error_destroy(request.error)
	assert(state.allocations == state.frees)
}
