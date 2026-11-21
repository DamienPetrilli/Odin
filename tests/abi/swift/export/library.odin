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

@(export)
identity_native_int :: proc "swift" (value: int) -> int { return reply.identity_int(value) }
@(export)
identity_native_uint :: proc "swift" (value: uint) -> uint { return reply.identity_uint(value) }
@(export)
identity_bool :: proc "swift" (value: bool) -> bool { return reply.identity_bool(value) }

Native_Words :: struct {
	signed:   int,
	unsigned: uint,
}

@(export)
identity_words :: proc "swift" (value: Native_Words) -> Native_Words { return value }

@(export)
modify_native_words :: proc "swift" (signed: []int, unsigned: []uint) {
	for &value in signed { value = -73 }
	for &value in unsigned { value = max(uint) }
}

@(export)
identity_i8 :: proc "swift" (value: i8) -> i8 { return reply.identity_int8(value) }
@(export)
identity_u8 :: proc "swift" (value: u8) -> u8 { return reply.identity_uint8(value) }
@(export)
identity_i16 :: proc "swift" (value: i16) -> i16 { return reply.identity_int16(value) }
@(export)
identity_u16 :: proc "swift" (value: u16) -> u16 { return reply.identity_uint16(value) }
@(export)
identity_i32 :: proc "swift" (value: i32) -> i32 { return reply.identity_int32(value) }
@(export)
identity_u32 :: proc "swift" (value: u32) -> u32 { return reply.identity_uint32(value) }
@(export)
identity_f32 :: proc "swift" (value: f32) -> f32 { return reply.identity_float(value) }

@(export)
edit_buffer :: proc "swift" (values: []i16, flags: []bool) {
	for &v in values { v += 1 }
	for &v in flags { v = !v }
}

@(export)
measure_pair :: proc "swift" (index: i64, weight: f64) -> (last_index: i64, total_weight: f64) {
	return reply.measure(index, weight)
}

@(export)
word_components :: proc "swift" (x: u64, y: f64, z: int, w: f64) -> (u64, f64, int, f64) {
	return x, y, z, w
}

@(export)
text_edges :: proc "swift" (text: string) -> int {
	if len(text) == 0 { return 0 }
	return len(text) + int(text[0]) + int(text[len(text)-1])
}

@(export, link_name="odin_same_utf8")
same_utf8 :: proc "swift" (a, b: string, expected: []u8) -> bool {
	return a == b && a == string(expected)
}

@(export)
packed_reply :: proc "swift" (x: i8, y: u16, truth: u8, w: f32) -> (code: i8, quantity: u16, enabled: bool, weight: f32) {
	code, quantity, _, weight = reply.packed_reply(x, y, false, w)
	enabled = transmute(bool)truth
	return
}

@(export)
wide_reply :: proc "swift" (x: i16, raw: u8) -> (bits: u16, weight: f64, low: i64, active: bool, high: u64, tail: i16) {
	bits, weight, low, _, high, tail = reply.wide_reply(x)
	active = transmute(bool)raw
	return
}

@(export)
packed_bytes :: proc "swift" (value: u8) -> (u8, bool, u8, u8, u8) {
	return value, value != 0, 0xfe, 0x41, value+1
}

@(export)
read_checked :: proc "swift" (n: u64) -> (u64, u64, u64, u64, bool) {
	context = runtime.default_context()
	a, b, c, d, ready, err := reply.checked_reading(n)
	defer reply.Call_Error_destroy(err)
	if err != nil { assert(err.(reply.ReadingError) == .Missing) }
	return a, b, c, d, ready
}
