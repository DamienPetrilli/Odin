// Date's public projection preserves its floating-point reference-epoch seconds.
// Its resilient native value is constructed and read through inspected Swift ABI.

gb_internal gbString swift_import_date_probe(gbString source, SwiftImportNominal *type, isize index) {
	return gb_string_append_fmt(source,
		"@_silgen_name(\"odin_swift_import_date_get_%td\")\npublic func date_get_%td(_ value: Swift.UnsafePointer<%.*s>) -> Swift.Double { value.pointee.timeIntervalSinceReferenceDate }\n"
		"@_silgen_name(\"odin_swift_import_date_init_%td\")\npublic func date_init_%td(_ storage: Swift.UnsafeMutablePointer<%.*s>, _ seconds: Swift.Double) { storage.initialize(to: %.*s(timeIntervalSinceReferenceDate: seconds)) }\n",
		index, index, LIT(type->swift_name), index, index, LIT(type->swift_name), LIT(type->swift_name));
}

gb_internal bool swift_import_date_layout(LLVMModuleRef module, String sil, SwiftImportNominal *type, isize index) {
	gbString name = gb_string_append_fmt(gb_string_make(temporary_allocator(), ""), "odin_swift_import_date_get_%td", index);
	LLVMValueRef probe = LLVMGetNamedFunction(module, name);
	LLVMValueRef result = probe ? swift_import_return(probe) : nullptr;
	if (!result || !LLVMIsACallInst(result)) return false;
	LLVMValueRef getter = LLVMGetCalledValue(result);
	if (!LLVMIsAFunction(getter) || !LLVMIsDeclaration(getter) || LLVMGetFunctionCallConv(getter) != LLVMSwiftCallConv ||
	    LLVMCountParams(getter) != 1 || LLVMGetTypeKind(LLVMTypeOf(LLVMGetParam(getter, 0))) != LLVMPointerTypeKind ||
	    LLVMGetTypeKind(LLVMGetReturnType(LLVMGlobalGetValueType(getter))) != LLVMDoubleTypeKind) return false;
	unsigned self = LLVMGetEnumAttributeKindForName("swiftself", 9);
	if (!LLVMGetEnumAttributeAtIndex(getter, 1, self)) return false;

	name = gb_string_append_fmt(gb_string_make(temporary_allocator(), ""), "odin_swift_import_date_init_%td", index);
	probe = LLVMGetNamedFunction(module, name);
	if (!probe) return false;
	LLVMValueRef initializer = nullptr;
	unsigned sret = LLVMGetEnumAttributeKindForName("sret", 4);
	for (auto block = LLVMGetFirstBasicBlock(probe); block; block = LLVMGetNextBasicBlock(block)) {
		for (auto instruction = LLVMGetFirstInstruction(block); instruction; instruction = LLVMGetNextInstruction(instruction)) {
			if (!LLVMIsACallInst(instruction)) continue;
			auto function = LLVMGetCalledValue(instruction);
			if (!LLVMIsAFunction(function) || !LLVMIsDeclaration(function) || LLVMGetFunctionCallConv(function) != LLVMSwiftCallConv ||
			    LLVMCountParams(function) != 2 || LLVMGetTypeKind(LLVMTypeOf(LLVMGetParam(function, 0))) != LLVMPointerTypeKind ||
			    LLVMGetTypeKind(LLVMTypeOf(LLVMGetParam(function, 1))) != LLVMDoubleTypeKind ||
			    LLVMGetTypeKind(LLVMGetReturnType(LLVMGlobalGetValueType(function))) != LLVMVoidTypeKind ||
			    !LLVMGetEnumAttributeAtIndex(function, 1, sret)) continue;
			if (initializer) return false;
			initializer = function;
		}
	}
	if (!initializer) return false;
	type->date_getter = copy_string(permanent_allocator(), make_string_c(LLVMGetValueName(getter)));
	type->date_initializer = copy_string(permanent_allocator(), make_string_c(LLVMGetValueName(initializer)));
	// The getter borrows self; initialization produces one owned value.
	String getter_sil = make_string_c(gb_string_append_fmt(gb_string_make(permanent_allocator(), ""),
		" @%.*s : $@convention(method) (@in_guaranteed Date) -> Double", LIT(type->date_getter)));
	String initializer_sil = make_string_c(gb_string_append_fmt(gb_string_make(permanent_allocator(), ""),
		" @%.*s : $@convention(method) (Double, @thin Date.Type) -> @out Date", LIT(type->date_initializer)));
	if (!swift_import_has_line(sil, getter_sil, false) || !swift_import_has_line(sil, initializer_sil, false)) return false;
	type->projected = true;
	return true;
}

gb_internal gbString swift_import_emit_date(gbString source, SwiftImportNominal *type) {
	String name = type->name;
	source = swift_import_emit_cached_layout(source, name);
	source = gb_string_append_fmt(source,
		"@(private)\nforeign swift_library {\n\t@(link_name=\"%.*sMa\")\n"
		"\t_swift_%.*s_metadata :: proc \"swift\" (request: u64) -> swift.Metadata_Response ---\n}\n",
		LIT(type->symbol), LIT(name));
	return gb_string_append_fmt(source,
		"%.*s :: swift.Date\n"
		"@(private)\nforeign swift_library {\n"
		"\t@(link_name=\"%.*s\")\n\t_swift_%.*s_seconds :: proc \"swift\" (#swift_self value: rawptr) -> f64 ---\n"
		"\t@(link_name=\"%.*s\")\n\t_swift_%.*s_construct :: proc \"swift\" (#swift_result storage: rawptr, seconds: f64) ---\n}\n"
		"@(private)\n_swift_%.*s_initialize :: proc(storage: rawptr, value: %.*s) -> bool {\n\t_swift_%.*s_construct(storage, f64(value))\n\treturn true\n}\n"
		"@(private)\n_swift_%.*s_take_with_layout :: proc(storage: rawptr, layout: swift.Value_Layout) -> (result: %.*s, ok: bool) #optional_ok {\n"
		"\tseconds := _swift_%.*s_seconds(storage)\n\tswift.value_deinitialize_from_layout(storage, layout)\n\treturn %.*s(seconds), true\n}\n\n",
		LIT(name), LIT(type->date_getter), LIT(name), LIT(type->date_initializer), LIT(name),
		LIT(name), LIT(name), LIT(name), LIT(name), LIT(name), LIT(name), LIT(name));
}
