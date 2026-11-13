package export_fixture

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
add_numbers :: proc(a, b: u64) -> u64 {
	assert(initialized == 42)
	// A normal Odin context is available on entry from Swift.
	values := make([]u64, 2)
	defer delete(values)
	values[0], values[1] = a, b
	return values[0] + values[1]
}

@(export)
update_reading :: proc(value: Reading) -> Reading {
	return Reading{value.page + 1, value.progress + 0.25}
}

@(export)
update_large :: proc(value: Large_Value) -> Large_Value {
	return Large_Value{value.a+1, value.b+2, value.c+3, value.d+4, value.e+5}
}

@(export)
modify_values :: proc(values: []u64, delta: u64) -> u64 {
	for &value in values {
		value += delta
	}
	return u64(len(values))
}

@(export)
round_trip :: proc(value: u64) -> u64 {
	return reply.increment(value)
}

@(export)
negate :: proc(value: bool) -> bool {
	return !value
}

@(export)
check_initialized :: proc() {
	assert(initialized == 42)
}

// Swift keywords must name this record, never an existential with another ABI.
Any :: struct {
	first, second: u64,
}

@(export)
update_any :: proc(value: Any) -> Any {
	return Any{value.first + 1, value.second + 2}
}
