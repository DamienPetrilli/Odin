gb_internal String swift_import_array_from(SwiftImportNominal *type, String value);
gb_internal String swift_import_array_to(SwiftImportNominal *type, String value);

// Native enums are projected into Odin values, not reinterpreted as Odin unions.
// All layout probes are inspection-only; no Swift adapter is linked.

gb_internal bool swift_import_projected(SwiftImportType const &type) {
	return type.nominal && type.nominal->projected;
}

gb_internal bool swift_import_plain_enum(SwiftImportNominal *type) {
	if (!type || !type->is_enum || !type->is_frozen || type->is_optional || type->cases.count == 0) return false;
	for (auto const &c : type->cases) if (c.has_payload) return false;
	return true;
}

// A single no-payload case has no native storage or register component. Keep
// its Odin value in the public signature, but omit it from the native call.
gb_internal bool swift_import_empty(SwiftImportType const &type) {
	return type.nominal && type.nominal->projected && type.nominal->alignment && type.nominal->size == 0;
}

gb_internal bool swift_import_indirect(SwiftImportType const &type) {
	return swift_import_kind(type, SwiftImportValue_Opaque) && !swift_import_empty(type) &&
	       !type.nominal->is_scalar && (!type.nominal->projected || type.nominal->components.count == 0);
}

gb_internal bool swift_import_owns(SwiftImportType const &type) {
	return type.nominal && !type.nominal->is_scalar && (!type.nominal->projected || type.nominal->owns);
}

// A native resilient value can require destruction even when its Odin
// projection is an unowned scalar (for example Foundation.Date).
gb_internal bool swift_import_native_owns(SwiftImportType const &type) {
	return swift_import_owns(type) || (swift_import_projected(type) && !type.nominal->alignment);
}

gb_internal String swift_import_metadata(SwiftImportType const &type) {
	if (type.nominal && !type.nominal->is_scalar) {
		return make_string_c(gb_string_append_fmt(gb_string_make(permanent_allocator(), ""), "_swift_%.*s_metadata(0).type", LIT(type.nominal->name)));
	}
	return make_string_c(gb_string_append_fmt(gb_string_make(permanent_allocator(), ""), "swift.value_metadata(%s)", type.odin));
}

gb_internal String swift_import_case_member(SwiftImportCase const &c) {
	String name = copy_string(permanent_allocator(), c.name);
	name.text[0] = gb_char_to_upper(name[0]);
	return name;
}

gb_internal String swift_import_case_name(SwiftImportNominal *type, SwiftImportCase const &c) {
	return concatenate3_strings(permanent_allocator(), type->name, str_lit("_"), swift_import_case_member(c));
}

// Only accept direct components whose storage offsets are demonstrated by a
// load probe. A register tuple alone is not evidence of the memory layout.
gb_internal bool swift_import_pointer_offset(LLVMTargetDataRef data, LLVMValueRef value, LLVMValueRef base, u64 *offset) {
	if (value == base) { *offset = 0; return true; }
	if (!LLVMIsAGetElementPtrInst(value)) return false;
	u64 result = 0;
	if (!swift_import_pointer_offset(data, LLVMGetOperand(value, 0), base, &result)) return false;
	LLVMTypeRef type = LLVMGetGEPSourceElementType(value);
	for (unsigned i = 1; i < cast(unsigned)LLVMGetNumOperands(value); i++) {
		LLVMValueRef operand = LLVMGetOperand(value, i);
		if (!LLVMIsAConstantInt(operand)) return false;
		u64 index = LLVMConstIntGetZExtValue(operand);
		if (i == 1) {
			if (index != 0) return false;
		} else if (LLVMGetTypeKind(type) == LLVMStructTypeKind) {
			if (index >= LLVMCountStructElementTypes(type)) return false;
			result += LLVMOffsetOfElement(data, type, cast(unsigned)index);
			type = LLVMStructGetTypeAtIndex(type, cast(unsigned)index);
		} else if (LLVMGetTypeKind(type) == LLVMArrayTypeKind) {
			if (index >= LLVMGetArrayLength(type)) return false;
			type = LLVMGetElementType(type);
			result += index * LLVMABISizeOfType(data, type);
		} else return false;
	}
	*offset = result;
	return true;
}

gb_internal LLVMValueRef swift_import_return(LLVMValueRef function) {
	LLVMValueRef result = nullptr;
	for (auto block = LLVMGetFirstBasicBlock(function); block; block = LLVMGetNextBasicBlock(block)) {
		LLVMValueRef end = LLVMGetBasicBlockTerminator(block);
		if (end && LLVMIsAReturnInst(end) && LLVMGetNumOperands(end) == 1) {
			if (result) return nullptr;
			result = LLVMGetOperand(end, 0);
		}
	}
	return result;
}


gb_internal LLVMValueRef swift_import_loaded_value(LLVMValueRef value) {
	while (LLVMIsACastInst(value)) {
		LLVMOpcode op = LLVMGetInstructionOpcode(value);
		if (op != LLVMZExt && op != LLVMTrunc && op != LLVMBitCast && op != LLVMPtrToInt) return nullptr;
		value = LLVMGetOperand(value, 0);
	}
	return LLVMIsALoadInst(value) ? value : nullptr;
}

gb_internal bool swift_import_coercion_uses(LLVMValueRef pointer) {
	for (auto use = LLVMGetFirstUse(pointer); use; use = LLVMGetNextUse(use)) {
		LLVMValueRef user = LLVMGetUser(use);
		if (LLVMIsAGetElementPtrInst(user)) {
			if (!swift_import_coercion_uses(user)) return false;
		} else if (LLVMIsAStoreInst(user)) {
			if (LLVMGetOperand(user, 1) != pointer) return false;
		} else if (LLVMIsALoadInst(user)) {
			if (LLVMGetOperand(user, 0) != pointer) return false;
		} else if (LLVMIsACallInst(user)) {
			size_t length = 0;
			char const *name = LLVMGetValueName2(LLVMGetCalledValue(user), &length);
			if (!string_starts_with(make_string(cast(u8 *)name, length), str_lit("llvm.lifetime."))) return false;
		} else return false;
	}
	return true;
}

// Some load probes copy the value to a local before coercing it. Accept only
// nonescaping temporaries initialized by one bounded memcpy from known storage.
gb_internal bool swift_import_copied_offset(LLVMTargetDataRef data, LLVMValueRef pointer, LLVMValueRef base, u64 offset, u64 size, unsigned depth = 0) {
	u64 source_offset = 0;
	if (swift_import_pointer_offset(data, pointer, base, &source_offset)) return source_offset == offset;
	if (depth == 4) return false;
	LLVMValueRef root = pointer;
	while (LLVMIsAGetElementPtrInst(root)) root = LLVMGetOperand(root, 0);
	if (!LLVMIsAAllocaInst(root) || !swift_import_pointer_offset(data, pointer, root, &source_offset) || source_offset != offset) return false;
	LLVMValueRef copy = nullptr;
	auto pending = array_make<LLVMValueRef>(temporary_allocator());
	array_add(&pending, root);
	for (isize i = 0; i < pending.count; i++) {
		for (auto use = LLVMGetFirstUse(pending[i]); use; use = LLVMGetNextUse(use)) {
			LLVMValueRef user = LLVMGetUser(use);
			if (LLVMIsAGetElementPtrInst(user)) { array_add(&pending, user); continue; }
			if (LLVMIsALoadInst(user)) continue;
			if (!LLVMIsACallInst(user)) return false;
			size_t length = 0;
			char const *text = LLVMGetValueName2(LLVMGetCalledValue(user), &length);
			String name = make_string(cast(u8 *)text, length);
			if (string_starts_with(name, str_lit("llvm.lifetime."))) continue;
			if (!string_starts_with(name, str_lit("llvm.memcpy."))) return false;
			if (LLVMGetOperand(user, 1) == pending[i]) continue;
			if (LLVMGetOperand(user, 0) != root || copy) return false;
			copy = user;
		}
	}
	if (!copy || !LLVMIsAConstantInt(LLVMGetOperand(copy, 2)) ||
	    LLVMConstIntGetZExtValue(LLVMGetOperand(copy, 2)) < offset+size) return false;
	return swift_import_copied_offset(data, LLVMGetOperand(copy, 1), base, 0, offset+size, depth+1);
}

// Swift sometimes gathers adjacent tag bytes through a temporary integer
// coercion. Verify every byte's source and reject calls/escaping pointers to
// that temporary, rather than assuming register order equals storage order.
gb_internal bool swift_import_component_load(LLVMTargetDataRef data, LLVMValueRef value, LLVMValueRef function, u64 offset, u64 size, u64 extent = 0) {
	if (extent == 0) extent = size;
	LLVMValueRef load = swift_import_loaded_value(value);
	if (!load) return false;
	u64 loaded = LLVMStoreSizeOfType(data, LLVMTypeOf(load));
	if (loaded != size && !(LLVMIsAZExtInst(value) && LLVMGetOperand(value, 0) == load && loaded == extent && loaded < size)) return false;
	LLVMValueRef pointer = LLVMGetOperand(load, 0);
	u64 source_offset = 0;
	if (loaded <= extent && swift_import_copied_offset(data, pointer, LLVMGetParam(function, 0), offset, loaded)) return true;
	LLVMValueRef root = pointer;
	while (LLVMIsAGetElementPtrInst(root)) root = LLVMGetOperand(root, 0);
	if (!LLVMIsAAllocaInst(root) || !swift_import_coercion_uses(root) ||
	    !swift_import_pointer_offset(data, pointer, root, &source_offset) || source_offset != offset) return false;
	u64 covered = 0;
	for (auto block = LLVMGetFirstBasicBlock(function); block; block = LLVMGetNextBasicBlock(block)) {
		for (auto instruction = LLVMGetFirstInstruction(block); instruction; instruction = LLVMGetNextInstruction(instruction)) {
			if (!LLVMIsAStoreInst(instruction)) continue;
			u64 destination = 0;
			if (!swift_import_pointer_offset(data, LLVMGetOperand(instruction, 1), root, &destination)) continue;
			u64 bytes = LLVMStoreSizeOfType(data, LLVMTypeOf(LLVMGetOperand(instruction, 0)));
			if (destination >= offset+size || destination+bytes <= offset) continue;
			if (destination < offset || bytes > size || destination+bytes > offset+extent) return false;
			LLVMValueRef field = swift_import_loaded_value(LLVMGetOperand(instruction, 0));
			u64 original = 0;
			if (!field || LLVMStoreSizeOfType(data, LLVMTypeOf(field)) != bytes ||
			    !swift_import_pointer_offset(data, LLVMGetOperand(field, 0), LLVMGetParam(function, 0), &original) ||
			    original != destination) return false;
			u64 mask = ((u64(1)<<bytes)-1) << (destination-offset);
			if (covered & mask) return false;
			covered |= mask;
		}
	}
	// Unwritten bytes in this verified temporary are padding, not payload.
	// No call or escaping pointer may have filled them with other data.
	return covered != 0;
}

gb_internal bool swift_import_enum_layout(LLVMModuleRef module, LLVMTargetDataRef data, SwiftImportNominal *type, isize index) {
	gbString name = gb_string_append_fmt(gb_string_make(temporary_allocator(), ""), "odin_swift_import_layout_%td", index);
	LLVMValueRef layout = LLVMGetNamedFunction(module, name);
	LLVMValueRef result = layout ? swift_import_return(layout) : nullptr;
	if (result && LLVMIsAConstantStruct(result) && LLVMGetNumOperands(result) == 2 &&
	    LLVMIsAConstantInt(LLVMGetOperand(result, 0)) && LLVMIsAConstantInt(LLVMGetOperand(result, 1))) {
		type->size = LLVMConstIntGetZExtValue(LLVMGetOperand(result, 0));
		type->alignment = LLVMConstIntGetZExtValue(LLVMGetOperand(result, 1));
		if ((type->size == 0 && ((!type->is_record && (!swift_import_plain_enum(type) || type->cases.count != 1)) || type->alignment != 1)) ||
		    type->alignment > 8 || type->alignment == 0) type->alignment = 0;
	}
	name = gb_string_append_fmt(gb_string_make(temporary_allocator(), ""), "odin_swift_import_load_%td", index);
	LLVMValueRef load = LLVMGetNamedFunction(module, name);
	if (!load) return false;
	LLVMTypeRef ret = LLVMGetReturnType(LLVMGlobalGetValueType(load));
	if (type->alignment && type->size == 0) return LLVMGetTypeKind(ret) == LLVMVoidTypeKind && LLVMCountParams(load) == 1;
	if (LLVMGetTypeKind(ret) == LLVMVoidTypeKind) {
		unsigned sret = LLVMGetEnumAttributeKindForName("sret", 4);
		LLVMAttributeRef attribute = LLVMGetEnumAttributeAtIndex(load, 1, sret);
		if (!attribute || !LLVMIsTypeAttribute(attribute) || LLVMCountParams(load) != 2) return false;
		LLVMTypeRef result_type = LLVMGetTypeAttributeValue(attribute);
		char const *name = LLVMGetTypeKind(result_type) == LLVMStructTypeKind ? LLVMGetStructName(result_type) : nullptr;
		if (!name) return false;
		type->indirect_llvm = copy_string(permanent_allocator(), make_string_c(name));
		return true;
	}
	if (!type->alignment || LLVMCountParams(load) != 1) return false;
	result = swift_import_return(load);
	if (!result) return false;
	bool aggregate = LLVMGetTypeKind(ret) == LLVMStructTypeKind;
	unsigned count = aggregate ? LLVMCountStructElementTypes(ret) : 1;
	if (count == 0 || count > 4) return false;
	array_init(&type->components, permanent_allocator());
	u64 end = 0;
	for (unsigned i = 0; i < count; i++) {
		LLVMTypeRef component = aggregate ? LLVMStructGetTypeAtIndex(ret, i) : ret;
		char const *odin = nullptr, *llvm = nullptr;
		u64 size = 8;
		if (LLVMGetTypeKind(component) == LLVMIntegerTypeKind) {
			unsigned bits = LLVMGetIntTypeWidth(component);
			if (bits == 64) { odin = "u64"; llvm = "i64"; }
			else if (bits == 32 || bits == 16 || bits == 8 || bits == 1) {
				odin = bits == 32 ? "u32" : bits == 16 ? "u16" : bits == 8 ? "u8" : "bool";
				llvm = bits == 32 ? "i32" : bits == 16 ? "i16" : bits == 8 ? "i8" : "i1";
				size = bits == 1 ? 1 : bits/8;
			}
		} else if (LLVMGetTypeKind(component) == LLVMDoubleTypeKind) { odin = "f64"; llvm = "double"; }
		else if (LLVMGetTypeKind(component) == LLVMPointerTypeKind) { odin = "rawptr"; llvm = "ptr"; }
		if (!odin) return false;
		LLVMValueRef part = result;
		if (aggregate) {
			while (LLVMIsAInsertValueInst(part)) {
				if (LLVMGetNumIndices(part) != 1) return false;
				if (LLVMGetIndices(part)[0] == i) { part = LLVMGetOperand(part, 1); break; }
				part = LLVMGetOperand(part, 0);
			}
		}
		end = align_formula(end, LLVMABIAlignmentOfType(data, component));
		if (end >= type->size) return false;
		u64 extent = gb_min(size, type->size-end);
		if (!swift_import_component_load(data, part, load, end, size, extent)) return false;
		end += extent;
		array_add(&type->components, (SwiftImportType{nullptr, odin, llvm, nullptr}));
	}
	return end == type->size;
}

// Reject cycles and incomplete payloads instead of emitting a union with lost
// cases. Dependent concrete types are resolved before their parent.
gb_internal bool swift_import_resolve_enum(SwiftImportNominal *type) {
	if (type->resolved) return type->supported;
	if (!type->is_enum && !swift_import_slice(type) && type->kind != SwiftImportValue_Set) return type->supported;
	if (type->resolving) return false;
	type->resolving = true;
	if (swift_import_slice(type) || type->kind == SwiftImportValue_Set) {
		type->supported &= swift_import_resolve_enum(type->argument);
		if (type->kind == SwiftImportValue_Set) type->supported &= type->set_array && swift_import_resolve_enum(type->set_array);
		type->resolving = false;
		type->resolved = true;
		return type->supported;
	}
	bool supported = type->supported && type->cases.count != 0;
	type->owns = !type->is_frozen;
	for (auto const &c : type->cases) {
		if (!c.available || (c.has_payload && c.fields.count == 0)) supported = false;
		for (auto const &field : c.fields) {
			if (!field.type.odin) { supported = false; continue; }
			if (field.type.nominal) supported &= field.type.nominal->kind != SwiftImportValue_Set && swift_import_resolve_enum(field.type.nominal);
			type->owns |= swift_import_owns(field.type);
		}
	}
	if (swift_import_plain_enum(type)) {
		String component = type->components.count == 1 ? make_string_c(type->components[0].llvm) : String{};
		supported &= type->alignment != 0 && (type->size == 0 || component == "i1" || component == "i8" || component == "i16");
	}
	type->resolving = false;
	type->resolved = true;
	type->supported = supported;
	type->projected = supported;
	return supported;
}

// A native temporary may have a fixed inline layout even when Swift passes it
// indirectly. Resilient layouts remain allocated using runtime metadata.
gb_internal char const *swift_import_enum_native(SwiftImportNominal *type) {
	if (!type->alignment) return "rawptr";
	return alloc_cstring(permanent_allocator(), concatenate_strings(permanent_allocator(), str_lit("_swift_native_"), type->name));
}

gb_internal String swift_import_enum_llvm(SwiftImportNominal *type, bool result) {
	gbString text = gb_string_make(permanent_allocator(), "");
	if (type->components.count == 0) return str_lit("ptr noalias");
	if (result && type->components.count > 1) text = gb_string_appendc(text, "{ ");
	for_array(i, type->components) text = gb_string_append_fmt(text, "%s%s", i ? ", " : "", type->components[i].llvm);
	if (result && type->components.count > 1) text = gb_string_appendc(text, " }");
	return make_string_c(text);
}

gb_internal gbString swift_import_emit_destroy(gbString source, SwiftImportType const &type, String value) {
	if (!swift_import_owns(type)) return source;
	if (swift_import_kind(type, SwiftImportValue_String)) return gb_string_append_fmt(source, "delete(%.*s, allocator)\n", LIT(value));
	if (swift_import_slice(type.nominal)) {
		if (swift_import_value_slice(type.nominal)) return gb_string_append_fmt(source, "%.*s_destroy(%.*s, allocator)\n", LIT(type.nominal->name), LIT(value));
		if (swift_import_string_array(type)) source = gb_string_append_fmt(source, "for text in %.*s { delete(text, allocator) }\n", LIT(value));
		return gb_string_append_fmt(source, "delete(%.*s, allocator)\n", LIT(value));
	}
	return gb_string_append_fmt(source, "%.*s_destroy(%.*s%s)\n", LIT(type.nominal->name), LIT(value), type.nominal->projected ? ", allocator" : "");
}

// Each conversion consumes exactly one initialized native field, including on
// allocation failure. The enclosing case cleans any fields not yet consumed.
gb_internal gbString swift_import_emit_take_field(gbString source, SwiftImportType const &type, String value, String address) {
	if (!type.nominal || type.nominal->is_scalar) {
		return gb_string_append_fmt(source, "%.*s := (cast(^%s)%.*s)^\n", LIT(value), type.odin, LIT(address));
	}
	if (swift_import_kind(type, SwiftImportValue_String)) {
		source = gb_string_append_fmt(source, "_native_%.*s := (cast(^swift.Native_String)%.*s)^\n%.*s, _ok_%.*s := swift.string_to_odin(_native_%.*s)\nswift.string_destroy(&_native_%.*s)\n", LIT(value), LIT(address), LIT(value), LIT(value), LIT(value), LIT(value));
	} else if (swift_import_slice(type.nominal)) {
		source = gb_string_append_fmt(source, "_native_%.*s := (cast(^swift.Native_Array)%.*s)^\n%.*s, _ok_%.*s := %.*s\nswift.array_destroy(_native_%.*s)\n", LIT(value), LIT(address), LIT(value), LIT(value), LIT(swift_import_array_to(type.nominal, concatenate_strings(permanent_allocator(), str_lit("_native_"), value))), LIT(value));
	} else if (type.nominal->projected) {
		source = gb_string_append_fmt(source, "%.*s, _ok_%.*s := _swift_%.*s_take(%.*s)\n", LIT(value), LIT(value), LIT(type.nominal->name), LIT(address));
	} else {
		source = gb_string_append_fmt(source, "_storage_%.*s, _ok_%.*s := swift.value_take(%.*s, %.*s)\n%.*s := %s(_storage_%.*s)\n", LIT(value), LIT(value), LIT(address), LIT(swift_import_metadata(type)), LIT(value), type.odin, LIT(value));
	}
	return source;
}

gb_internal gbString swift_import_emit_initialize_field(gbString source, SwiftImportType const &type, String value, String address) {
	if (!type.nominal || type.nominal->is_scalar) return gb_string_append_fmt(source, "(cast(^%s)%.*s)^ = %.*s\n", type.odin, LIT(address), LIT(value));
	if (swift_import_kind(type, SwiftImportValue_String)) return gb_string_append_fmt(source, "(cast(^swift.Native_String)%.*s)^ = swift.string_from_odin(%.*s) or_return\n", LIT(address), LIT(value));
	if (swift_import_slice(type.nominal)) return gb_string_append_fmt(source, "(cast(^swift.Native_Array)%.*s)^ = %.*s or_return\n", LIT(address), LIT(swift_import_array_from(type.nominal, value)));
	if (type.nominal->projected) return gb_string_append_fmt(source, "if !_swift_%.*s_initialize(%.*s, %.*s) { return false }\n", LIT(type.nominal->name), LIT(address), LIT(value));
	return gb_string_append_fmt(source, "if %.*s == nil { return false }\nswift.value_initialize_copy(%.*s, rawptr(%.*s), %.*s)\n", LIT(value), LIT(address), LIT(value), LIT(swift_import_metadata(type)));
}

gb_internal gbString swift_import_emit_copy_field(gbString source, SwiftImportType const &type, String value, String from) {
	if (!swift_import_owns(type)) return gb_string_append_fmt(source, "%.*s := %.*s\n", LIT(value), LIT(from));
	if (swift_import_kind(type, SwiftImportValue_String)) {
		return gb_string_append_fmt(source, "%.*s, _error_%.*s := strings.clone(%.*s, allocator)\nif _error_%.*s != nil { return }\n", LIT(value), LIT(value), LIT(from), LIT(value));
	}
	if (swift_import_value_slice(type.nominal)) return gb_string_append_fmt(source, "%.*s := %.*s_copy(%.*s, allocator) or_return\n", LIT(value), LIT(type.nominal->name), LIT(from));
	if (swift_import_slice(type.nominal)) {
		source = gb_string_append_fmt(source, "%.*s, _error_%.*s := make(%s, len(%.*s), allocator)\nif _error_%.*s != nil { return }\n", LIT(value), LIT(value), type.odin, LIT(from), LIT(value));
		if (swift_import_string_array(type)) {
			source = gb_string_append_fmt(source, "for text, index in %.*s {\n\tcloned, err := strings.clone(text, allocator)\n\tif err != nil {\n\t\tfor initialized in %.*s[:index] { delete(initialized, allocator) }\n\t\tdelete(%.*s, allocator)\n\t\treturn\n\t}\n\t%.*s[index] = cloned\n}\n", LIT(from), LIT(value), LIT(value), LIT(value));
		} else source = gb_string_append_fmt(source, "copy(%.*s, %.*s)\n", LIT(value), LIT(from));
		return source;
	}
	return gb_string_append_fmt(source, "%.*s := %.*s_copy(%.*s%s) or_return\n", LIT(value), LIT(type.nominal->name), LIT(from), type.nominal->projected ? ", allocator" : "");
}

gb_internal String swift_import_field_value(isize index) {
	return make_string_c(gb_string_append_fmt(gb_string_make(permanent_allocator(), ""), "_value%td", index));
}

gb_internal String swift_import_field_address(SwiftImportCase const &c, isize index) {
	if (c.fields.count == 1) return str_lit("storage");
	return make_string_c(gb_string_append_fmt(gb_string_make(permanent_allocator(), ""), "swift.tuple_element(storage, tuple, %td)", index));
}

gb_internal gbString swift_import_emit_tuple(gbString source, SwiftImportCase const &c) {
	if (c.fields.count < 2) return source;
	source = gb_string_appendc(source, "fields := []rawptr{");
	for (auto const &field : c.fields) source = gb_string_append_fmt(source, "%.*s, ", LIT(swift_import_metadata(field.type)));
	return gb_string_appendc(source, "}\ntuple := swift.tuple_metadata(fields)\n");
}

gb_internal gbString swift_import_emit_case_result(gbString source, SwiftImportNominal *type, SwiftImportCase const &c) {
	if (type->is_optional) return gb_string_appendc(source, c.has_payload ? "return _value0, true\n" : "return nil, true\n");
	source = gb_string_append_fmt(source, "return %.*s{", LIT(swift_import_case_name(type, c)));
	for_array(i, c.fields) source = gb_string_append_fmt(source, "%s_value%td", i ? ", " : "", i);
	return gb_string_appendc(source, "}, true\n");
}

// A scalar has no extra inhabitants. Its Optional therefore appends a tag
// byte (some=0, none=1). Use this path only when inspection verified that exact
// native size and component layout. Nested optionals must append another byte;
// layouts reusing extra inhabitants continue to use Swift's witnesses.
gb_internal bool swift_import_plain_optional(SwiftImportNominal *type) {
	if (!type->is_optional || !type->projected || type->owns || !type->alignment || !type->components.count) return false;
	auto argument = type->argument;
	if (argument->is_scalar) {
		// Bool has spare bit patterns. Integer and floating-point scalars
		// have none and their size equals their natural alignment on arm64.
		return argument->swift_name != "Swift.Bool" && type->size == type->alignment+1;
	}
	return swift_import_plain_optional(argument) && type->size == argument->size+1 && type->alignment == argument->alignment;
}

// Frozen no-payload enums are ordinary Odin values. Their backing type is
// independent of Swift's tag width, including i1 and a zero-sized single case.
// RawRepresentable raw values are initializer/getter data, not these ABI tags.
gb_internal gbString swift_import_emit_plain_enum(gbString source, SwiftImportNominal *type) {
	String name = type->name;
	source = gb_string_append_fmt(source, "%.*s :: enum u32 {\n", LIT(name));
	for (auto const &c : type->cases) source = gb_string_append_fmt(source, "\t%.*s = %u,\n", LIT(swift_import_case_member(c)), c.tag);
	source = gb_string_appendc(source, "}\n");
	if (type->size == 0) source = gb_string_append_fmt(source, "@(private)\n_swift_native_%.*s :: struct {bytes: [0]u8}\n", LIT(name));
	else source = gb_string_append_fmt(source, "@(private)\n_swift_native_%.*s :: %s\n", LIT(name), type->components[0].odin);
	source = gb_string_append_fmt(source, "@(private)\n_swift_%.*s_take :: proc(storage: rawptr) -> (result: %.*s, ok: bool) #optional_ok {\n", LIT(name), LIT(name));
	if (type->size == 0) source = gb_string_append_fmt(source, "return .%.*s, true\n", LIT(swift_import_case_member(type->cases[0])));
	else source = gb_string_append_fmt(source, "tag := u32((cast(^_swift_native_%.*s)storage)^)\nassert(tag < %td, \"Invalid frozen Swift enum tag\")\nreturn %.*s(tag), true\n", LIT(name), type->cases.count, LIT(name));
	source = gb_string_append_fmt(source, "}\n@(private)\n_swift_%.*s_initialize :: proc(storage: rawptr, value: %.*s) -> bool {\n", LIT(name), LIT(name));
	if (type->size == 0) source = gb_string_append_fmt(source, "return value == .%.*s\n", LIT(swift_import_case_member(type->cases[0])));
	else source = gb_string_append_fmt(source, "if u32(value) >= %td { return false }\n(cast(^_swift_native_%.*s)storage)^ = _swift_native_%.*s(value)\nreturn true\n", type->cases.count, LIT(name), LIT(name));
	return gb_string_appendc(source, "}\n\n");
}

// Resilient generic specializations share case-tag symbols. Emit one foreign
// global per symbol, including in single-module builds where duplicate LLVM
// globals would otherwise acquire invalid numeric suffixes.
gb_internal gbString swift_import_emit_enum_tags(gbString source, Array<SwiftImportNominal *> const &types) {
	auto imported = array_make<SwiftImportCase *>(temporary_allocator());
	for (auto type : types) {
		if (!type->supported || !type->is_enum || !type->projected || swift_import_plain_enum(type)) continue;
		for_array(i, type->cases) {
			auto &c = type->cases[i];
			c.tag_name = make_string_c(gb_string_append_fmt(gb_string_make(permanent_allocator(), ""), "_swift_%.*s_tag_%td", LIT(type->name), i));
			if (type->is_frozen) {
				source = gb_string_append_fmt(source, "@(private)\n%.*s :: u32(%u)\n", LIT(c.tag_name), c.tag);
				continue;
			}
			bool duplicate = false;
			for (auto previous : imported) {
				if (previous->symbol == c.symbol) {
					c.tag_name = previous->tag_name;
					duplicate = true;
					break;
				}
			}
			if (duplicate) continue;
			array_add(&imported, &c);
			source = gb_string_append_fmt(source, "@(private)\nforeign swift_library {\n\t@(link_name=\"%.*s\")\n\t%.*s: u32\n}\n", LIT(c.symbol), LIT(c.tag_name));
		}
	}
	return source;
}

gb_internal gbString swift_import_emit_enum(gbString source, SwiftImportNominal *type) {
	if (swift_import_plain_enum(type)) return swift_import_emit_plain_enum(source, type);
	String name = type->name;
	// Odin requires at least two variants for #no_nil. Keep a single payload
	// case as an ordinary union, rejecting its extra nil state on conversion.
	bool nullable = type->is_frozen && !type->is_optional && type->cases.count == 1;
	if (type->is_optional) {
		source = gb_string_append_fmt(source, "%.*s :: Maybe(%s)\n", LIT(name), swift_import_nominal_type(type->argument).odin);
	} else {
		for (auto const &c : type->cases) {
			source = gb_string_append_fmt(source, "%.*s :: struct {\n", LIT(swift_import_case_name(type, c)));
			for (auto const &field : c.fields) source = gb_string_append_fmt(source, "\t%.*s: %s,\n", LIT(field.name), field.type.odin);
			source = gb_string_appendc(source, "}\n");
		}
		if (!type->is_frozen) source = gb_string_append_fmt(source,
			"@(private)\n_swift_unknown_%.*s :: distinct rawptr\n%.*s_Unknown :: struct {value: _swift_unknown_%.*s}\n", LIT(name), LIT(name), LIT(name));
		source = gb_string_append_fmt(source, "%.*s :: union%s {\n", LIT(name), nullable ? "" : " #no_nil");
		for (auto const &c : type->cases) source = gb_string_append_fmt(source, "\t%.*s,\n", LIT(swift_import_case_name(type, c)));
		if (!type->is_frozen) source = gb_string_append_fmt(source, "\t%.*s_Unknown,\n", LIT(name));
		source = gb_string_appendc(source, "}\n");
	}
	if (type->alignment) {
		source = gb_string_append_fmt(source, "@(private)\n_swift_native_%.*s :: ", LIT(name));
		if (type->components.count == 1) source = gb_string_append_fmt(source, "%s\n", type->components[0].odin);
		else if (type->components.count) {
			source = gb_string_appendc(source, "struct {\n");
			for_array(i, type->components) source = gb_string_append_fmt(source, "\tr%td: %s,\n", i, type->components[i].odin);
			source = gb_string_appendc(source, "}\n");
		} else source = gb_string_append_fmt(source, "struct #align(%llu) {bytes: [%llu]u8}\n", cast(unsigned long long)type->alignment, cast(unsigned long long)type->size);
	}

	// Consuming native-to-Odin projection. Native temporary storage is freed by
	// the caller separately; neither stack nor async capture storage is freed.
	source = gb_string_append_fmt(source, "@(private)\n_swift_%.*s_take :: proc(storage: rawptr) -> (result: %.*s, ok: bool) #optional_ok {\n", LIT(name), LIT(name));
	bool plain_optional = swift_import_plain_optional(type);
	if (plain_optional) source = gb_string_append_fmt(source,
		"tag := u32((cast([^]u8)storage)[%llu])\nif tag > 1 { panic(\"Invalid frozen Swift enum tag\") }\n", cast(unsigned long long)(type->size-1));
	else source = gb_string_append_fmt(source, "metadata := _swift_%.*s_metadata(0).type\ntag, tagged := swift.enum_tag(storage, metadata)\nassert(tagged)\n", LIT(name));
	for_array(i, type->cases) {
		auto const &c = type->cases[i];
		if (plain_optional && !c.has_payload) {
			source = swift_import_emit_case_result(source, type, c);
			continue;
		}
		source = gb_string_append_fmt(source, "if tag == %.*s {\n", LIT(c.tag_name));
		if (c.has_payload && !plain_optional) source = gb_string_appendc(source, "swift.enum_project(storage, metadata)\n");
		source = swift_import_emit_tuple(source, c);
		for_array(j, c.fields) {
			auto const &field = c.fields[j];
			String value = swift_import_field_value(j);
			source = swift_import_emit_take_field(source, field.type, value, swift_import_field_address(c, j));
			if (field.type.nominal && !field.type.nominal->is_scalar) {
				source = gb_string_append_fmt(source, "if !_ok_%.*s {\n", LIT(value));
				for (isize k = j+1; k < c.fields.count; k++) source = gb_string_append_fmt(source,
					"swift.value_deinitialize(%.*s, %.*s)\n", LIT(swift_import_field_address(c, k)), LIT(swift_import_metadata(c.fields[k].type)));
				source = gb_string_appendc(source, "return\n}\n");
			}
			if (swift_import_owns(field.type)) {
				source = gb_string_appendc(source, "defer if !ok {\n");
				if (field.type.nominal->projected || field.type.nominal->kind == SwiftImportValue_String || swift_import_slice(field.type.nominal)) source = gb_string_appendc(source, "allocator := context.allocator\n");
				source = swift_import_emit_destroy(source, field.type, value);
				source = gb_string_appendc(source, "}\n");
			}
		}
		source = swift_import_emit_case_result(source, type, c);
		source = gb_string_appendc(source, "}\n");
	}
	if (!type->is_frozen) source = gb_string_append_fmt(source, "unknown := swift.value_take(storage, metadata) or_return\nreturn %.*s_Unknown{_swift_unknown_%.*s(unknown)}, true\n", LIT(name), LIT(name));
	else if (!plain_optional) source = gb_string_appendc(source, "swift.value_deinitialize(storage, metadata)\npanic(\"Invalid frozen Swift enum tag\")\n");
	source = gb_string_appendc(source, "}\n");

	// Construct the native enum in uninitialized storage. Failure leaves it
	// uninitialized and destroys all fields already constructed.
	source = gb_string_append_fmt(source, "@(private)\n_swift_%.*s_initialize :: proc(storage: rawptr, value: %.*s) -> (ok: bool) {\n", LIT(name), LIT(name));
	if (!plain_optional) source = gb_string_append_fmt(source, "metadata := _swift_%.*s_metadata(0).type\n", LIT(name));
	source = gb_string_appendc(source, "switch item in value {\n");
	for_array(i, type->cases) {
		auto const &c = type->cases[i];
		if (type->is_optional) source = gb_string_append_fmt(source, "case %s:\n", c.has_payload ? c.fields[0].type.odin : "nil");
		else source = gb_string_append_fmt(source, "case %.*s:\n", LIT(swift_import_case_name(type, c)));
		source = swift_import_emit_tuple(source, c);
		for_array(j, c.fields) {
			auto const &field = c.fields[j];
			String value = type->is_optional ? str_lit("item") : concatenate_strings(permanent_allocator(), str_lit("item."), field.name);
			String address = swift_import_field_address(c, j);
			source = swift_import_emit_initialize_field(source, field.type, value, address);
			if (swift_import_native_owns(field.type)) source = gb_string_append_fmt(source, "defer if !ok { swift.value_deinitialize(%.*s, %.*s) }\n", LIT(address), LIT(swift_import_metadata(field.type)));
		}
		if (plain_optional) source = gb_string_append_fmt(source, "(cast([^]u8)storage)[%llu] = %u\n", cast(unsigned long long)(type->size-1), c.tag);
		else source = gb_string_append_fmt(source, "swift.enum_inject(storage, metadata, %.*s)\n", LIT(c.tag_name));
		source = gb_string_appendc(source, "return true\n");
	}
	if (!type->is_frozen) source = gb_string_append_fmt(source, "case %.*s_Unknown:\nif item.value == nil { return false }\nswift.value_initialize_copy(storage, rawptr(item.value), metadata)\nreturn true\n", LIT(name));
	if (nullable) source = gb_string_appendc(source, "case nil: return false\n");
	source = gb_string_appendc(source, "}\nreturn false\n}\n");

	// Public ownership helpers act on ordinary Odin data. Assignment remains
	// a shallow copy; these are explicit operations on an independently owned value.
	source = gb_string_append_fmt(source, "%.*s_destroy :: proc(value: %.*s, allocator := context.allocator) {\nswitch item in value {\n", LIT(name), LIT(name));
	for (auto const &c : type->cases) {
		if (type->is_optional) source = gb_string_append_fmt(source, "case %s:\n", c.has_payload ? c.fields[0].type.odin : "nil");
		else source = gb_string_append_fmt(source, "case %.*s:\n", LIT(swift_import_case_name(type, c)));
		for (auto const &field : c.fields) source = swift_import_emit_destroy(source, field.type,
			type->is_optional ? str_lit("item") : concatenate_strings(permanent_allocator(), str_lit("item."), field.name));
	}
	if (!type->is_frozen) source = gb_string_append_fmt(source, "case %.*s_Unknown:\nswift.value_destroy(rawptr(item.value), _swift_%.*s_metadata(0).type)\n", LIT(name), LIT(name));
	if (nullable) source = gb_string_appendc(source, "case nil:\n");
	source = gb_string_appendc(source, "}\n}\n");
	source = gb_string_append_fmt(source, "@(require_results)\n%.*s_copy :: proc(value: %.*s, allocator := context.allocator) -> (result: %.*s, ok: bool) #optional_ok {\ncontext.allocator = allocator\nswitch item in value {\n", LIT(name), LIT(name), LIT(name));
	for (auto const &c : type->cases) {
		if (type->is_optional) source = gb_string_append_fmt(source, "case %s:\n", c.has_payload ? c.fields[0].type.odin : "nil");
		else source = gb_string_append_fmt(source, "case %.*s:\n", LIT(swift_import_case_name(type, c)));
		for_array(j, c.fields) {
			auto const &field = c.fields[j];
			String value = swift_import_field_value(j);
			String from = type->is_optional ? str_lit("item") : concatenate_strings(permanent_allocator(), str_lit("item."), field.name);
			source = swift_import_emit_copy_field(source, field.type, value, from);
			if (swift_import_owns(field.type)) {
				source = gb_string_appendc(source, "defer if !ok {\n");
				source = swift_import_emit_destroy(source, field.type, value);
				source = gb_string_appendc(source, "}\n");
			}
		}
		source = swift_import_emit_case_result(source, type, c);
	}
	if (!type->is_frozen) source = gb_string_append_fmt(source, "case %.*s_Unknown:\ncopy := swift.value_copy(rawptr(item.value), _swift_%.*s_metadata(0).type, allocator) or_return\nreturn %.*s_Unknown{_swift_unknown_%.*s(copy)}, true\n", LIT(name), LIT(name), LIT(name), LIT(name));
	if (nullable) source = gb_string_appendc(source, "case nil: return\n");
	return gb_string_appendc(source, "}\nreturn\n}\n\n");
}
