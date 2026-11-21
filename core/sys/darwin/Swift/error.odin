#+build darwin, arm64
package darwin_Swift

// An owned Swift error box. Nil means no native error. Imported throwing calls
// project it to their module's Call_Error union. Unknown or unconverted errors
// keep this owner; copying the address does not retain another reference.
Error :: distinct rawptr

// Fallback cases in an imported module's Call_Error union. Its generated
// copy/destroy procedures manage these owners along with concrete payloads.
Unknown_Error :: struct {
	error: Error, // Owned error whose concrete type is not mapped by this module.
}

Error_Conversion_Failed :: struct {
	error: Error, // Owned matching error whose Odin projection could not be copied.
}

// Swift returned successfully, but copying its result to Odin failed.
Result_Conversion_Failed :: struct {}

// Status of copying a concrete Odin value out of a Swift error. This describes
// inspection, not the operation which threw. Only None makes the output valid.
// The input error is borrowed and remains usable after every outcome.
Error_Cast_Error :: enum {
	None,
	Type_Mismatch, // Nil or a different concrete Swift error type.
	Conversion_Failed, // Matching type, but its independent copy could not be made.
}

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

@(private)
Error_Value :: struct {
	value, metadata, witness: rawptr,
}

@(private)
error_metadata_cache: rawptr

@(private)
foreign {
	// Swift runtime ErrorValueResult. Scratch handles a bridged object without
	// assuming that the error box contains a native Swift payload.
	@(link_name="swift_getErrorValue")
	error_get_value :: proc "c" (error: Error, scratch: ^rawptr, result: ^Error_Value) ---
	@(link_name="swift_getDynamicType")
	error_dynamic_type :: proc "c" (value, metadata: rawptr, existential: bool) -> rawptr ---
	@(link_name="$ss9_typeName_9qualifiedSSypXp_SbtF")
	error_type_name_native :: proc "swift" (metadata: rawptr, qualified: bool) -> Native_String ---
	@(link_name="$sSS10describingSSx_tclufC")
	error_description_native :: proc "swift" (value: rawptr, metadata: rawptr) -> Native_String ---
}

// Return an independently owned Odin string; release it with delete. The error
// is borrowed for this call and remains the caller's responsibility. This name
// is diagnostic text, not a persistent identifier or an error code.
@(require_results)
error_type_name :: proc(error: Error, qualified := true) -> (result: string, ok: bool) #optional_ok {
	if error == nil { return }
	scratch: rawptr
	value: Error_Value
	error_get_value(error, &scratch, &value)
	metadata := error_dynamic_type(value.value, value.metadata, true)
	native := error_type_name_native(metadata, qualified)
	defer string_destroy(&native)
	return string_to_odin(native)
}

// Equivalent to Swift String(describing: error), including custom descriptions.
// This is diagnostic text, not a localized user message or a stable error code.
// Nil and Odin allocation failure return false without consuming the error.
@(require_results)
error_description :: proc(error: Error) -> (result: string, ok: bool) #optional_ok {
	if error == nil { return }
	metadata := metadata_from_name_cached(&error_metadata_cache, "s5Error_p")
	if metadata == nil { return }
	// String's generic initializer consumes its argument. Give it a retained
	// Error existential, keeping the caller's reference unchanged.
	owned := error_retain(error)
	native := error_description_native(&owned, metadata)
	defer string_destroy(&native)
	return string_to_odin(native)
}

// Borrow a concrete error value with exactly the requested complete metadata.
// Keep both the error and caller-owned scratch word alive while using the result.
// A bridged object may reside in scratch; never return a pointer to local scratch.
// Nil and a different native type do not consume the error or allocate storage.
error_value :: proc(error: Error, metadata: rawptr, scratch: ^rawptr) -> rawptr {
	if error == nil || metadata == nil || scratch == nil { return nil }
	value: Error_Value
	error_get_value(error, scratch, &value)
	if value.metadata != metadata { return nil }
	return value.value
}

// Complete concrete metadata for exact identity checks. No borrowed payload
// address escapes this call; bridged-object scratch remains local.
error_metadata :: proc(error: Error) -> rawptr {
	if error == nil { return nil }
	scratch: rawptr
	value: Error_Value
	error_get_value(error, &scratch, &value)
	return value.metadata
}
