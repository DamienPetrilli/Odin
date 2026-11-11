package swift_abi

Nested :: struct {
	reading: struct {page: i64, progress: f64},
	flag:    u8,
}

Packed :: struct #packed {
	page:     i64,
	progress: f64,
}

Nested_Parameter :: proc "swift" (value: Nested)
Packed_Parameter :: proc "swift" (value: Packed)
Slice_Parameter :: proc "swift" (value: []u8)
By_Ptr_Parameter :: proc "swift" (#by_ptr value: i64)
String_Result :: proc "swift" () -> string
Variadic_Parameter :: proc "swift" (value: ..i64)
Multiple_Results :: proc "swift" () -> (i64, f64)
Odin_Callback :: proc "swift" (f: proc ())
C_Callback :: proc "swift" (f: proc "c" ())
C_Callback_Result :: proc "swift" () -> proc "c" ()

c_scalar :: proc "c" (value: i64) -> i64 {
	return value
}

check_assignment :: proc() {
	f: proc "swift" (value: i64) -> i64 = c_scalar
	_ = f
}
