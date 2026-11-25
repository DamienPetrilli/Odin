// UUID projects to core:encoding/uuid.Identifier. The native value is resilient;
// only its public byte getter and initializer determine the boundary conversion.

gb_internal gbString swift_import_uuid_probe(gbString source, SwiftImportNominal *type, isize index) {
	return gb_string_append_fmt(source,
		"@_silgen_name(\"odin_swift_import_uuid_get_%td\")\npublic func uuid_get_%td(_ value: Swift.UnsafePointer<%.*s>) -> Foundation.uuid_t { value.pointee.uuid }\n"
		"@_silgen_name(\"odin_swift_import_uuid_init_%td\")\npublic func uuid_init_%td(_ storage: Swift.UnsafeMutablePointer<%.*s>, _ bytes: Foundation.uuid_t) { storage.initialize(to: %.*s(uuid: bytes)) }\n"
		"@_silgen_name(\"odin_swift_import_uuid_echo_%td\")\npublic func uuid_echo_%td(_ value: %.*s) -> %.*s { value }\n",
		index, index, LIT(type->swift_name), index, index, LIT(type->swift_name), LIT(type->swift_name),
		index, index, LIT(type->swift_name), LIT(type->swift_name));
}

gb_internal bool swift_import_uuid_layout(LLVMModuleRef module, String sil, SwiftImportNominal *type, isize index) {
	LLVMValueRef functions[2] = {};
	unsigned self = LLVMGetEnumAttributeKindForName("swiftself", 9);
	unsigned sret = LLVMGetEnumAttributeKindForName("sret", 4);
	for (isize i = 0; i < 2; i++) {
		gbString name = gb_string_append_fmt(gb_string_make(temporary_allocator(), ""), "odin_swift_import_uuid_%s_%td", i ? "init" : "get", index);
		LLVMValueRef probe = LLVMGetNamedFunction(module, name);
		if (!probe) return false;
		for (auto block = LLVMGetFirstBasicBlock(probe); block; block = LLVMGetNextBasicBlock(block)) {
			for (auto instruction = LLVMGetFirstInstruction(block); instruction; instruction = LLVMGetNextInstruction(instruction)) {
				if (!LLVMIsACallInst(instruction)) continue;
				auto function = LLVMGetCalledValue(instruction);
				if (!LLVMIsAFunction(function) || !LLVMIsDeclaration(function) || LLVMGetFunctionCallConv(function) != LLVMSwiftCallConv) continue;
				if (LLVMCountParams(function) != (i ? 17u : 1u) || LLVMGetTypeKind(LLVMTypeOf(LLVMGetParam(function, 0))) != LLVMPointerTypeKind) continue;
				LLVMTypeRef result = LLVMGetReturnType(LLVMGlobalGetValueType(function));
				bool valid = true;
				if (i) {
					valid = LLVMGetTypeKind(result) == LLVMVoidTypeKind && LLVMGetEnumAttributeAtIndex(function, 1, sret);
					for (unsigned j = 1; j < 17 && valid; j++) {
						LLVMTypeRef byte = LLVMTypeOf(LLVMGetParam(function, j));
						valid = LLVMGetTypeKind(byte) == LLVMIntegerTypeKind && LLVMGetIntTypeWidth(byte) == 8;
					}
				} else {
					valid = LLVMGetEnumAttributeAtIndex(function, 1, self) && LLVMGetTypeKind(result) == LLVMStructTypeKind && LLVMCountStructElementTypes(result) == 2;
					for (unsigned j = 0; j < 2 && valid; j++) {
						LLVMTypeRef word = LLVMStructGetTypeAtIndex(result, j);
						valid = LLVMGetTypeKind(word) == LLVMIntegerTypeKind && LLVMGetIntTypeWidth(word) == 64;
					}
				}
				if (!valid) continue;
				if (functions[i]) return false;
				functions[i] = function;
			}
		}
		if (!functions[i]) return false;
	}
	gbString name = gb_string_append_fmt(gb_string_make(temporary_allocator(), ""), "odin_swift_import_uuid_echo_%td", index);
	LLVMValueRef echo = LLVMGetNamedFunction(module, name);
	if (!echo || LLVMGetFunctionCallConv(echo) != LLVMSwiftCallConv || LLVMCountParams(echo) != 2 ||
	    LLVMGetTypeKind(LLVMGetReturnType(LLVMGlobalGetValueType(echo))) != LLVMVoidTypeKind ||
	    !LLVMGetEnumAttributeAtIndex(echo, 1, sret)) return false;
	for (unsigned i = 0; i < 2; i++) if (LLVMGetTypeKind(LLVMTypeOf(LLVMGetParam(echo, i))) != LLVMPointerTypeKind) return false;
	String signature = make_string_c(gb_string_append_fmt(gb_string_make(temporary_allocator(), ""),
		" @%s : $@convention(thin) (@in_guaranteed UUID) -> @out UUID {", name));
	if (!swift_import_has_line(sil, signature, false)) return false;
	type->uuid_getter = copy_string(permanent_allocator(), make_string_c(LLVMGetValueName(functions[0])));
	type->uuid_initializer = copy_string(permanent_allocator(), make_string_c(LLVMGetValueName(functions[1])));
	gbString bytes = gb_string_make(temporary_allocator(), "");
	for (isize i = 0; i < 16; i++) bytes = gb_string_appendc(bytes, i ? ", UInt8" : "UInt8");
	String getter = make_string_c(gb_string_append_fmt(gb_string_make(temporary_allocator(), ""),
		" @%.*s : $@convention(method) (@in_guaranteed UUID) -> (%s)", LIT(type->uuid_getter), bytes));
	String initializer = make_string_c(gb_string_append_fmt(gb_string_make(temporary_allocator(), ""),
		" @%.*s : $@convention(method) (%s, @thin UUID.Type) -> @out UUID", LIT(type->uuid_initializer), bytes));
	if (!swift_import_has_line(sil, getter, false) || !swift_import_has_line(sil, initializer, false)) return false;
	type->projected = true;
	return true;
}

gb_internal gbString swift_import_emit_uuid(gbString source, SwiftImportNominal *type) {
	source = swift_import_emit_cached_layout(source, type->name);
	source = gb_string_append_fmt(source,
		"UUID :: _swift_uuid.Identifier\n"
		"@(private)\n_swift_UUID_Words :: struct { low, high: u64 }\n"
		"@(private)\nforeign swift_library {\n"
		"\t@(link_name=\"%.*sMa\")\n\t_swift_UUID_metadata :: proc \"swift\" (request: u64) -> swift.Metadata_Response ---\n"
		"\t@(link_name=\"%.*s\")\n\t_swift_UUID_bytes :: proc \"swift\" (#swift_self value: rawptr) -> _swift_UUID_Words ---\n"
		"\t@(link_name=\"%.*s\")\n\t_swift_UUID_construct :: proc \"swift\" (#swift_result storage: rawptr",
		LIT(type->symbol), LIT(type->uuid_getter), LIT(type->uuid_initializer));
	for (isize i = 0; i < 16; i++) source = gb_string_append_fmt(source, ", b%td: u8", i);
	source = gb_string_appendc(source,
		") ---\n}\n"
		"@(private)\n_swift_UUID_initialize :: proc(storage: rawptr, value: UUID) -> bool {\n\t_swift_UUID_construct(storage");
	for (isize i = 0; i < 16; i++) source = gb_string_append_fmt(source, ", value[%td]", i);
	return gb_string_appendc(source,
		")\n\treturn true\n}\n"
		"@(private)\n_swift_UUID_read :: proc(storage: rawptr) -> UUID { return transmute(UUID)_swift_UUID_bytes(storage) }\n"
		"@(private)\n_swift_UUID_take_with_layout :: proc(storage: rawptr, layout: swift.Value_Layout) -> (result: UUID, ok: bool) #optional_ok {\n"
		"\tvalue := _swift_UUID_read(storage)\n\tswift.value_deinitialize_from_layout(storage, layout)\n\treturn value, true\n}\n\n");
}
