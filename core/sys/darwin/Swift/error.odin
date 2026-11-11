#+build darwin, arm64
package darwin_Swift

// An owned Swift error box. Nil means success. A throwing async completion
// receives one reference and must release it, or transfer it to longer-lived
// storage. Copying the address does not retain another reference.
Error :: distinct rawptr

@(private)
foreign {
	@(link_name="swift_errorRetain")
	error_retain_native :: proc "c" (error: Error) -> Error ---
	@(link_name="swift_errorRelease")
	error_release_native :: proc "c" (error: Error) ---
}

@(require_results)
error_retain :: proc(error: Error) -> Error {
	if error == nil {
		return nil
	}
	return error_retain_native(error)
}

error_release :: proc(error: Error) {
	if error != nil {
		error_release_native(error)
	}
}
