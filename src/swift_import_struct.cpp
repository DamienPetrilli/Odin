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
	return gb_string_append_fmt(source,
		"@_silgen_name(\"odin_swift_import_stride_%td\")\npublic func stride_%td() -> Swift.Int { Swift.MemoryLayout<%.*s>.stride }\n",
		index, index, LIT(type->swift_name));
}

gb_internal void swift_import_struct_layout(LLVMModuleRef module, LLVMTargetDataRef data, SwiftImportNominal *type, isize index) {
	bool valid = swift_import_enum_layout(module, data, type, index);
	u64 size = 0, alignment = 1;
	for (auto &field : type->fields) {
		u64 bytes = make_string_c(field.type.odin) == "bool" ? 1 : 8;
		size = align_formula(size, bytes);
		field.offset = size;
		size += bytes;
		alignment = gb_max(alignment, bytes);
	}
	valid &= type->size == size && type->alignment == alignment;
	gbString stride_name = gb_string_append_fmt(gb_string_make(temporary_allocator(), ""), "odin_swift_import_stride_%td", index);
	LLVMValueRef stride_function = LLVMGetNamedFunction(module, stride_name);
	LLVMValueRef stride = stride_function ? swift_import_return(stride_function) : nullptr;
	type->stride = gb_max(u64(1), align_formula(size, alignment));
	valid &= stride && LLVMIsAConstantInt(stride) && LLVMConstIntGetZExtValue(stride) == type->stride;
	for_array(i, type->fields) {
		gbString name = gb_string_append_fmt(gb_string_make(temporary_allocator(), ""), "odin_swift_import_field_%td_%td", index, i);
		LLVMValueRef function = LLVMGetNamedFunction(module, name);
		LLVMValueRef value = function ? swift_import_return(function) : nullptr;
		u64 bytes = make_string_c(type->fields[i].type.odin) == "bool" ? 1 : 8;
		valid &= value && LLVMCountParams(function) == 1 && swift_import_component_load(data, value, function, type->fields[i].offset, bytes);
	}
	// The backend gathers adjacent Bool bytes into one integer component.
	// Prove that classification too; matching offsets alone is insufficient.
	isize component = 0;
	for (isize i = 0; i < type->fields.count;) {
		auto const &field = type->fields[i];
		char const *llvm = field.type.llvm;
		isize next = i+1;
		if (make_string_c(field.type.odin) == "bool") {
			while (next < type->fields.count && make_string_c(type->fields[next].type.odin) == "bool" &&
			       type->fields[next].offset/8 == field.offset/8) next++;
			isize bytes = next-i;
			llvm = bytes == 1 ? "i1" : bytes <= 2 ? "i16" : bytes <= 4 ? "i32" : "i64";
		}
		if (component < type->components.count) valid &= make_string_c(type->components[component].llvm) == make_string_c(llvm);
		component++;
		i = next;
	}
	valid &= type->components.count == (component <= 4 ? component : 0);
	if (!valid) {
		type->is_record = false;
		type->size = type->alignment = type->stride = 0;
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
	LLVMAttributeRef attribute = capture ? LLVMGetEnumAttributeAtIndex(function, position, capture) : nullptr;
	if (!attribute) {
		capture = LLVMGetEnumAttributeKindForName("nocapture", 9);
		attribute = capture ? LLVMGetEnumAttributeAtIndex(function, position, capture) : nullptr;
	}
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
	source = gb_string_append_fmt(source, "}\n#assert(size_of(%.*s) == %llu && align_of(%.*s) == %llu)\n", LIT(name), cast(unsigned long long)(type->size ? type->stride : 0), LIT(name), cast(unsigned long long)type->alignment);
	for (auto const &field : type->fields) source = gb_string_append_fmt(source, "#assert(offset_of(%.*s, %.*s) == %llu)\n", LIT(name), LIT(field.name), cast(unsigned long long)field.offset);
	source = gb_string_append_fmt(source, "@(private)\n_swift_native_%.*s :: %.*s\n", LIT(name), LIT(name));
	// A nested Swift payload can reuse tail padding. Only touch stored fields.
	source = gb_string_append_fmt(source, "@(private)\n_swift_%.*s_initialize :: proc(storage: rawptr, value: %.*s) -> bool {\n", LIT(name), LIT(name));
	if (type->fields.count) source = gb_string_append_fmt(source, "target := cast(^%.*s)storage\n", LIT(name));
	for (auto const &field : type->fields) source = gb_string_append_fmt(source, "target.%.*s = value.%.*s\n", LIT(field.name), LIT(field.name));
	source = gb_string_appendc(source, "return true\n}\n");
	source = gb_string_append_fmt(source, "@(private)\n_swift_%.*s_take :: proc(storage: rawptr) -> (result: %.*s, ok: bool) #optional_ok {\n", LIT(name), LIT(name));
	if (type->fields.count) source = gb_string_append_fmt(source, "value := cast(^%.*s)storage\n", LIT(name));
	for (auto const &field : type->fields) source = gb_string_append_fmt(source, "result.%.*s = value.%.*s\n", LIT(field.name), LIT(field.name));
	return gb_string_appendc(source, "return result, true\n}\n\n");
}
