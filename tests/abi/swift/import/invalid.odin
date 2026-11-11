package invalid_swift_import

import "base:intrinsics"

bad :: proc() {
	data: int
	callback :: proc(data: ^int, value: u64) {}
	wrong_data :: proc(data: ^u64, value: u64) {}
	wrong_result :: proc(data: ^int, value: string) {}
	foreign_callback :: proc "c" (data: ^int, value: u64) {}
	_ = intrinsics.swift_async_call("not_a_swift_symbol", &data, callback)
	_ = intrinsics.swift_async_call("$sInvalid", "borrowed string", callback)
	_ = intrinsics.swift_async_call("$sInvalid", &data, wrong_data)
	_ = intrinsics.swift_async_call("$sInvalid", &data, wrong_result)
	_ = intrinsics.swift_async_call("$sInvalid", &data, foreign_callback)
	_ = intrinsics.swift_async_call("$sInvalid", &data, callback, "invalid argument")
}

contextless :: proc "contextless" () {
	data: int
	callback :: proc(data: ^int) {}
	_ = intrinsics.swift_async_call("$sInvalid", &data, callback)
}

bad_record :: proc() {
	Borrowed :: struct { text: string }
	callback :: proc(data: Borrowed) {}
	_ = intrinsics.swift_async_call("$sInvalid", Borrowed{}, callback)
}

bad_alignment :: proc() {
	Aligned :: struct #align(16) { value: u64 }
	callback :: proc(data: Aligned) {}
	_ = intrinsics.swift_async_call("$sInvalid", Aligned{}, callback)
}

bad_receiver :: proc() {
	callback :: proc(data: u64) {}
	_ = intrinsics.swift_async_method_call("$sInvalid", u64(1), callback, u64(2))
}
