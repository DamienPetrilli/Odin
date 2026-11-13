package export_fixture

import "base:runtime"

foreign import reply "swift:reply/SwiftReply"

Reading :: struct {
	page:     i64,
	progress: f64,
}

Large_Value :: struct {
	a, b, c, d, e: u64,
}

initialized: u64

@(init)
initialize :: proc "contextless" () {
	initialized = 42
}

@(export)
add_numbers :: proc "swift" (a, b: u64) -> u64 {
	// Establish context explicitly before allocation or diagnostics.
	context = runtime.default_context()
	assert(initialized == 42)
	values := make([]u64, 2)
	defer delete(values)
	values[0], values[1] = a, b
	return values[0] + values[1]
}

@(export)
update_reading :: proc "swift" (value: Reading) -> Reading {
	return Reading{value.page + 1, value.progress + 0.25}
}

@(export)
update_large :: proc "swift" (value: Large_Value) -> Large_Value {
	return Large_Value{value.a+1, value.b+2, value.c+3, value.d+4, value.e+5}
}

@(export)
modify_values :: proc "swift" (values: []u64, delta: u64) -> u64 {
	for &value in values {
		value += delta
	}
	return u64(len(values))
}

@(export)
round_trip :: proc "swift" (value: u64) -> u64 {
	return reply.increment(value)
}

@(export)
negate :: proc "swift" (value: bool) -> bool {
	return !value
}

@(export)
check_initialized :: proc "swift" () {
	context = runtime.default_context()
	assert(initialized == 42)
}

// Swift keywords must name this record, never an existential with another ABI.
Any :: struct {
	first, second: u64,
}

@(export)
update_any :: proc "swift" (value: Any) -> Any {
	return Any{value.first + 1, value.second + 2}
}

@(export)
modify_signed :: proc "swift" (values: []i64) {
	for &value in values { value -= 2 }
}

@(export)
modify_floats :: proc "swift" (values: []f64) {
	for &value in values { value *= 1.5 }
}

// A Swift callback remains callable by address without becoming module API.
private_add :: proc "swift" (value: u64) -> u64 { return value + 1 }

@(export)
call_private :: proc "swift" (value: u64) -> u64 {
	callback: proc "swift" (u64) -> u64 = private_add
	return callback(value)
}

// Existing exports using other conventions are not selected for Swift.
@(export)
c_answer :: proc "c" (value: i32) -> i32 { return value + 1 }

@(export)
odin_length :: proc(value: string) -> int { return len(value) }
