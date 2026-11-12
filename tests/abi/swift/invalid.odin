package swift_abi

Nested :: struct {
	reading: struct {page: i64, progress: f64},
	flag:    u64,
}

Packed :: struct #packed {
	page:     i64,
	progress: f64,
}

Empty :: struct {}
Narrow :: struct {code: u32, flags: u32}
Byte_First :: struct {tag: u8, value: u64}
Byte_Pair :: struct {value: u64, a, b: u8}
Byte :: struct {tag: u8}
Indirect_Byte :: struct {a, b, c, d: u64, tag: u8}

Nested_Arg :: proc "swift" (value: Nested)
Packed_Arg :: proc "swift" (value: Packed)
Empty_Arg :: proc "swift" (value: Empty)
Narrow_Arg :: proc "swift" (value: Narrow)
Leading_Byte :: proc "swift" (value: Byte_First)
Multiple_Bytes :: proc "swift" (value: Byte_Pair)
Byte_Only :: proc "swift" (value: Byte)
Indirect_Tag :: proc "swift" (value: Indirect_Byte)
Indirect_Tag_Result :: proc "swift" () -> Indirect_Byte
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

Missing_Async_Context :: proc "swift/async" (value: rawptr)
Bad_Async_Context :: proc "swift/async" (#swift_async value: u64)
Unexpected_Async_Context :: proc "swift" (#swift_async value: rawptr)
Bad_Indirect_Result :: proc "swift" (arg: u64, #swift_result result: rawptr)
Swift_Receiver :: proc "swift" (#swift_self receiver: rawptr)

check_swift_register_assignment :: proc(f: Swift_Receiver) {
	plain: proc "swift" (receiver: rawptr) = f
	_ = plain
}

check_swift_async_call :: proc(f: proc "swift/async" (#swift_async ctx: rawptr)) {
	f(nil)
}
