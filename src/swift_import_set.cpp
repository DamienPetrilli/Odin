// Set inputs are Odin slices. Swift hashing/equality determine membership.
// Nontrivial elements use the literal initializer, which consumes a native Array.

gb_internal gbString swift_import_set_probe(gbString source, SwiftImportNominal *type, isize index) {
	source = gb_string_append_fmt(source,
		"@_silgen_name(\"odin_swift_import_set_%td\")\npublic func set_%td(_ a: %.*s, _ b: %.*s) -> %.*s { [a, b] }\n",
		index, index, LIT(type->argument->swift_name), LIT(type->argument->swift_name), LIT(type->swift_name));
	if (type->argument->is_scalar) {
		source = gb_string_append_fmt(source,
			"@_silgen_name(\"odin_swift_import_set_native_%td\")\n"
			"public func native_%td(_ count: Swift.Int) -> %.*s {\n"
			"let native = Swift._NativeSet<%.*s>(capacity: count)\n"
			"_ = native.hashTable; _ = native._elements; _ = native._storage._seed\n"
			"return Swift.Set(_native: native)\n}\n"
			"@_silgen_name(\"odin_swift_import_set_hash_%td\")\n"
			"public func hash_%td(_ value: %.*s, _ seed: Swift.Int) -> Swift.Int { value._rawHashValue(seed: seed) }\n"
			"@_silgen_name(\"odin_swift_import_set_equal_%td\")\n"
			"public func equal_%td(_ a: %.*s, _ b: %.*s) -> Swift.Bool { %s }\n",
			index, index, LIT(type->swift_name), LIT(type->argument->swift_name), index, index, LIT(type->argument->swift_name),
			index, index, LIT(type->argument->swift_name), LIT(type->argument->swift_name), type->argument->name == "Double" ? "a.isEqual(to: b)" : "a == b");
	}
	return source;
}


// Frozen ABI storage permits scalar initialization without a temporary Array.
// Reject an unfamiliar layout/convention and retain the literal constructor.
gb_internal bool swift_import_set_sil(String sil, String symbol, String convention) {
	String anchor = concatenate3_strings(temporary_allocator(), str_lit(" @"), symbol, str_lit(" : $@convention(method)"));
	String_Iterator lines = {sil};
	while (lines.pos < sil.len) {
		String line = string_split_iterator(&lines, '\n');
		if (string_starts_with(line, str_lit("sil ")) && swift_import_index(line, anchor) >= 0 && string_ends_with(line, convention)) return true;
	}
	return false;
}

gb_internal bool swift_import_set_scalar_layout(LLVMModuleRef module, LLVMTargetDataRef data, String sil, SwiftImportNominal *type, isize index) {
	auto storage = LLVMGetTypeByName2(LLVMGetModuleContext(module), "Ts15__RawSetStorageC");
	if (!storage || LLVMCountStructElementTypes(storage) != 9 || LLVMABISizeOfType(data, storage) != 56) return false;
	u64 offsets[] = {0, 16, 24, 32, 33, 34, 36, 40, 48};
	u64 sizes[] = {16, 8, 8, 1, 1, 2, 4, 8, 8};
	for (unsigned i = 0; i < gb_count_of(offsets); i++) {
		if (LLVMOffsetOfElement(data, storage, i) != offsets[i] || LLVMABISizeOfType(data, LLVMStructGetTypeAtIndex(storage, i)) != sizes[i]) return false;
	}
	char const *symbols[] = {
		"$ss10_NativeSetV8capacityAByxGSi_tcfC", "$sSh7_nativeShyxGs10_NativeSetVyxGn_tcfC",
		"$ss10_NativeSetV9hashTables05_HashD0Vvg", "$ss10_NativeSetV9_elementsSpyxGvg",
	};
	char const *ownership[] = {
		"(Int, @thin _NativeSet<τ_0_0>.Type) -> @owned _NativeSet<τ_0_0>",
		"(@owned _NativeSet<τ_0_0>, @thin Set<τ_0_0>.Type) -> @owned Set<τ_0_0>",
		"(@guaranteed _NativeSet<τ_0_0>) -> _HashTable",
		"(@guaranteed _NativeSet<τ_0_0>) -> UnsafeMutablePointer<τ_0_0>",
	};
	for (unsigned i = 0; i < gb_count_of(symbols); i++) {
		auto function = LLVMGetNamedFunction(module, symbols[i]);
		if (!function || !LLVMIsDeclaration(function) || LLVMGetFunctionCallConv(function) != LLVMSwiftCallConv || LLVMCountParams(function) != 3) return false;
		for (unsigned j = 0; j < 3; j++) {
			auto parameter = LLVMTypeOf(LLVMGetParam(function, j));
			bool integer = i == 0 && j == 0;
			if (LLVMGetTypeKind(parameter) != (integer ? LLVMIntegerTypeKind : LLVMPointerTypeKind)) return false;
			if (integer && LLVMGetIntTypeWidth(parameter) != 64) return false;
		}
		auto result = LLVMGetReturnType(LLVMGlobalGetValueType(function));
		if (i == 2) {
			if (LLVMGetTypeKind(result) != LLVMStructTypeKind || LLVMCountStructElementTypes(result) != 2) return false;
			if (LLVMGetTypeKind(LLVMStructGetTypeAtIndex(result, 0)) != LLVMPointerTypeKind) return false;
			auto mask = LLVMStructGetTypeAtIndex(result, 1);
			if (LLVMGetTypeKind(mask) != LLVMIntegerTypeKind || LLVMGetIntTypeWidth(mask) != 64) return false;
		} else if (LLVMGetTypeKind(result) != LLVMPointerTypeKind) return false;
		if (!swift_import_set_sil(sil, make_string_c(symbols[i]), make_string_c(ownership[i]))) return false;
	}
	String name = type->argument->name;
	char const *prefix = name == "UInt64" ? "$ss6UInt64V" : name == "Int64" ? "$ss5Int64V" : name == "Int" ? "$sSi" : name == "UInt" ? "$sSu" : name == "Double" ? "$sSd" : nullptr;
	if (!prefix) return false;
	type->set_hash = concatenate_strings(permanent_allocator(), make_string_c(prefix), str_lit("13_rawHashValue4seedS2i_tF"));
	char const *suffix = name == "Double" ? "7isEqual2toSbSd_tF" : name == "Int" ? "2eeoiySbSi_SitFZ" : name == "UInt" ? "2eeoiySbSu_SutFZ" : "2eeoiySbAB_ABtFZ";
	type->set_equal = concatenate_strings(permanent_allocator(), make_string_c(prefix), make_string_c(suffix));
	String hash_convention = make_string_c(gb_string_append_fmt(gb_string_make(temporary_allocator(), ""), "(Int, %.*s) -> Int", LIT(name)));
	String equal_convention = make_string_c(gb_string_append_fmt(gb_string_make(temporary_allocator(), ""), "(%.*s, %.*s%s%.*s%s) -> Bool", LIT(name), LIT(name), name == "Double" ? "" : ", @thin ", name == "Double" ? 0 : cast(int)name.len, name.text, name == "Double" ? "" : ".Type"));
	if (!swift_import_set_sil(sil, type->set_hash, hash_convention) || !swift_import_set_sil(sil, type->set_equal, equal_convention)) return false;
	auto hash = LLVMGetNamedFunction(module, alloc_cstring(temporary_allocator(), type->set_hash));
	gbString equal_name = gb_string_append_fmt(gb_string_make(temporary_allocator(), ""), "odin_swift_import_set_equal_%td", index);
	auto equal = LLVMGetNamedFunction(module, equal_name);
	// Equality is transparent in Swift and is inlined even at -Onone. Check its
	// SIL declaration and the concrete scalar lowering of the inspection call.
	for (unsigned i = 0; i < 2; i++) {
		auto function = i ? equal : hash;
		if (!function || LLVMGetFunctionCallConv(function) != LLVMSwiftCallConv || LLVMCountParams(function) != 2) return false;
		for (unsigned j = 0; j < 2; j++) {
			auto parameter = LLVMTypeOf(LLVMGetParam(function, j));
			bool floating = name == "Double" && (i || j);
			if (LLVMGetTypeKind(parameter) != (floating ? LLVMDoubleTypeKind : LLVMIntegerTypeKind)) return false;
			if (!floating && LLVMGetIntTypeWidth(parameter) != 64) return false;
		}
		auto result = LLVMGetReturnType(LLVMGlobalGetValueType(function));
		if (LLVMGetTypeKind(result) != LLVMIntegerTypeKind || LLVMGetIntTypeWidth(result) != (i ? 1 : 64)) return false;
	}
	return true;
}

gb_internal bool swift_import_set_layout(LLVMModuleRef module, LLVMTargetDataRef data, String sil, SwiftImportNominal *type, isize index) {
	gbString name = gb_string_append_fmt(gb_string_make(temporary_allocator(), ""), "odin_swift_import_set_%td", index);
	LLVMValueRef probe = LLVMGetNamedFunction(module, name);
	if (!probe || !type->set_array) return false;
	LLVMValueRef initializer = nullptr;
	for (auto block = LLVMGetFirstBasicBlock(probe); block; block = LLVMGetNextBasicBlock(block)) {
		for (auto instruction = LLVMGetFirstInstruction(block); instruction; instruction = LLVMGetNextInstruction(instruction)) {
			if (!LLVMIsACallInst(instruction)) continue;
			auto function = LLVMGetCalledValue(instruction);
			if (!LLVMIsAFunction(function) || make_string_c(LLVMGetValueName(function)) != "$sSh12arrayLiteralShyxGxd_tcfC") continue;
			if (initializer || !LLVMIsDeclaration(function) || LLVMGetFunctionCallConv(function) != LLVMSwiftCallConv || LLVMCountParams(function) != 3) return false;
			if (LLVMGetTypeKind(LLVMGetReturnType(LLVMGlobalGetValueType(function))) != LLVMPointerTypeKind) return false;
			for (unsigned i = 0; i < 3; i++) if (LLVMGetTypeKind(LLVMTypeOf(LLVMGetParam(function, i))) != LLVMPointerTypeKind) return false;
			initializer = function;
		}
	}
	if (!initializer) return false;
	type->set_scalar = type->argument->is_scalar && swift_import_set_scalar_layout(module, data, sil, type, index);
	type->set_initializer = copy_string(permanent_allocator(), make_string_c(LLVMGetValueName(initializer)));
	String convention = str_lit("(@owned Array<τ_0_0>, @thin Set<τ_0_0>.Type) -> @owned Set<τ_0_0>");
	String anchor = concatenate3_strings(permanent_allocator(), str_lit(" @"), type->set_initializer, str_lit(" : $@convention(method)"));
	String_Iterator lines = {sil};
	while (lines.pos < sil.len) {
		String line = string_split_iterator(&lines, '\n');
		if (string_starts_with(line, str_lit("sil ")) && swift_import_index(line, anchor) >= 0 && string_ends_with(line, convention)) return true;
	}
	return false;
}

gb_internal gbString swift_import_emit_set(gbString source, SwiftImportNominal *type) {
	SwiftImportType element = swift_import_nominal_type(type->argument);
	String name = type->name;
	String metadata = swift_import_metadata(element);
	gbString scalar = gb_string_make(temporary_allocator(), "");
	if (type->set_scalar) {
		source = gb_string_append_fmt(source,
			"@(private)\nforeign swift_library {\n"
			"\t@(link_name=\"%.*s\")\n\t_swift_%.*s_hash :: proc \"swift\" (seed: int, value: %s) -> int ---\n"
			"\t@(link_name=\"%.*s\")\n\t_swift_%.*s_equal :: proc \"swift\" (a, b: %s) -> bool ---\n}\n",
			LIT(type->set_hash), LIT(name), element.odin, LIT(type->set_equal), LIT(name), element.odin);
		scalar = gb_string_append_fmt(scalar,
			"\tif native, valid := swift.set_from_scalars(values, conformance, _swift_%.*s_hash, _swift_%.*s_equal); valid { return native, true }\n", LIT(name), LIT(name));
	}
	source = gb_string_append_fmt(source,
		"@(private)\nforeign swift_library {\n\t@(link_name=\"%.*s\")\n"
		"\t_swift_%.*s_construct :: proc \"swift\" (array, metadata, witness: rawptr) -> rawptr ---\n}\n"
		"@(private)\n_swift_%.*s_witness: rawptr\n"
		"@(private)\n_swift_%.*s_from :: proc(values: []%s) -> (result: swift.Native_Set, ok: bool) #optional_ok {\n"
		"\tif len(values) == 0 { return {swift.empty_set()}, true }\n"
		"\tconformance := swift.set_conformance_cached(&_swift_%.*s_witness, %.*s)\n\tif conformance.witness == nil { return }\n"
		"%s\tarray := %.*s or_return\n"
		"\treturn {_swift_%.*s_construct(array.storage, conformance.element, conformance.witness)}, true\n}\n\n",
		LIT(type->set_initializer), LIT(name), LIT(name), LIT(name), element.odin, LIT(name), LIT(metadata),
		scalar, LIT(swift_import_array_from(type->set_array, str_lit("values"))), LIT(name));
	return source;
}
