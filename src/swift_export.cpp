// Swift declarations describe native Swift-ABI entry points emitted by Odin.
// Nominal type metadata, value initializers and enum conformances use a Swift object.

struct SwiftExportProcedure {
	Entity *entity;
	String name, symbol, link_alias;
};

struct SwiftExportSymbol {
	Entity *entity;
	String name;
};

gb_global Array<SwiftExportSymbol> swift_export_symbols;
gb_global Array<SwiftExportProcedure> swift_export_procedures;
gb_global Array<Type *> swift_export_types;
gb_global Array<Type *> swift_export_optional_types;
gb_global String swift_export_directory;
gb_global String swift_export_object_directory;
gb_global Ast *swift_export_node;
gb_global bool swift_export_has_uuid;
gb_global bool swift_export_has_string;
gb_global String swift_export_uuid_getter;
gb_global String swift_export_uuid_initializer;

gb_internal String swift_export_name(String name, bool upper) {
	gbString result = gb_string_make(permanent_allocator(), "");
	bool capitalize = upper;
	for (isize i = 0; i < name.len; i++) {
		char c = name[i];
		if (c == '_') {
			capitalize = gb_string_length(result) != 0;
			continue;
		}
		if (gb_string_length(result) == 0) c = upper ? gb_char_to_upper(c) : gb_char_to_lower(c);
		else if (capitalize) c = gb_char_to_upper(c);
		result = gb_string_append_length(result, &c, 1);
		capitalize = false;
	}
	return make_string_c(result);
}

gb_internal char const *swift_export_integer(Type *raw) {
	if (raw == t_i8)   return "Swift.Int8";
	if (raw == t_u8)   return "Swift.UInt8";
	if (raw == t_i16)  return "Swift.Int16";
	if (raw == t_u16)  return "Swift.UInt16";
	if (raw == t_i32)  return "Swift.Int32";
	if (raw == t_u32)  return "Swift.UInt32";
	if (raw == t_i64)  return "Swift.Int64";
	if (raw == t_u64)  return "Swift.UInt64";
	if (raw == t_int)  return "Swift.Int";
	if (raw == t_uint) return "Swift.UInt";
	return nullptr;
}

gb_internal char const *swift_export_scalar(Type *type) {
	if (type == t_f32)  return "Swift.Float";
	if (type == t_f64)  return "Swift.Double";
	if (type == t_bool) return "Swift.Bool";
	return swift_export_integer(type);
}

gb_internal char const *swift_export_enum_raw_type(Type *type) {
	return swift_export_integer(base_type(base_type(type)->Enum.base_type));
}

// Verified against the target Swift compiler before emitting entry points.
// A single-case enum has no native argument or result component.
gb_internal Type *swift_export_enum_tag_type(Type *type) {
	isize count = base_type(type)->Enum.fields.count;
	if (count == 1) return nullptr;
	if (count <= 256) return t_u8;
	return t_u16;
}

gb_internal String swift_export_type_name(Type *type, bool escaped = false) {
	if (char const *name = swift_export_scalar(type)) return make_string_c(name);
	if (is_swift_uuid_type(type)) return str_lit("Foundation.UUID");
	if (type == t_string) return str_lit("Swift.String");
	if (Type *element = swift_export_optional_element(type)) {
		return concatenate_strings(permanent_allocator(), make_string_c(swift_export_scalar(element)), str_lit("?"));
	}
	if (is_type_slice(type)) {
		gbString name = gb_string_append_fmt(gb_string_make(permanent_allocator(), ""),
			"Swift.UnsafeMutableBufferPointer<%s>", swift_export_scalar(base_type(type)->Slice.elem));
		return make_string_c(name);
	}
	String name = swift_export_name(type->Named.name, true);
	return escaped ? concatenate3_strings(permanent_allocator(), str_lit("`"), name, str_lit("`")) : name;
}

gb_internal GB_COMPARE_PROC(swift_export_enum_value_compare) {
	Entity *x = *cast(Entity *const *)a;
	Entity *y = *cast(Entity *const *)b;
	return big_int_cmp(&x->Constant.value.value_integer, &y->Constant.value.value_integer);
}

gb_internal bool swift_export_check_type(Type *type, bool parameter) {
	if (swift_export_scalar(type)) return true;
	if (Type *element = swift_export_optional_element(type)) {
		for (Type *existing : swift_export_optional_types) if (existing == element) return true;
		array_add(&swift_export_optional_types, element);
		return true;
	}
	if (parameter && type == t_string) {
		swift_export_has_string = true;
		return true;
	}
	if (is_swift_uuid_type(type)) {
		swift_export_has_uuid = true;
		return true;
	}
	Type *bt = base_type(type);
	if (parameter && type == bt && bt->kind == Type_Slice) {
		return is_swift_abi_slice_parameter(type);
	}
	if (type->kind != Type_Named || !is_type_supported_by_swift_abi(type)) return false;
	for (Type *existing : swift_export_types) if (existing == type) return true;
	if (bt->kind == Type_Enum) {
		if (bt->Enum.fields.count == 0 || bt->Enum.fields.count > 65536) {
			error(type->Named.type_name->token, "Swift export: enums require between 1 and 65536 cases");
			return false;
		}
		auto fields = array_make<Entity *>(temporary_allocator());
		for (Entity *field : bt->Enum.fields) array_add(&fields, field);
		array_sort(fields, swift_export_enum_value_compare);
		for (isize i = 1; i < fields.count; i++) {
			if (compare_exact_values(Token_CmpEq, fields[i]->Constant.value, fields[i-1]->Constant.value)) {
				error(fields[i]->token, "Swift export: enum raw values must be unique");
				return false;
			}
		}
	} else if (bt->kind == Type_Struct) {
		// The target Swift compiler verifies field offsets and native lowering.
		for (Entity *field : bt->Struct.fields) {
			if ((!is_swift_abi_word_field(field->type) && field->type != t_bool) ||
			    !swift_export_scalar(field->type) || is_blank_ident(field->token)) return false;
		}
	} else return false;
	array_add(&swift_export_types, type);
	return true;
}

gb_internal GB_COMPARE_PROC(swift_export_procedure_compare) {
	auto x = cast(SwiftExportProcedure const *)a;
	auto y = cast(SwiftExportProcedure const *)b;
	return string_compare(x->name, y->name);
}

gb_internal GB_COMPARE_PROC(swift_export_type_compare) {
	return string_compare(swift_export_type_name(*cast(Type *const *)a), swift_export_type_name(*cast(Type *const *)b));
}

gb_internal bool is_swift_export_procedure(Checker *checker, Entity *e) {
	if (e->pkg != checker->info.init_package || e->kind != Entity_Procedure || !e->Procedure.is_export) return false;
	ProcCallingConvention cc = base_type(e->type)->Proc.calling_convention;
	return cc == ProcCC_Swift || cc == ProcCC_SwiftAsync;
}

gb_internal bool swift_export_check_types();

gb_internal bool swift_export_prepare(Checker *checker) {
	// Only static library builds produce a Swift module. Object/executable
	// builds keep their existing low-level foreign-entry behavior.
	if (build_context.build_mode == BuildMode_StaticLibrary) {
		for (Entity *e : checker->info.entities) {
			if (is_swift_export_procedure(checker, e)) {
				build_context.swift_export = true;
				break;
			}
		}
	}
	if (!build_context.swift_export) {
		if (build_context.swift_module_name.len) {
			gb_printf_err("-swift-module-name requires exported Swift procedures in a static library\n");
			return false;
		}
		return true;
	}
#if !defined(GB_SYSTEM_OSX) || LLVM_VERSION_MAJOR < 18
	gb_printf_err("Swift exports require a macOS host with Xcode and LLVM 18 or newer\n");
	return false;
#else
	if (build_context.metrics.os != TargetOs_darwin || build_context.metrics.arch != TargetArch_arm64 ||
	    build_context.build_mode != BuildMode_StaticLibrary || build_context.cached) {
		gb_printf_err("Swift exports require a Darwin arm64 static library without -internal-cached\n");
		return false;
	}
	if (!build_context.swift_module_name.len) {
		build_context.swift_module_name = concatenate_strings(permanent_allocator(), str_lit("Odin"), swift_export_name(checker->info.init_package->name, true));
	}
	if (!swift_import_identifier(build_context.swift_module_name) || build_context.swift_module_name == "Swift") {
		gb_printf_err("Invalid Swift export module name\n");
		return false;
	}
	String entry_prefix = concatenate3_strings(permanent_allocator(), str_lit("__odin_swift_"), build_context.swift_module_name, str_lit("_"));
	String helper_prefix = concatenate3_strings(permanent_allocator(), str_lit("__odin_swift_"), build_context.swift_module_name, str_lit("."));
	String metadata_prefix = make_string_c(gb_string_append_fmt(gb_string_make(permanent_allocator(), ""), "$s%td%.*s", build_context.swift_module_name.len, LIT(build_context.swift_module_name)));
	array_init(&swift_export_symbols, permanent_allocator());
	for (Entity *e : checker->info.entities) {
		String symbol = {};
		bool definition = false;
		if (e->kind == Entity_Procedure) {
			definition = !e->Procedure.is_foreign;
			symbol = e->Procedure.link_name;
			if (!symbol.len && (e->Procedure.is_export || e->Procedure.is_foreign)) symbol = e->token.string;
		} else if (e->kind == Entity_Variable) {
			definition = !e->Variable.is_foreign;
			symbol = e->Variable.link_name;
			if (!symbol.len && (e->Variable.is_export || e->Variable.is_foreign)) symbol = e->token.string;
		}
		if (symbol.len && definition) array_add(&swift_export_symbols, SwiftExportSymbol{e, symbol});
		if (symbol.len && (string_starts_with(symbol, entry_prefix) || string_starts_with(symbol, helper_prefix) || string_starts_with(symbol, metadata_prefix))) {
			error(e->token, "Swift export: link name '%.*s' uses the generated module's reserved namespace", LIT(symbol));
		}
	}
	array_init(&swift_export_procedures, permanent_allocator());
	array_init(&swift_export_types, permanent_allocator());
	array_init(&swift_export_optional_types, permanent_allocator());
	for (Entity *e : checker->info.entities) {
		if (!is_swift_export_procedure(checker, e)) continue;
		Type *type = base_type(e->type);
		bool valid = !type->Proc.is_polymorphic && !type->Proc.variadic && !type->Proc.c_vararg &&
		             !type->Proc.diverging && !type->Proc.return_by_pointer &&
		             type->Proc.calling_convention == ProcCC_Swift;
		bool adapted_value = false;
		for (isize i = 0; i < type->Proc.param_count; i++) {
			Entity *param = type->Proc.params->Tuple.variables[i];
			adapted_value |= param->type == t_string || swift_export_optional_element(param->type);
			valid &= !(param->flags & EntityFlags_SwiftABI) && swift_export_check_type(param->type, true);
		}
		for (isize i = 0; i < type->Proc.result_count; i++) {
			Entity *result = type->Proc.results->Tuple.variables[i];
			valid &= swift_export_check_type(result->type, false);
			adapted_value |= swift_export_optional_element(result->type) != nullptr;
			if (type->Proc.result_count == 1 || !result->token.string.len) continue;
			String label = swift_export_name(result->token.string, false);
			if (!swift_import_identifier(label)) error(result->token, "Swift export: invalid tuple result label after case conversion");
			for (isize j = 0; j < i; j++) {
				Entity *prev = type->Proc.results->Tuple.variables[j];
				if (prev->token.string.len && prev->token.string != "_" && label == swift_export_name(prev->token.string, false)) {
					error(result->token, "Swift export: tuple result label '%.*s' collides after case conversion", LIT(label));
				}
			}
		}
		if (!valid) {
			error(e->token, "Swift export: expected a synchronous Swift procedure without ABI parameter attributes, with supported numeric scalars, bool, integer enums, flat scalar structs, scalar Maybe values, uuid.Identifier, or borrowed string and scalar slice parameters, and supported result types");
			continue;
		}
		SwiftExportProcedure proc = {};
		proc.entity = e;
		proc.name = swift_export_name(e->token.string, false);
		proc.symbol = make_string_c(gb_string_append_fmt(gb_string_make(permanent_allocator(), ""), "__odin_swift_%.*s_%.*s", LIT(build_context.swift_module_name), LIT(proc.name)));
		if (adapted_value) {
			// The body uses Odin value storage. Expose the native Swift entry under
			// both the module name and the requested linker name.
			proc.link_alias = e->Procedure.link_name.len ? e->Procedure.link_name : e->token.string;
			e->Procedure.link_name = concatenate_strings(permanent_allocator(), proc.symbol, str_lit(".body"));
			e->Procedure.is_export = false;
		}
		for (auto const &other : swift_export_procedures) {
			if (other.name == proc.name) error(e->token, "Swift export: name '%.*s' collides after case conversion", LIT(proc.name));
		}
		if (!swift_import_identifier(proc.name)) error(e->token, "Swift export: invalid name after case conversion");

		array_add(&swift_export_procedures, proc);
	}
	for (Type *type : swift_export_types) {
		String name = swift_export_type_name(type);
		if (!swift_import_identifier(name)) error(type->Named.type_name->token, "Swift export: invalid type name after case conversion");
		if (name == "Swift" || (swift_export_has_uuid && name == "Foundation")) {
			error(type->Named.type_name->token, "Swift export: type '%.*s' shadows a module name; rename the type", LIT(name));
		} else if (name == build_context.swift_module_name) {
			error(type->Named.type_name->token, "Swift export: type '%.*s' shadows a module name; rename the type or select another -swift-module-name", LIT(name));
		}
		Slice<Entity *> fields = {};
		if (is_type_enum(type)) fields = {base_type(type)->Enum.fields.data, base_type(type)->Enum.fields.count};
		else fields = base_type(type)->Struct.fields;
		StringMap<Entity *> members = {};
		string_map_init(&members);
		defer (string_map_destroy(&members));
		for (Entity *field : fields) {
			String member = swift_export_name(field->token.string, false);
			if (string_map_get(&members, member)) {
				error(field->token, "Swift export: field '%.*s' collides after case conversion", LIT(field->token.string));
			} else string_map_set(&members, member, field);
			if (!swift_import_identifier(member)) error(field->token, "Swift export: invalid field name after case conversion");
		}
		for (Type *other : swift_export_types) {
			if (other != type && swift_export_type_name(other) == name) error(type->Named.type_name->token, "Swift export: duplicate type name '%.*s'", LIT(name));
		}
		for (auto const &proc : swift_export_procedures) {
			if (proc.name == name) error(proc.entity->token, "Swift export: procedure and type name collision");
		}
	}
	array_sort(swift_export_procedures, swift_export_procedure_compare);
	array_sort(swift_export_types, swift_export_type_compare);
	if (any_errors()) return false;
	if (!swift_export_procedures.count) {
		gb_printf_err("Swift export: no @(export) procedures in the initial package\n");
		return false;
	}
	if (swift_export_has_uuid && build_context.swift_module_name == "Foundation") {
		gb_printf_err("Swift export: module name 'Foundation' conflicts with UUID's module\n");
		return false;
	}
	swift_export_node = swift_export_procedures[0].entity->identifier;
	char *directory = alloc_cstring(permanent_allocator(), swift_import_path(temporary_directory(permanent_allocator()), "odin-swift-export-XXXXXX"));
	if (!mkdtemp(directory)) {
		gb_printf_err("Swift export: cannot create temporary directory\n");
		return false;
	}
	swift_export_directory = make_string_c(directory);
	if (!swift_import_directories.allocator.proc) array_init(&swift_import_directories, permanent_allocator());
	array_add(&swift_import_directories, swift_export_directory);
	swift_export_object_directory = swift_import_path(swift_export_directory, "objects");
	if (mkdir(alloc_cstring(permanent_allocator(), swift_export_object_directory), 0700) != 0) {
		gb_printf_err("Swift export: cannot create object directory: %s\n", strerror(errno));
		return false;
	}
	return swift_export_check_types();
#endif
}

gb_internal gbString swift_export_emit_enum(gbString source, Type *type) {
	String name = swift_export_type_name(type);
	source = gb_string_append_fmt(source, "@frozen public enum `%.*s`: %s {\n", LIT(name), swift_export_enum_raw_type(type));
	for (Entity *field : base_type(type)->Enum.fields) {
		String member = swift_export_name(field->token.string, false);
		gbString value = exact_value_to_string(field->Constant.value);
		source = gb_string_append_fmt(source, "\tcase `%.*s` = %s\n", LIT(member), value);
		gb_string_free(value);
	}
	return gb_string_appendc(source, "}\n");
}

gb_internal gbString swift_export_emit_struct(gbString source, Type *type) {
	String name = swift_export_type_name(type);
	source = gb_string_append_fmt(source, "@frozen public struct `%.*s` {\n", LIT(name));
	for (Entity *field : base_type(type)->Struct.fields) {
		String field_name = swift_export_name(field->token.string, false);
		source = gb_string_append_fmt(source, "\tpublic var `%.*s`: %s\n", LIT(field_name), swift_export_scalar(field->type));
	}
	source = gb_string_appendc(source, "\tpublic init(");
	isize index = 0;
	for (Entity *field : base_type(type)->Struct.fields) {
		String field_name = swift_export_name(field->token.string, false);
		source = gb_string_append_fmt(source, "%s`%.*s` p%td: %s", index ? ", " : "", LIT(field_name), index, swift_export_scalar(field->type));
		index++;
	}
	source = gb_string_appendc(source, ") {\n");
	index = 0;
	for (Entity *field : base_type(type)->Struct.fields) {
		String field_name = swift_export_name(field->token.string, false);
		source = gb_string_append_fmt(source, "\t\tself.`%.*s` = p%td\n", LIT(field_name), index++);
	}
	source = gb_string_appendc(source, "\t}\n}\n");
	return source;
}

#if defined(GB_SYSTEM_OSX)
#include <llvm-c/Transforms/PassBuilder.h>

// Read the constant stores made by Swift's assignment to an inout Optional.
// A Swift global may be initialized lazily, even when its value is a literal.
gb_internal bool swift_export_optional_case(LLVMTargetDataRef data, LLVMValueRef function, Type *element, isize index) {
	if (!function || LLVMCountParams(function) != 1 || LLVMCountBasicBlocks(function) != 1) return false;
	auto block = LLVMGetFirstBasicBlock(function);
	auto dest = LLVMGetParam(function, 0);
	unsigned size = cast(unsigned)type_size_of(element);
	unsigned extent = size + (element != t_bool);
	u8 bytes[9] = {}, known[9] = {};
	for (auto inst = LLVMGetFirstInstruction(block); inst; inst = LLVMGetNextInstruction(inst)) {
		switch (LLVMGetInstructionOpcode(inst)) {
		case LLVMGetElementPtr: case LLVMRet: break;
		case LLVMStore: {
			auto ptr = LLVMGetOperand(inst, 1);
			u64 offset = 0;
			auto value = LLVMGetOperand(inst, 0);
			if (!swift_import_pointer_offset(data, ptr, dest, &offset) || !LLVMIsAConstantInt(value)) return false;
			unsigned bits = LLVMGetIntTypeWidth(LLVMTypeOf(value));
			if (!bits || bits > 64 || offset >= extent || (bits+7)/8 > extent-offset) return false;
			u64 raw = LLVMConstIntGetZExtValue(value);
			for (unsigned bit = 0; bit < bits; bit += 8) {
				unsigned byte = cast(unsigned)offset + bit/8;
				known[byte] = cast(u8)((1u << gb_min(8u, bits-bit))-1);
				bytes[byte] = cast(u8)(raw >> bit) & known[byte];
			}
			break;
		}
		default: return false;
		}
	}
	if (element == t_bool) return known[0] == 0xff && bytes[0] == (index == 0 ? 2 : index-1);
	if (!(known[size]&1) || (bytes[size]&1) != (index == 0)) return false;
	if (index == 0) return true; // The absent case has no payload.
	u64 one = element == t_f32 ? 0x3f800000ull : element == t_f64 ? 0x3ff0000000000000ull : 1;
	u64 expected = index == 2 ? one : 0;
	for (unsigned i = 0; i < size; i++) {
		if (known[i] != 0xff || bytes[i] != cast(u8)(expected >> (8*i))) return false;
	}
	return true;
}

gb_internal bool swift_export_check_optional(LLVMModuleRef module, LLVMTargetDataRef data, Type *element, isize index) {
	auto name = [&](char const *suffix) -> char const * {
		return gb_string_append_fmt(gb_string_make(temporary_allocator(), ""), "odin_swift_optional_%td_%s", index, suffix);
	};
	LLVMValueRef function = LLVMGetNamedFunction(module, name("identity"));
	LLVMContextRef context = LLVMGetModuleContext(module);
	unsigned bits = cast(unsigned)type_size_of(element)*8;
	LLVMTypeRef word = LLVMIntTypeInContext(context, element == t_bool ? 8 : gb_min(bits*2, 64));
	bool wide = bits == 64;
	bool valid = function && LLVMGetFunctionCallConv(function) == LLVMSwiftCallConv &&
	             LLVMCountParams(function) == (wide ? 2u : 1u) && LLVMTypeOf(LLVMGetParam(function, 0)) == word;
	if (valid) {
		LLVMTypeRef result = LLVMGetReturnType(LLVMGlobalGetValueType(function));
		if (wide) {
			LLVMTypeRef tag = LLVMInt8TypeInContext(context);
			valid = LLVMTypeOf(LLVMGetParam(function, 1)) == tag && LLVMGetTypeKind(result) == LLVMStructTypeKind &&
			        LLVMCountStructElementTypes(result) == 2 && LLVMStructGetTypeAtIndex(result, 0) == word &&
			        LLVMStructGetTypeAtIndex(result, 1) == tag;
		} else valid = result == word;
	}
	if (!valid) {
		char *type = function ? LLVMPrintTypeToString(LLVMGlobalGetValueType(function)) : nullptr;
		error(swift_export_node, "Swift export: unsupported native Optional lowering for %s: %s",
		      swift_export_scalar(element), type ? type : "missing Swift identity probe");
		if (type) LLVMDisposeMessage(type);
		return false;
	}

	char const *cases[] = {"none", "zero", "one"};
	for (isize i = 0; i < gb_count_of(cases); i++) {
		auto probe = LLVMGetNamedFunction(module, name(cases[i]));
		if (!swift_export_optional_case(data, probe, element, i)) {
			char *ir = probe ? LLVMPrintValueToString(probe) : nullptr;
			error(swift_export_node, "Swift export: unsupported native Optional %s case for %s\n%s",
			      cases[i], swift_export_scalar(element), ir ? ir : "missing Swift case probe");
			if (ir) LLVMDisposeMessage(ir);
			return false;
		}
	}
	return true;
}
#endif

gb_internal bool swift_export_check_types() {
#if !defined(GB_SYSTEM_OSX)
	return false;
#else
	SwiftImportNominal uuid = {};
	uuid.swift_name = str_lit("Foundation.UUID");
	gbString source = gb_string_make(permanent_allocator(), "");
	if (swift_export_has_uuid) {
		source = gb_string_appendc(source, "import Foundation\n");
		source = swift_import_uuid_probe(source, &uuid, 0);
	}
	if (swift_export_has_string) {
		source = gb_string_appendc(source, "@_silgen_name(\"odin_swift_export_string\") public func string_probe(_ value: Swift.String) {}\n");
	}
	for_array(i, swift_export_optional_types) {
		Type *element = swift_export_optional_types[i];
		char const *type = swift_export_scalar(element);
		source = gb_string_append_fmt(source,
			"@_silgen_name(\"odin_swift_optional_%td_identity\") public func optional_%td(_ value: %s?) -> %s? { value }\n"
			"@_silgen_name(\"odin_swift_optional_%td_none\") public func optional_none_%td(_ p: inout %s?) { p = nil }\n"
			"@_silgen_name(\"odin_swift_optional_%td_zero\") public func optional_zero_%td(_ p: inout %s?) { p = %s }\n"
			"@_silgen_name(\"odin_swift_optional_%td_one\") public func optional_one_%td(_ p: inout %s?) { p = %s }\n",
			i, i, type, type, i, i, type, i, i, type, element == t_bool ? "false" : "0",
			i, i, type, element == t_bool ? "true" : "1");
	}
	auto records = array_make<SwiftImportNominal>(temporary_allocator(), swift_export_types.count);
	for_array(i, swift_export_types) {
		Type *type = swift_export_types[i];
		if (is_type_struct(type)) {
			source = swift_export_emit_struct(source, type);
			auto &record = records[i];
			record.is_record = record.is_frozen = true;
			record.swift_name = swift_export_type_name(type, true);
			array_init(&record.fields, temporary_allocator());
			for (Entity *field : base_type(type)->Struct.fields) {
				SwiftImportField item = {};
				item.swift_name = swift_export_name(field->token.string, false);
				for (auto const &scalar : swift_import_scalars) {
					if (make_string_c(scalar.type.swift) == make_string_c(swift_export_scalar(field->type))) item.type = scalar.type;
				}
				array_add(&record.fields, item);
			}
			source = gb_string_append_fmt(source,
				"@_silgen_name(\"odin_swift_import_load_%td\") public func load_%td(_ value: Swift.UnsafePointer<%.*s>) -> %.*s { value.pointee }\n"
				"@_silgen_name(\"odin_swift_import_layout_%td\") public func layout_%td() -> (Swift.Int, Swift.Int) { (Swift.MemoryLayout<%.*s>.size, Swift.MemoryLayout<%.*s>.alignment) }\n"
				"@_silgen_name(\"odin_swift_export_record_%td\") public func record_%td(_ value: %.*s) -> %.*s { value }\n",
				i, i, LIT(record.swift_name), LIT(record.swift_name), i, i, LIT(record.swift_name), LIT(record.swift_name),
				i, i, LIT(record.swift_name), LIT(record.swift_name));
			source = swift_import_struct_probe(source, &record, i);
			continue;
		}
		if (!is_type_enum(type)) continue;
		source = swift_export_emit_enum(source, type);
		String name = swift_export_type_name(type, true);
		source = gb_string_append_fmt(source,
			"@_silgen_name(\"odin_enum_echo_%td\") public func echo%td(_ value: %.*s) -> %.*s { value }\n",
			i, i, LIT(name), LIT(name));
		// Check both ends of the declaration-order tag sequence, independently
		// of the enum's raw values. The single-case functions return void.
		auto fields = base_type(type)->Enum.fields;
		for (isize j = 0; j < 2; j++) {
			isize index = j ? fields.count-1 : 0;
			String member = swift_export_name(fields[index]->token.string, false);
			source = gb_string_append_fmt(source,
				"@_silgen_name(\"odin_enum_case_%td_%td\") public func case%td_%td() -> %.*s { .`%.*s` }\n",
				i, j, i, j, LIT(name), LIT(member));
		}
	}
	for_array(i, swift_export_procedures) {
		Type *results = base_type(swift_export_procedures[i].entity->type)->Proc.results;
		if (!swift_abi_tuple_needs_layout(reduce_tuple_to_single_type(results))) continue;
		source = gb_string_append_fmt(source, "@_silgen_name(\"odin_tuple_%td\") public func tuple_%td() -> (", i, i);
		for_array(j, results->Tuple.variables) {
			if (j) source = gb_string_appendc(source, ", ");
			source = gb_string_appendc(source, swift_export_scalar(results->Tuple.variables[j]->type));
		}
		source = gb_string_appendc(source, ") { fatalError() }\n");
	}
	if (!gb_string_length(source)) return true;
	String dir = swift_export_directory;
	if (!swift_import_write(swift_export_node, swift_import_path(dir, "Types.swift"), source, true)) return false;
	auto args = array_make<String>(permanent_allocator());
	array_add(&args, str_lit("--sdk"));
	array_add(&args, selected_subtarget == Subtarget_iPhone ? str_lit("iphoneos") : selected_subtarget == Subtarget_iPhoneSimulator ? str_lit("iphonesimulator") : str_lit("macosx"));
	char const *flags[] = {"swiftc", "-parse-as-library", "-enable-library-evolution", "-Onone", "-emit-ir", "-target"};
	for (char const *flag : flags) array_add(&args, make_string_c(flag));
	array_add(&args, build_context.metrics.target_triplet);
	array_add(&args, str_lit("-module-name"));
	array_add(&args, build_context.swift_module_name);
	array_add(&args, str_lit("-module-cache-path"));
	array_add(&args, swift_import_path(temporary_directory(permanent_allocator()), "odin-swift-module-cache"));
	array_add(&args, swift_import_path(dir, "Types.swift"));
	array_add(&args, str_lit("-o"));
	array_add(&args, swift_import_path(dir, "Types.ll"));
	if (!swift_import_exec(swift_export_node, dir, args, nullptr, true)) return false;
	String sil = {};
	if (swift_export_has_uuid || swift_export_has_string) {
		for (auto &arg : args) {
			if (arg == "-emit-ir") arg = str_lit("-emit-silgen");
			if (arg == swift_import_path(dir, "Types.ll")) arg = swift_import_path(dir, "Types.sil");
		}
		if (!swift_import_exec(swift_export_node, dir, args, nullptr, true)) return false;
		sil = swift_import_read(swift_import_path(dir, "Types.sil"));
	}
	String ir = swift_import_read(swift_import_path(dir, "Types.ll"));
	LLVMContextRef context = LLVMContextCreate();
	defer (LLVMContextDispose(context));
	LLVMMemoryBufferRef buffer = LLVMCreateMemoryBufferWithMemoryRangeCopy(cast(char const *)ir.text, ir.len, "Swift type export");
	LLVMModuleRef module = nullptr;
	char *diagnostic = nullptr;
	if (LLVMParseIRInContext(context, buffer, &module, &diagnostic)) {
		error(swift_export_node, "Swift export: cannot inspect native type lowering: %s", diagnostic ? diagnostic : "invalid IR");
		LLVMDisposeMessage(diagnostic);
		return false;
	}
	defer (LLVMDisposeModule(module));
	LLVMTargetDataRef data = LLVMCreateTargetData(LLVMGetDataLayoutStr(module));
	defer (LLVMDisposeTargetData(data));
	if (swift_export_has_string) {
		LLVMValueRef probe = LLVMGetNamedFunction(module, "odin_swift_export_string");
		String signature = str_lit(" @odin_swift_export_string : $@convention(thin) (@guaranteed String) -> () {");
		if (!probe || LLVMGetFunctionCallConv(probe) != LLVMSwiftCallConv || LLVMCountParams(probe) != 2 ||
		    LLVMTypeOf(LLVMGetParam(probe, 0)) != LLVMInt64TypeInContext(context) ||
		    LLVMGetTypeKind(LLVMTypeOf(LLVMGetParam(probe, 1))) != LLVMPointerTypeKind ||
		    !swift_import_has_line(sil, signature, false)) {
			error(swift_export_node, "Swift export: unsupported native String lowering or ownership");
			return false;
		}
	}
	if (swift_export_has_uuid) {
		if (!swift_import_uuid_layout(module, sil, &uuid, 0)) {
			error(swift_export_node, "Swift export: unsupported native UUID lowering or ownership");
			return false;
		}
		swift_export_uuid_getter = uuid.uuid_getter;
		swift_export_uuid_initializer = uuid.uuid_initializer;
	}
	for_array(i, swift_export_types) {
		Type *type = swift_export_types[i];
		if (is_type_struct(type)) {
			auto &record = records[i];
			swift_import_struct_layout(module, data, &record, i);
			bool valid = record.projected && record.stride == cast(u64)gb_max(i64(1), type_size_of(type)) &&
			             record.alignment == cast(u64)type_align_of(type);
			for_array(j, record.fields) valid &= record.fields[j].offset == cast(u64)type_offset_of(type, j);
			SwiftABIRecordComponent components[4];
			isize count = swift_abi_record_components(type, components, gb_count_of(components));
			gbString name = gb_string_append_fmt(gb_string_make(temporary_allocator(), ""), "odin_swift_export_record_%td", i);
			LLVMValueRef echo = LLVMGetNamedFunction(module, name);
			valid &= echo && LLVMGetFunctionCallConv(echo) == LLVMSwiftCallConv;
			if (echo && count > gb_count_of(components)) {
				valid &= record.components.count == 0 && LLVMCountParams(echo) == 2 &&
				         LLVMGetTypeKind(LLVMGetReturnType(LLVMGlobalGetValueType(echo))) == LLVMVoidTypeKind;
				valid &= swift_import_struct_parameter(echo, 0, &record, true) && swift_import_struct_parameter(echo, 1, &record, false);
			} else if (echo) {
				valid &= record.components.count == count && LLVMCountParams(echo) == cast(unsigned)count;
				LLVMTypeRef result = LLVMGetReturnType(LLVMGlobalGetValueType(echo));
				for (isize j = 0; j < count && valid; j++) {
					Type *field = base_type(components[j].type);
					LLVMTypeRef expected = field == t_bool ? LLVMInt1TypeInContext(context) : field == t_f64 ? LLVMDoubleTypeInContext(context) :
					                       LLVMIntTypeInContext(context, cast(unsigned)type_size_of(field)*8);
					LLVMTypeRef returned = count == 1 ? result : LLVMGetTypeKind(result) == LLVMStructTypeKind && LLVMCountStructElementTypes(result) == count ? LLVMStructGetTypeAtIndex(result, cast(unsigned)j) : nullptr;
					valid &= LLVMTypeOf(LLVMGetParam(echo, cast(unsigned)j)) == expected && returned == expected;
				}
			}
			if (!valid) error(type->Named.type_name->token, "Swift export: unsupported native record layout or lowering for '%.*s'", LIT(type->Named.name));
			continue;
		}
		if (!is_type_enum(type)) continue;
		isize count = base_type(type)->Enum.fields.count;
		unsigned bits = count == 1 ? 0 : count <= 256 ? 8 : 16;
		LLVMTypeRef component = bits ? LLVMIntTypeInContext(context, bits) : LLVMVoidTypeInContext(context);
		gbString name = gb_string_append_fmt(gb_string_make(temporary_allocator(), ""), "odin_enum_echo_%td", i);
		LLVMValueRef echo = LLVMGetNamedFunction(module, name);
		bool valid = echo && LLVMGetFunctionCallConv(echo) == LLVMSwiftCallConv &&
		             LLVMGetReturnType(LLVMGlobalGetValueType(echo)) == component && LLVMCountParams(echo) == (bits ? 1 : 0);
		if (valid && bits) valid = LLVMTypeOf(LLVMGetParam(echo, 0)) == component;
		for (isize j = 0; j < 2; j++) {
			name = gb_string_append_fmt(gb_string_make(temporary_allocator(), ""), "odin_enum_case_%td_%td", i, j);
			LLVMValueRef function = LLVMGetNamedFunction(module, name);
			valid &= function && LLVMGetFunctionCallConv(function) == LLVMSwiftCallConv &&
			         LLVMCountParams(function) == 0 && LLVMGetReturnType(LLVMGlobalGetValueType(function)) == component;
			if (function && bits) {
				LLVMValueRef value = swift_import_return(function);
				valid &= value && LLVMIsAConstantInt(value) && LLVMConstIntGetZExtValue(value) == cast(u64)(j ? count-1 : 0);
			}
		}
		if (!valid) error(type->Named.type_name->token, "Swift export: unsupported native enum lowering for '%.*s'", LIT(type->Named.name));
	}
	for_array(i, swift_export_procedures) {
		Entity *e = swift_export_procedures[i].entity;
		Type *results = base_type(e->type)->Proc.results;
		if (!swift_abi_tuple_needs_layout(reduce_tuple_to_single_type(results))) continue;
		gbString name = gb_string_append_fmt(gb_string_make(temporary_allocator(), ""), "odin_tuple_%td", i);
		LLVMValueRef probe = LLVMGetNamedFunction(module, name);
		char *actual = probe ? LLVMPrintTypeToString(LLVMGetReturnType(LLVMGlobalGetValueType(probe))) : nullptr;
		String expected = make_string_c(swift_abi_tuple_result_llvm(results));
		bool indirect = expected == "void";
		bool valid = actual && make_string_c(actual) == expected && LLVMGetFunctionCallConv(probe) == LLVMSwiftCallConv &&
		             LLVMCountParams(probe) == (indirect ? 1u : 0u) && (!indirect || swift_abi_tuple_storage(probe, data, results));
		if (actual) LLVMDisposeMessage(actual);
		if (!valid) error(e->token, "Swift export: unsupported native tuple result lowering for '%.*s'", LIT(e->token.string));
	}
	if (swift_export_optional_types.count) {
		// Inspect the other probes first. Canonicalize only after their
		// unoptimized bodies have supplied the record and enum layouts.
		auto options = LLVMCreatePassBuilderOptions();
		defer (LLVMDisposePassBuilderOptions(options));
		if (auto failure = LLVMRunPasses(module, "sroa,instcombine", nullptr, options)) {
			char *message = LLVMGetErrorMessage(failure);
			error(swift_export_node, "Swift export: cannot inspect Optional cases: %s", message);
			LLVMDisposeErrorMessage(message);
			return false;
		}
		for_array(i, swift_export_optional_types) {
			if (!swift_export_check_optional(module, data, swift_export_optional_types[i], i)) return false;
		}
	}
	return !any_errors();
#endif
}

#if defined(GB_SYSTEM_OSX)
#include <sys/file.h>

// Stage on the destination volume. An exchange keeps the previous version
// in staging until all three publications have succeeded.
gb_internal bool swift_export_publish(String dir, String output, String module, String interface) {
	auto a = temporary_allocator();
	String parent = directory_from_path(output);
	if (!parent.len) parent = str_lit(".");
	int dst = open(alloc_cstring(a, parent), O_RDONLY|O_DIRECTORY);
	if (dst < 0) {
		gb_printf_err("Swift export: cannot open '%.*s': %s\n", LIT(parent), strerror(errno));
		return false;
	}
	defer (close(dst));
	if (flock(dst, LOCK_EX) != 0) {
		gb_printf_err("Swift export: cannot lock '%.*s': %s\n", LIT(parent), strerror(errno));
		return false;
	}
	char *stage = alloc_cstring(a, swift_import_path(parent, ".odin-swift-XXXXXX"));
	if (!mkdtemp(stage)) {
		gb_printf_err("Swift export: cannot stage files in '%.*s': %s\n", LIT(parent), strerror(errno));
		return false;
	}
	bool keep_stage = false;
	defer (if (!keep_stage) removefile(stage, nullptr, REMOVEFILE_RECURSIVE));
	int tmp = open(stage, O_RDONLY|O_DIRECTORY);
	if (tmp < 0) {
		gb_printf_err("Swift export: cannot open '%s': %s\n", stage, strerror(errno));
		return false;
	}
	defer (close(tmp));
	char const *names[] = {alloc_cstring(a, module), alloc_cstring(a, interface), alloc_cstring(a, filename_without_directory(output))};
	struct stat info[3] = {};
	bool exists[3] = {};
	for (isize i = 0; i < 3; i++) {
		String from = swift_import_path(dir, i == 2 ? "exports.a" : names[i]);
		String to = swift_import_path(make_string_c(stage), names[i]);
		if (copyfile(alloc_cstring(a, from), alloc_cstring(a, to), nullptr, COPYFILE_DATA|COPYFILE_EXCL) != 0) {
			gb_printf_err("Swift export: cannot stage '%s': %s\n", names[i], strerror(errno));
			return false;
		}
		if (fstatat(dst, names[i], &info[i], AT_SYMLINK_NOFOLLOW) != 0) {
			if (errno == ENOENT) continue;
			gb_printf_err("Swift export: cannot inspect '%s': %s\n", names[i], strerror(errno));
			return false;
		}
		if (!S_ISREG(info[i].st_mode)) {
			gb_printf_err("Swift export: expected a regular file at '%s'\n", names[i]);
			return false;
		}
		exists[i] = true;
		for (isize j = 0; j < i; j++) {
			if (exists[j] && info[i].st_dev == info[j].st_dev && info[i].st_ino == info[j].st_ino) {
				gb_printf_err("Swift export: '%s' and '%s' refer to the same file\n", names[j], names[i]);
				return false;
			}
		}
	}
	for (isize i = 0; i < 3; i++) {
		if (renameatx_np(tmp, names[i], dst, names[i], exists[i] ? RENAME_SWAP : RENAME_EXCL) == 0) continue;
		gb_printf_err("Swift export: cannot publish '%s': %s\n", names[i], strerror(errno));
		while (i > 0) {
			i--;
			if (renameatx_np(dst, names[i], tmp, names[i], exists[i] ? RENAME_SWAP : RENAME_EXCL) != 0) {
				gb_printf_err("Swift export: cannot restore '%s': %s; recovery files in '%s'\n", names[i], strerror(errno), stage);
				keep_stage = true;
			}
		}
		return false;
	}
	return true;
}
#endif

gb_internal bool swift_export_link(Array<String> const &objects) {
#if !defined(GB_SYSTEM_OSX)
	return false;
#else
	gbString source = gb_string_make(permanent_allocator(), "// Generated by Odin.\n");
	if (swift_export_has_uuid) source = gb_string_appendc(source, "import Foundation\n");
	for (Type *type : swift_export_types) {
		if (is_type_enum(type)) {
			source = swift_export_emit_enum(source, type);
			continue;
		}
		source = swift_export_emit_struct(source, type);
	}
	for (auto const &proc : swift_export_procedures) {
		Type *type = base_type(proc.entity->type);
		source = gb_string_append_fmt(source, "@_silgen_name(\"%.*s\")\npublic func `%.*s`(", LIT(proc.symbol), LIT(proc.name));
		for (isize i = 0; i < type->Proc.param_count; i++) {
			String name = swift_export_type_name(type->Proc.params->Tuple.variables[i]->type, true);
			source = gb_string_append_fmt(source, "%s_ p%td: %.*s", i ? ", " : "", i, LIT(name));
		}
		source = gb_string_appendc(source, ")");
		if (type->Proc.result_count == 1) {
			source = gb_string_append_fmt(source, " -> %.*s", LIT(swift_export_type_name(type->Proc.results->Tuple.variables[0]->type, true)));
		} else if (type->Proc.result_count > 1) {
			source = gb_string_appendc(source, " -> (");
			for_array(i, type->Proc.results->Tuple.variables) {
				Entity *result = type->Proc.results->Tuple.variables[i];
				if (i) source = gb_string_appendc(source, ", ");
				if (result->token.string.len && result->token.string != "_") {
					source = gb_string_append_fmt(source, "`%.*s`: ", LIT(swift_export_name(result->token.string, false)));
				}
				source = gb_string_append_fmt(source, "%.*s", LIT(swift_export_type_name(result->type, true)));
			}
			source = gb_string_appendc(source, ")");
		}
		source = gb_string_appendc(source, "\n");
	}
	String dir = swift_export_directory;
	if (!swift_import_write(swift_export_node, swift_import_path(dir, "Exports.swift"), source, true)) return false;
	String module = build_context.swift_module_name;
	String module_file = concatenate_strings(permanent_allocator(), module, str_lit(".swiftmodule"));
	String interface_file = concatenate_strings(permanent_allocator(), module, str_lit(".swiftinterface"));
	auto args = array_make<String>(permanent_allocator());
	array_add(&args, str_lit("--sdk"));
	array_add(&args, selected_subtarget == Subtarget_iPhone ? str_lit("iphoneos") : selected_subtarget == Subtarget_iPhoneSimulator ? str_lit("iphonesimulator") : str_lit("macosx"));
	array_add(&args, str_lit("swiftc"));
	array_add(&args, str_lit("-target"));
	array_add(&args, build_context.metrics.target_triplet);
	array_add(&args, str_lit("-module-cache-path"));
	array_add(&args, swift_import_path(temporary_directory(permanent_allocator()), "odin-swift-module-cache"));
	array_add(&args, build_context.optimization_level > 0 ? str_lit("-O") : str_lit("-Onone"));
	if (build_context.ODIN_DEBUG) array_add(&args, str_lit("-g"));
	if (build_context.sanitizer_flags & SanitizerFlag_Address) array_add(&args, str_lit("-sanitize=address"));
	array_add(&args, str_lit("-parse-as-library"));
	array_add(&args, str_lit("-enable-library-evolution"));
	array_add(&args, str_lit("-module-name"));
	array_add(&args, module);
	array_add(&args, str_lit("-emit-module-path"));
	array_add(&args, swift_import_path(dir, alloc_cstring(permanent_allocator(), module_file)));
	array_add(&args, str_lit("-emit-module-interface-path"));
	array_add(&args, swift_import_path(dir, alloc_cstring(permanent_allocator(), interface_file)));
	array_add(&args, str_lit("-emit-object"));
	array_add(&args, str_lit("-o"));
	array_add(&args, swift_import_path(dir, "types.o"));
	array_add(&args, swift_import_path(dir, "Exports.swift"));
	if (!swift_import_exec(swift_export_node, dir, args, nullptr, true)) return false;
	// The Swift compiler can also emit shared helper names outside its mangled
	// module namespace. Do not let an Odin data/function symbol replace one.
	array_clear(&args);
	array_add(&args, str_lit("nm"));
	array_add(&args, str_lit("-gUj"));
	array_add(&args, swift_import_path(dir, "types.o"));
	String symbols = {};
	if (!swift_import_exec(swift_export_node, dir, args, &symbols, true)) return false;
	for (auto const &symbol : swift_export_symbols) {
		String name = concatenate_strings(permanent_allocator(), str_lit("_"), symbol.name);
		String_Iterator it = {symbols};
		while (it.pos < symbols.len) {
			if (string_split_iterator(&it, '\n') == name) {
				error(symbol.entity->token, "Swift export: link name '%.*s' conflicts with a Swift-generated symbol", LIT(symbol.name));
			}
		}
	}
	if (any_errors()) return false;
	array_clear(&args);
	array_add(&args, str_lit("ar"));
	array_add(&args, str_lit("rcs"));
	String archive = swift_import_path(dir, "exports.a");
	array_add(&args, archive);
	for (String object : objects) array_add(&args, object);
	array_add(&args, swift_import_path(dir, "types.o"));
	if (!swift_import_exec(swift_export_node, dir, args, nullptr, true)) return false;
	String output = path_to_string(permanent_allocator(), build_context.build_paths[BuildPath_Output]);
	return swift_export_publish(dir, output, module_file, interface_file);
#endif
}
