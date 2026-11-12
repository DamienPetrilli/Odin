package invalid_swift_import

import "base:intrinsics"
import swift "core:sys/darwin/Swift"

bad :: proc() {
	callback :: proc(task: swift.Task, value: u64) {}
	wrong_task :: proc(task: u64, value: u64) {}
	wrong_result :: proc(task: swift.Task, value: string) {}
	foreign_callback :: proc "c" (task: swift.Task, value: u64) {}
	_ = intrinsics.swift_async_call("not_a_swift_symbol", callback)
	_ = intrinsics.swift_async_call("$sInvalid", wrong_task)
	_ = intrinsics.swift_async_call("$sInvalid", wrong_result)
	_ = intrinsics.swift_async_call("$sInvalid", foreign_callback)
	_ = intrinsics.swift_async_call("$sInvalid", callback, "invalid argument")
	_ = intrinsics.swift_async_method_call("$sInvalid", callback, u64(2))
}

contextless :: proc "contextless" () {
	callback :: proc(task: swift.Task) {}
	_ = intrinsics.swift_async_call("$sInvalid", callback)
}
