// Inspect an untyped Swift Error without consuming its owner. Copy native data
// before the existing consuming projection; returned Odin payloads own their data.
gb_internal gbString swift_import_emit_error(gbString source, SwiftImportNominal *type) {
	String name = type->name;
	source = gb_string_append_fmt(source,
		"// Borrows error. A nil err returns an independently owned concrete value.\n"
		"@(require_results)\n%.*s_from_error :: proc(error: swift.Error) -> (value: %.*s, err: swift.Error_Cast_Error) {\n"
		"\tmetadata := _swift_%.*s_metadata(0).type\n\tscratch: rawptr\n"
		"\tnative_value := swift.error_value(error, metadata, &scratch)\n\tif native_value == nil { return value, .Type_Mismatch }\n",
		LIT(name), LIT(name), LIT(name));
	if (type->alignment) {
		source = gb_string_append_fmt(source, "\tnative: %s = ---\n\tstorage := rawptr(&native)\n", swift_import_enum_native(type));
	} else {
		source = gb_string_appendc(source, "\ttemporary: swift.Value_Temporary = ---\n\tlayout := swift.value_layout(metadata)\n"
			"\tstorage, allocated := swift.value_temporary_from_layout(&temporary, layout)\n"
			"\tif !allocated { return value, .Conversion_Failed }\n"
			"\tdefer swift.value_temporary_free(&temporary, storage)\n");
	}
	source = gb_string_append_fmt(source,
		"\tswift.value_initialize_copy(storage, native_value, metadata)\n"
		"\tconverted, ok := _swift_%.*s_take(storage)\n\tif !ok { return value, .Conversion_Failed }\n"
		"\treturn converted, nil\n}\n\n", LIT(name));
	return source;
}

// The thrown type is not part of an untyped throws signature. Keep the imported
// concrete alternatives together, and preserve every other error as an owner.
gb_internal gbString swift_import_emit_async_error(gbString source, Array<SwiftImportNominal *> const &types) {
	source = gb_string_appendc(source, "// Nil means success. The callback owns this value; assignment does not copy its owners.\nAsync_Error :: union {\n");
	for (auto type : types) {
		if (type->supported && type->is_error && type->projected) source = gb_string_append_fmt(source, "\t%.*s,\n", LIT(type->name));
	}
	source = gb_string_appendc(source,
		"\tswift.Unknown_Error,\n\tswift.Error_Conversion_Failed,\n\tswift.Result_Conversion_Failed,\n}\n\n"
		"Async_Error_destroy :: proc(error: Async_Error, allocator := context.allocator) {\n\tswitch item in error {\n\tcase nil:\n");
	for (auto type : types) {
		if (!type->supported || !type->is_error || !type->projected) continue;
		source = gb_string_append_fmt(source, "\tcase %.*s:\n", LIT(type->name));
		source = swift_import_emit_destroy(source, swift_import_nominal_type(type), str_lit("item"));
	}
	source = gb_string_appendc(source,
		"\tcase swift.Unknown_Error:\n\t\tswift.error_release(item.error)\n"
		"\tcase swift.Error_Conversion_Failed:\n\t\tswift.error_release(item.error)\n"
		"\tcase swift.Result_Conversion_Failed:\n\t}\n}\n\n"
		"@(require_results)\nAsync_Error_copy :: proc(error: Async_Error, allocator := context.allocator) -> (value: Async_Error, ok: bool) #optional_ok {\n"
		"\tcontext.allocator = allocator\n\tswitch item in error {\n\tcase nil:\n\t\treturn nil, true\n");
	for (auto type : types) {
		if (!type->supported || !type->is_error || !type->projected) continue;
		source = gb_string_append_fmt(source, "\tcase %.*s:\n", LIT(type->name));
		source = swift_import_emit_copy_field(source, swift_import_nominal_type(type), str_lit("copied"), str_lit("item"));
		source = gb_string_appendc(source, "\t\treturn copied, true\n");
	}
	source = gb_string_appendc(source,
		"\tcase swift.Unknown_Error:\n\t\tif item.error == nil { return }\n\t\treturn swift.Unknown_Error{swift.error_retain(item.error)}, true\n"
		"\tcase swift.Error_Conversion_Failed:\n\t\tif item.error == nil { return }\n\t\treturn swift.Error_Conversion_Failed{swift.error_retain(item.error)}, true\n"
		"\tcase swift.Result_Conversion_Failed:\n\t\treturn item, true\n\t}\n\treturn\n}\n\n"
		"// Consumes the native owner. Projection failure transfers it intact to the callback.\n"
		"@(private)\n_swift_async_error_take :: proc(error: swift.Error) -> Async_Error {\n\tif error == nil { return nil }\n");
	bool has_concrete = false;
	for (auto type : types) has_concrete |= type->supported && type->is_error && type->projected;
	if (has_concrete) {
		source = gb_string_appendc(source, "\tmetadata := swift.error_metadata(error)\n");
		for (auto type : types) {
			if (!type->supported || !type->is_error || !type->projected) continue;
			source = gb_string_append_fmt(source,
				"\tif metadata == _swift_%.*s_metadata(0).type {\n"
				"\t\tvalue, err := %.*s_from_error(error)\n"
				"\t\tif err != nil { return swift.Error_Conversion_Failed{error} }\n"
				"\t\tswift.error_release(error)\n\t\treturn value\n\t}\n", LIT(type->name), LIT(type->name));
		}
	}
	return gb_string_appendc(source, "\treturn swift.Unknown_Error{error}\n}\n\n");
}
