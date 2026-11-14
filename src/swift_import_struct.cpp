// Plain frozen records have native Odin fields only after inspection proves
// every field's offset, total size, alignment and direct ABI components.
// Other records keep their metadata-driven, explicitly owned representation.

gb_internal void swift_import_struct_fields(SwiftImportNominal *type, JsonValue *graph, Array<SwiftImportNominal *> const &types) {
	if (!type->is_frozen || type->is_enum || type->is_template || type->argument || type->is_scalar || !type->declaration) return;
	for (auto attribute : swift_import_array(type->declaration, "declAttributes")) {
		if (attribute->kind != Json_String || (attribute->string != "Frozen" && attribute->string != "Available")) return;
	}
	array_init(&type->fields, permanent_allocator());
	for (auto field : swift_import_array(type->declaration, "children")) {
		if (swift_import_string(field, "kind") != "Var" || swift_import_member(field, "static")) continue;
		auto stored = swift_import_member(field, "hasStorage");
		if (!stored || stored->kind != Json_Boolean || !stored->boolean) continue;
		String usr = swift_import_string(field, "usr");
		JsonValue *symbol = nullptr;
		for (auto candidate : swift_import_array(graph, "symbols")) {
			if (swift_import_string(swift_import_member(candidate, "identifier"), "precise") == usr) { symbol = candidate; break; }
		}
		if (!symbol || !swift_import_available(symbol)) return;
		for (auto attribute : swift_import_array(field, "declAttributes")) {
			if (attribute->kind != Json_String || (attribute->string != "HasStorage" && attribute->string != "Available")) return;
		}
		auto children = swift_import_array(field, "children");
		SwiftImportField item = {};
		item.swift_name = swift_import_string(field, "name");
		if (!swift_import_identifier(item.swift_name) || children.count != 1 ||
		    !swift_import_named_type(swift_import_string(children[0], "usr"), &item.type, types) || item.type.nominal) return;
		item.name = swift_import_name(item.swift_name, true);
		array_add(&type->fields, item);
	}
	type->is_record = true;
}

gb_internal gbString swift_import_struct_probe(gbString source, SwiftImportNominal *type, isize index) {
	for_array(i, type->fields) {
		auto const &field = type->fields[i];
		source = gb_string_append_fmt(source,
			"@_silgen_name(\"odin_swift_import_field_%td_%td\")\npublic func field_%td_%td(_ value: Swift.UnsafePointer<%.*s>) -> %s { value.pointee.`%.*s` }\n",
			index, i, index, i, LIT(type->swift_name), field.type.swift, LIT(field.swift_name));
	}
	return source;
}

gb_internal void swift_import_struct_layout(LLVMModuleRef module, LLVMTargetDataRef data, SwiftImportNominal *type, isize index) {
	bool valid = swift_import_enum_layout(module, data, type, index);
	valid &= type->size == cast(u64)type->fields.count*8 && type->alignment == (type->fields.count ? 8 : 1);
	for_array(i, type->fields) {
		gbString name = gb_string_append_fmt(gb_string_make(temporary_allocator(), ""), "odin_swift_import_field_%td_%td", index, i);
		LLVMValueRef function = LLVMGetNamedFunction(module, name);
		LLVMValueRef value = function ? swift_import_return(function) : nullptr;
		valid &= value && LLVMCountParams(function) == 1 && swift_import_component_load(data, value, function, cast(u64)i*8, 8);
	}
	if (!valid) {
		type->is_record = false;
		type->size = type->alignment = 0;
		array_clear(&type->components);
		return;
	}
	type->projected = true;
}

// Capture spelling and attribute order differ between LLVM versions. Check
// indirect record promises through LLVM, then omit only those checked attributes
// from the inspection declaration. ABI attributes such as sret remain intact.
gb_internal bool swift_import_struct_parameter(LLVMValueRef function, unsigned index, SwiftImportNominal *type, bool result) {
	if (!function || index >= LLVMCountParams(function)) return false;
	unsigned position = index+1;
	unsigned capture = LLVMGetEnumAttributeKindForName("captures", 8);
	if (!capture) capture = LLVMGetEnumAttributeKindForName("nocapture", 9);
	LLVMAttributeRef attribute = LLVMGetEnumAttributeAtIndex(function, position, capture);
	if (!attribute || LLVMGetEnumAttributeValue(attribute) != 0) return false;
	unsigned alignment = LLVMGetEnumAttributeKindForName("align", 5);
	attribute = LLVMGetEnumAttributeAtIndex(function, position, alignment);
	if (attribute && LLVMGetEnumAttributeValue(attribute) > type->alignment) return false;
	unsigned size = LLVMGetEnumAttributeKindForName("dereferenceable", 15);
	attribute = LLVMGetEnumAttributeAtIndex(function, position, size);
	if (result) {
		if (attribute && LLVMGetEnumAttributeValue(attribute) > type->size) return false;
	} else if (!attribute || LLVMGetEnumAttributeValue(attribute) != type->size) return false;
	LLVMRemoveEnumAttributeAtIndex(function, position, capture);
	LLVMRemoveEnumAttributeAtIndex(function, position, alignment);
	LLVMRemoveEnumAttributeAtIndex(function, position, size);
	return true;
}

gb_internal gbString swift_import_emit_struct(gbString source, SwiftImportNominal *type) {
	String name = type->name;
	source = gb_string_append_fmt(source, "%.*s :: struct {\n", LIT(name));
	for (auto const &field : type->fields) source = gb_string_append_fmt(source, "\t%.*s: %s,\n", LIT(field.name), field.type.odin);
	source = gb_string_append_fmt(source, "}\n#assert(size_of(%.*s) == %llu && align_of(%.*s) == %llu)\n", LIT(name), cast(unsigned long long)type->size, LIT(name), cast(unsigned long long)type->alignment);
	source = gb_string_append_fmt(source, "@(private)\n_swift_native_%.*s :: %.*s\n", LIT(name), LIT(name));
	source = gb_string_append_fmt(source, "@(private)\n_swift_%.*s_initialize :: proc(storage: rawptr, value: %.*s) -> bool {\n(cast(^%.*s)storage)^ = value\nreturn true\n}\n", LIT(name), LIT(name), LIT(name));
	return gb_string_append_fmt(source, "@(private)\n_swift_%.*s_take :: proc(storage: rawptr) -> (result: %.*s, ok: bool) #optional_ok {\nreturn (cast(^%.*s)storage)^, true\n}\n\n", LIT(name), LIT(name), LIT(name));
}
