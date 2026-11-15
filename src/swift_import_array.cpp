// Imported-value arrays share Swift's native storage operations. Element
// projections use the same explicit ownership rules as standalone values.

gb_internal String swift_import_array_from(SwiftImportNominal *type, String value) {
	gbString text = gb_string_make(permanent_allocator(), "");
	if (swift_import_value_slice(type)) text = gb_string_append_fmt(text, "_swift_%.*s_from(%.*s)", LIT(type->name), LIT(value));
	else text = gb_string_append_fmt(text, "swift.array_from_odin(%.*s)", LIT(value));
	return make_string_c(text);
}

gb_internal String swift_import_array_to(SwiftImportNominal *type, String value) {
	gbString text = gb_string_make(permanent_allocator(), "");
	if (swift_import_value_slice(type)) text = gb_string_append_fmt(text, "_swift_%.*s_to(%.*s)", LIT(type->name), LIT(value));
	else text = gb_string_append_fmt(text, "swift.array_to_odin(%.*s, %s)", LIT(value), swift_import_slice_element(type));
	return make_string_c(text);
}

gb_internal gbString swift_import_emit_array_cleanup(gbString source, SwiftImportType const &element) {
	source = gb_string_appendc(source, "defer if !ok {\n");
	if (swift_import_owns(element)) {
		source = gb_string_appendc(source, "for item in values[:initialized] {\n");
		source = swift_import_emit_destroy(source, element, str_lit("item"));
		source = gb_string_appendc(source, "}\n");
	}
	return gb_string_appendc(source, "delete(values, allocator)\n}\n");
}

gb_internal gbString swift_import_emit_array(gbString source, SwiftImportNominal *type) {
	String name = type->name;
	SwiftImportType element = swift_import_nominal_type(type->argument);
	String metadata = swift_import_metadata(element);
	source = gb_string_append_fmt(source, "%.*s :: []%s\n@(private)\n_swift_%.*s_cache: swift.Array_Value_Cache\n", LIT(name), element.odin, LIT(name));
	if (element.nominal->is_record) {
		source = gb_string_append_fmt(source, "@(private)\n_swift_%.*s_from :: proc(values: []%s) -> (result: swift.Native_Array, ok: bool) #optional_ok {\nreturn swift.array_from_trivial(values, %.*s, &_swift_%.*s_cache, %llu)\n}\n", LIT(name), element.odin, LIT(metadata), LIT(name), cast(unsigned long long)element.nominal->size);
		source = gb_string_append_fmt(source, "@(private)\n_swift_%.*s_to :: proc(value: swift.Native_Array) -> (result: []%s, ok: bool) #optional_ok {\nreturn swift.array_to_trivial(value, %.*s, &_swift_%.*s_cache, %s, %llu)\n}\n", LIT(name), element.odin, LIT(metadata), LIT(name), element.odin, cast(unsigned long long)element.nominal->size);
		source = gb_string_append_fmt(source, "%.*s_destroy :: proc(values: []%s, allocator := context.allocator) {\ndelete(values, allocator)\n}\n", LIT(name), element.odin);
		return gb_string_append_fmt(source, "@(require_results)\n%.*s_copy :: proc(value: []%s, allocator := context.allocator) -> (result: []%s, ok: bool) #optional_ok {\nvalues, err := non_zero_make([]%s, len(value), allocator)\nif err != nil { return }\ncopy(values, value)\nreturn values, true\n}\n\n", LIT(name), element.odin, element.odin, element.odin);
	}
	if (element.nominal->projected) {
		source = gb_string_append_fmt(source, "@(private)\n_swift_%.*s_initialize_element :: proc(storage: rawptr, value: %s) -> (ok: bool) {\n", LIT(name), element.odin);
		source = swift_import_emit_initialize_field(source, element, str_lit("value"), str_lit("storage"));
		source = gb_string_appendc(source, "return true\n}\n");
		source = gb_string_append_fmt(source, "@(private)\n_swift_%.*s_copy_element :: proc(value: %s, allocator: mem.Allocator) -> (result: %s, ok: bool) #optional_ok {\ncontext.allocator = allocator\n", LIT(name), element.odin, element.odin);
		source = swift_import_emit_copy_field(source, element, str_lit("item"), str_lit("value"));
		source = gb_string_appendc(source, "return item, true\n}\n");

		source = gb_string_append_fmt(source, "@(private)\n_swift_%.*s_from :: proc(values: []%s) -> (result: swift.Native_Array, ok: bool) #optional_ok {\nmetadata := %.*s\nbuffer := swift.array_value_allocate(len(values), metadata, &_swift_%.*s_cache) or_return\ninitialized := 0\ndefer if !ok { swift.array_value_abort(buffer, initialized, metadata) }\nfor item, index in values {\nif !_swift_%.*s_initialize_element(swift.array_value_element(buffer, index), item) { return }\ninitialized += 1\n}\nreturn buffer.value, true\n}\n", LIT(name), element.odin, LIT(metadata), LIT(name), LIT(name));
	} else {
		source = gb_string_append_fmt(source, "@(private)\n_swift_%.*s_from :: proc(values: []%s) -> (result: swift.Native_Array, ok: bool) #optional_ok {\nreturn swift.array_from_values(values, %.*s, &_swift_%.*s_cache)\n}\n", LIT(name), element.odin, LIT(metadata), LIT(name));
	}

	if (!element.nominal->projected) {
		source = gb_string_append_fmt(source, "@(private)\n_swift_%.*s_to :: proc(value: swift.Native_Array) -> (result: []%s, ok: bool) #optional_ok {\nreturn swift.array_take_values(value, %.*s, &_swift_%.*s_cache, %s)\n}\n", LIT(name), element.odin, LIT(metadata), LIT(name), element.odin);
	} else {
		source = gb_string_append_fmt(source, "@(private)\n_swift_%.*s_to :: proc(value: swift.Native_Array) -> (result: []%s, ok: bool) #optional_ok {\nmetadata := %.*s\nbuffer := swift.array_value_buffer(value, metadata, &_swift_%.*s_cache) or_return\nif buffer.count == 0 { return nil, true }\nallocator := context.allocator\nvalues, err := make([]%s, buffer.count, allocator)\nif err != nil || raw_data(values) == nil { return }\ninitialized := 0\n", LIT(name), element.odin, LIT(metadata), LIT(name), element.odin);
		source = swift_import_emit_array_cleanup(source, element);
		if (element.nominal->alignment) source = gb_string_append_fmt(source, "temporary: %s\nstorage := rawptr(&temporary)\n", swift_import_enum_native(element.nominal));
		else source = gb_string_appendc(source, "storage := swift.value_allocate(metadata) or_return\ndefer swift.value_free_uninitialized(storage)\n");
		source = gb_string_appendc(source, "for index in 0..<buffer.count {\naddress := swift.array_value_element(buffer, index)\n");
		source = gb_string_append_fmt(source, "swift.value_initialize_copy(storage, address, metadata)\nitem := _swift_%.*s_take(storage) or_return\n", LIT(element.nominal->name));
		source = gb_string_appendc(source, "values[index] = item\ninitialized += 1\n}\nreturn values, true\n}\n");
	}

	source = gb_string_append_fmt(source, "%.*s_destroy :: proc(values: []%s, allocator := context.allocator) {\n", LIT(name), element.odin);
	if (!element.nominal->projected) {
		source = gb_string_append_fmt(source, "swift.value_destroy_many(values, %.*s)\n", LIT(metadata));
	} else if (swift_import_owns(element)) {
		source = gb_string_appendc(source, "for item in values {\n");
		source = swift_import_emit_destroy(source, element, str_lit("item"));
		source = gb_string_appendc(source, "}\n");
	}
	source = gb_string_appendc(source, "delete(values, allocator)\n}\n");
	if (!element.nominal->projected) {
		return gb_string_append_fmt(source, "@(require_results)\n%.*s_copy :: proc(value: []%s, allocator := context.allocator) -> (result: []%s, ok: bool) #optional_ok {\nreturn swift.value_copy_many(value, %.*s, allocator)\n}\n\n", LIT(name), element.odin, element.odin, LIT(metadata));
	}
	source = gb_string_append_fmt(source, "@(require_results)\n%.*s_copy :: proc(value: []%s, allocator := context.allocator) -> (result: []%s, ok: bool) #optional_ok {\nif len(value) == 0 { return nil, true }\nvalues, err := make([]%s, len(value), allocator)\nif err != nil || raw_data(values) == nil { return }\ninitialized := 0\n", LIT(name), element.odin, element.odin, element.odin);
	source = swift_import_emit_array_cleanup(source, element);
	source = gb_string_append_fmt(source, "for item, index in value {\nvalues[index] = _swift_%.*s_copy_element(item, allocator) or_return\ninitialized += 1\n}\nreturn values, true\n}\n\n", LIT(name));
	return source;
}
