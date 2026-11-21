package export_fixture

// Construct a present value from a missing Swift input, and a missing value
// from a present input. A reverse tag error cannot cancel out on a round trip.
if_missing :: proc "contextless" (value: Maybe($T), fallback: T) -> Maybe(T) {
	if value == nil { return fallback }
	return nil
}

@(export)
missing_bool :: proc "swift" (value: Maybe(bool), fallback: bool) -> Maybe(bool) {
	return if_missing(value, fallback)
}

@(export)
missing_i8 :: proc "swift" (value: Maybe(i8), fallback: i8) -> Maybe(i8) {
	return if_missing(value, fallback)
}

@(export)
missing_u8 :: proc "swift" (value: Maybe(u8), fallback: u8) -> Maybe(u8) {
	return if_missing(value, fallback)
}

@(export)
missing_i16 :: proc "swift" (value: Maybe(i16), fallback: i16) -> Maybe(i16) {
	return if_missing(value, fallback)
}

@(export)
missing_u16 :: proc "swift" (value: Maybe(u16), fallback: u16) -> Maybe(u16) {
	return if_missing(value, fallback)
}

@(export)
missing_i32 :: proc "swift" (value: Maybe(i32), fallback: i32) -> Maybe(i32) {
	return if_missing(value, fallback)
}

@(export)
missing_u32 :: proc "swift" (value: Maybe(u32), fallback: u32) -> Maybe(u32) {
	return if_missing(value, fallback)
}

@(export)
missing_i64 :: proc "swift" (value: Maybe(i64), fallback: i64) -> Maybe(i64) {
	return if_missing(value, fallback)
}

@(export)
missing_u64 :: proc "swift" (value: Maybe(u64), fallback: u64) -> Maybe(u64) {
	return if_missing(value, fallback)
}

@(export)
missing_int :: proc "swift" (value: Maybe(int), fallback: int) -> Maybe(int) {
	return if_missing(value, fallback)
}

@(export)
missing_uint :: proc "swift" (value: Maybe(uint), fallback: uint) -> Maybe(uint) {
	return if_missing(value, fallback)
}

@(export)
missing_f32 :: proc "swift" (value: Maybe(f32), fallback: f32) -> Maybe(f32) {
	return if_missing(value, fallback)
}

@(export)
missing_f64 :: proc "swift" (value: Maybe(f64), fallback: f64) -> Maybe(f64) {
	return if_missing(value, fallback)
}

@(export)
select_optional :: proc "swift" (a, b: Maybe(f64), first: bool) -> Maybe(f64) {
	if first { return a }
	return b
}

@(export)
select_optional_byte :: proc "swift" (a, b: Maybe(u8), first: bool) -> Maybe(u8) {
	if first { return a }
	return b
}

@(export)
local_optional :: proc "swift" (input: Maybe(u64), seed: u64, first: bool) -> Maybe(u64) {
	if first { return input }
	// A locally formed nil can have a valid tag and a stale payload.
	storage := [2]u64{seed, 0}
	return transmute(Maybe(u64))storage
}
