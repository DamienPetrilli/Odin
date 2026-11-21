// Plain frozen records have native Odin fields only after inspection proves
// every field's offset, total size, alignment and direct ABI components.
// Other records keep their metadata-driven, explicitly owned representation.

gb_internal void swift_import_struct_fields(SwiftImportNominal *type, JsonValue *graph, Array<SwiftImportNominal *> *types) {
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
		if (!symbol || swift_import_availability_rejection(symbol).len) return;
		for (auto attribute : swift_import_array(field, "declAttributes")) {
			if (attribute->kind != Json_String || (attribute->string != "HasStorage" && attribute->string != "Available")) return;
		}
		auto children = swift_import_array(field, "children");
		SwiftImportField item = {};
		item.swift_name = swift_import_string(field, "name");
		if (!swift_import_identifier(item.swift_name) || children.count != 1 ||
		    !swift_import_api_type(children[0], &item.type, types) || item.type.scalar_only ||
		    (item.type.nominal && !swift_import_kind(item.type, SwiftImportValue_String))) return;
		item.name = swift_import_name(item.swift_name, true);
		array_add(&type->fields, item);
	}
	for (auto const &field : type->fields) type->owns |= swift_import_owns(field.type);
	type->is_record = true;
}

gb_internal gbString swift_import_struct_probe(gbString source, SwiftImportNominal *type, isize index) {
	for_array(i, type->fields) {
		auto const &field = type->fields[i];
		source = gb_string_append_fmt(source, "@_silgen_name(\"odin_swift_import_field_%td_%td\")\npublic func field_%td_%td(", index, i, index, i);
		if (type->is_tuple) {
			// inout lets the field probe project the original storage. Loading the
			// entire tuple can introduce outlined copies of every String owner.
			source = gb_string_append_fmt(source, "_ value: inout %.*s) -> %s { value.%td }\n", LIT(type->swift_name), field.type.swift, i);
		} else {
			source = gb_string_append_fmt(source, "_ value: Swift.UnsafePointer<%.*s>) -> %s { value.pointee.`%.*s` }\n", LIT(type->swift_name), field.type.swift, LIT(field.swift_name));
		}
	}
	return gb_string_append_fmt(source,
		"@_silgen_name(\"odin_swift_import_stride_%td\")\npublic func stride_%td() -> Swift.Int { Swift.MemoryLayout<%.*s>.stride }\n",
		index, index, LIT(type->swift_name));
}

gb_internal void swift_import_struct_layout(LLVMModuleRef module, LLVMTargetDataRef data, SwiftImportNominal *type, isize index) {
	bool valid = swift_import_enum_layout(module, data, type, index);
	u64 size = 0, alignment = 1;
	for (auto &field : type->fields) {
		u64 bytes = swift_import_kind(field.type, SwiftImportValue_String) ? 16 : make_string_c(field.type.odin) == "bool" ? 1 : 8;
		u64 field_alignment = gb_min(bytes, u64(8));
		size = align_formula(size, field_alignment);
		field.offset = size;
		size += bytes;
		alignment = gb_max(alignment, field_alignment);
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
		if (swift_import_kind(type->fields[i].type, SwiftImportValue_String)) {
			// String returns its two frozen words and retains the object word.
			// Verify both loads from this field, not merely a 16-byte size.
			for (unsigned word = 0; word < 2; word++) {
				LLVMValueRef part = value;
				while (part && LLVMIsAInsertValueInst(part)) {
					if (LLVMGetNumIndices(part) != 1) break;
					if (LLVMGetIndices(part)[0] == word) { part = LLVMGetOperand(part, 1); break; }
					part = LLVMGetOperand(part, 0);
				}
				valid &= part && LLVMCountParams(function) == 1 && swift_import_component_load(data, part, function, type->fields[i].offset+word*8, 8);
			}
		} else valid &= value && LLVMCountParams(function) == 1 && swift_import_component_load(data, value, function, type->fields[i].offset, bytes);
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
		if (swift_import_kind(field.type, SwiftImportValue_String)) {
			if (component < type->components.count) valid &= make_string_c(type->components[component].llvm) == "i64";
			component++;
			llvm = "ptr";
		}
		if (component < type->components.count) valid &= make_string_c(type->components[component].llvm) == make_string_c(llvm);
		component++;
		i = next;
	}
	valid &= type->components.count == (component <= 4 ? component : 0);
	if (!valid) {
		type->is_record = false;
		type->owns = false;
		type->size = type->alignment = type->stride = 0;
		array_clear(&type->components);
		return;
	}
	type->projected = true;
}

// Capture spelling and attribute order differ between LLVM versions. Check
// indirect record promises through LLVM, then omit only those checked attributes
// from the inspection declaration. ABI attributes such as sret remain intact.
gb_internal bool swift_import_storage_parameter(LLVMValueRef function, unsigned index, u64 bytes, u64 align, bool result) {
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
	if (attribute && LLVMGetEnumAttributeValue(attribute) > align) return false;
	unsigned size = LLVMGetEnumAttributeKindForName("dereferenceable", 15);
	attribute = LLVMGetEnumAttributeAtIndex(function, position, size);
	if (result) {
		if (attribute && LLVMGetEnumAttributeValue(attribute) > bytes) return false;
	} else if (!attribute || LLVMGetEnumAttributeValue(attribute) != bytes) return false;
	LLVMRemoveEnumAttributeAtIndex(function, position, capture);
	LLVMRemoveEnumAttributeAtIndex(function, position, alignment);
	LLVMRemoveEnumAttributeAtIndex(function, position, size);
	return true;
}

gb_internal bool swift_import_struct_parameter(LLVMValueRef function, unsigned index, SwiftImportNominal *type, bool result) {
	return swift_import_storage_parameter(function, index, type->size, type->alignment, result);
}

gb_internal gbString swift_import_emit_owned_struct(gbString source, SwiftImportNominal *type);

gb_internal gbString swift_import_emit_struct(gbString source, SwiftImportNominal *type) {
	if (type->owns) return swift_import_emit_owned_struct(source, type);
	String name = type->name;
	source = gb_string_append_fmt(source, "%.*s :: struct {\n", LIT(name));
	for (auto const &field : type->fields) source = gb_string_append_fmt(source, "\t%.*s: %s,\n", LIT(field.name), field.type.odin);
	source = gb_string_append_fmt(source, "}\n#assert(size_of(%.*s) == %llu && align_of(%.*s) == %llu)\n", LIT(name), cast(unsigned long long)(type->size ? type->stride : 0), LIT(name), cast(unsigned long long)type->alignment);
	for (auto const &field : type->fields) source = gb_string_append_fmt(source, "#assert(offset_of(%.*s, %.*s) == %llu)\n", LIT(name), LIT(field.name), cast(unsigned long long)field.offset);
	source = gb_string_append_fmt(source, "@(private)\n_swift_native_%.*s :: %.*s\n", LIT(name), LIT(name));
	// A nested Swift payload can reuse tail padding. Only touch stored fields.
	source = gb_string_append_fmt(source, "@(private)\n_swift_%.*s_initialize :: proc(storage: rawptr, value: %.*s) -> bool {\n", LIT(name), LIT(name));
	if (type->fields.count) source = gb_string_append_fmt(source, "target := cast(^%.*s)storage\n", LIT(name));
	for (auto const &field : type->fields) {
		if (make_string_c(field.type.odin) == "bool") {
			source = gb_string_append_fmt(source, "(cast(^u8)&target.%.*s)^ = u8(value.%.*s)\n", LIT(field.name), LIT(field.name));
		} else {
			source = gb_string_append_fmt(source, "target.%.*s = value.%.*s\n", LIT(field.name), LIT(field.name));
		}
	}
	source = gb_string_appendc(source, "return true\n}\n");
	source = gb_string_append_fmt(source, "@(private)\n_swift_%.*s_take :: proc(storage: rawptr) -> (result: %.*s, ok: bool) #optional_ok {\n", LIT(name), LIT(name));
	if (type->fields.count) source = gb_string_append_fmt(source, "value := cast(^%.*s)storage\n", LIT(name));
	for (auto const &field : type->fields) source = gb_string_append_fmt(source, "result.%.*s = value.%.*s\n", LIT(field.name), LIT(field.name));
	return gb_string_appendc(source, "return result, true\n}\n\n");
}

// Public owned fields use Odin representations. Separate native temporary
// storage keeps Swift String bits and ARC out of those ordinary Odin fields.
gb_internal String swift_import_struct_address(SwiftImportField const &field) {
	return make_string_c(gb_string_append_fmt(gb_string_make(permanent_allocator(), ""),
		"rawptr(uintptr(storage)+%llu)", cast(unsigned long long)field.offset));
}

gb_internal gbString swift_import_emit_owned_struct(gbString source, SwiftImportNominal *type) {
	String name = type->name;
	if (type->is_tuple) source = gb_string_appendc(source, "@(private)\n");
	source = gb_string_append_fmt(source, "%.*s :: struct {\n", LIT(name));
	for (auto const &field : type->fields) source = gb_string_append_fmt(source, "\t%.*s: %s,\n", LIT(field.name), field.type.odin);
	source = gb_string_append_fmt(source, "}\n@(private)\n_swift_native_%.*s :: struct ", LIT(name));
	if (type->components.count) {
		source = gb_string_appendc(source, "{\n");
		for_array(i, type->components) source = gb_string_append_fmt(source, "\tr%td: %s,\n", i, type->components[i].odin);
	} else source = gb_string_append_fmt(source, "#align(%llu) {\n\tbytes: [%llu]u8,\n", cast(unsigned long long)type->alignment, cast(unsigned long long)type->size);
	if (!type->is_tuple) {
		source = gb_string_append_fmt(source, "}\n@(private)\n_swift_%.*s_initialize :: proc(storage: rawptr, value: %.*s) -> (ok: bool) {\n", LIT(name), LIT(name));
		for (auto const &field : type->fields) {
			String address = swift_import_struct_address(field);
			String value = concatenate_strings(permanent_allocator(), str_lit("value."), field.name);
			source = swift_import_emit_initialize_field(source, field.type, value, address);
			if (swift_import_native_owns(field.type)) source = gb_string_append_fmt(source, "defer if !ok { swift.value_deinitialize(%.*s, %.*s) }\n", LIT(address), LIT(swift_import_metadata(field.type)));
		}
		source = gb_string_appendc(source, "return true\n");
	}
	source = gb_string_append_fmt(source, "}\n@(private)\n_swift_%.*s_take :: proc(storage: rawptr) -> (result: %.*s, ok: bool) #optional_ok {\n", LIT(name), LIT(name));
	source = gb_string_appendc(source, "allocator := context.allocator\n");
	for_array(i, type->fields) {
		auto const &field = type->fields[i];
		String value = swift_import_field_value(i);
		source = swift_import_emit_take_field(source, field.type, value, swift_import_struct_address(field));
		if (field.type.nominal) {
			source = gb_string_append_fmt(source, "if !_ok_%.*s {\n", LIT(value));
			for (isize j = i+1; j < type->fields.count; j++) {
				auto const &remaining = type->fields[j];
				if (swift_import_native_owns(remaining.type)) source = gb_string_append_fmt(source, "swift.value_deinitialize(%.*s, %.*s)\n", LIT(swift_import_struct_address(remaining)), LIT(swift_import_metadata(remaining.type)));
			}
			source = gb_string_appendc(source, "return\n}\n");
		}
		if (swift_import_owns(field.type)) {
			source = gb_string_appendc(source, "defer if !ok {\n");
			source = swift_import_emit_destroy(source, field.type, value);
			source = gb_string_appendc(source, "}\n");
		}
	}
	source = gb_string_append_fmt(source, "return %.*s{", LIT(name));
	for_array(i, type->fields) source = gb_string_append_fmt(source, "%s_value%td", i ? ", " : "", i);
	source = gb_string_appendc(source, "}, true\n}\n");
	if (type->is_tuple) return source;
	source = gb_string_append_fmt(source, "%.*s_destroy :: proc(value: %.*s, allocator := context.allocator) {\n", LIT(name), LIT(name));
	for (auto const &field : type->fields) source = swift_import_emit_destroy(source, field.type, concatenate_strings(permanent_allocator(), str_lit("value."), field.name));
	source = gb_string_append_fmt(source, "}\n@(require_results)\n%.*s_copy :: proc(value: %.*s, allocator := context.allocator) -> (result: %.*s, ok: bool) #optional_ok {\ncontext.allocator = allocator\n", LIT(name), LIT(name), LIT(name));
	for_array(i, type->fields) {
		auto const &field = type->fields[i];
		String value = swift_import_field_value(i);
		source = swift_import_emit_copy_field(source, field.type, value, concatenate_strings(permanent_allocator(), str_lit("value."), field.name));
		if (swift_import_owns(field.type)) {
			source = gb_string_appendc(source, "defer if !ok {\n");
			source = swift_import_emit_destroy(source, field.type, value);
			source = gb_string_appendc(source, "}\n");
		}
	}
	source = gb_string_append_fmt(source, "return %.*s{", LIT(name));
	for_array(i, type->fields) source = gb_string_append_fmt(source, "%s_value%td", i ? ", " : "", i);
	return gb_string_appendc(source, "}, true\n}\n\n");
}
