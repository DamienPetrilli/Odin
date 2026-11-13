// Swift declarations describe native Swift-ABI entry points emitted by Odin.
// Only nominal type metadata and value initializers require a Swift object.

struct SwiftExportProcedure {
	Entity *entity;
	String name, symbol;
};

struct SwiftExportSymbol {
	Entity *entity;
	String name;
};

gb_global Array<SwiftExportSymbol> swift_export_symbols;
gb_global Array<SwiftExportProcedure> swift_export_procedures;
gb_global Array<Type *> swift_export_types;
gb_global String swift_export_directory;
gb_global Ast *swift_export_node;

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

gb_internal char const *swift_export_scalar(Type *type) {
	if (type == t_i64)  return "Swift.Int64";
	if (type == t_u64)  return "Swift.UInt64";
	if (type == t_f64)  return "Swift.Double";
	if (type == t_bool) return "Swift.Bool";
	return nullptr;
}

gb_internal String swift_export_type_name(Type *type, bool escaped = false) {
	if (char const *name = swift_export_scalar(type)) return make_string_c(name);
	if (is_type_slice(type)) {
		gbString name = gb_string_append_fmt(gb_string_make(permanent_allocator(), ""),
			"Swift.UnsafeMutableBufferPointer<%s>", swift_export_scalar(base_type(type)->Slice.elem));
		return make_string_c(name);
	}
	String name = swift_export_name(type->Named.name, true);
	return escaped ? concatenate3_strings(permanent_allocator(), str_lit("`"), name, str_lit("`")) : name;
}

gb_internal bool swift_export_check_type(Type *type, bool parameter) {
	if (swift_export_scalar(type)) return true;
	Type *bt = base_type(type);
	if (parameter && type == bt && bt->kind == Type_Slice) {
		return swift_export_scalar(bt->Slice.elem) != nullptr && bt->Slice.elem != t_bool;
	}
	if (type->kind != Type_Named || bt->kind != Type_Struct || !is_type_supported_by_swift_abi(type)) return false;
	// Full-width trivial fields have identical offsets, size and stride.
	for (Entity *field : bt->Struct.fields) {
		if (!swift_export_scalar(field->type) || field->type == t_bool || is_blank_ident(field->token)) return false;

	}
	for (Type *existing : swift_export_types) if (existing == type) return true;
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
	for (Entity *e : checker->info.entities) {
		if (!is_swift_export_procedure(checker, e)) continue;
		Type *type = base_type(e->type);
		bool valid = !type->Proc.is_polymorphic && !type->Proc.variadic && !type->Proc.c_vararg &&
		             !type->Proc.diverging && !type->Proc.return_by_pointer && type->Proc.result_count <= 1 &&
		             type->Proc.calling_convention == ProcCC_Swift;
		for (isize i = 0; i < type->Proc.param_count; i++) {
			Entity *param = type->Proc.params->Tuple.variables[i];
			valid &= !(param->flags & EntityFlags_SwiftABI) && swift_export_check_type(param->type, true);
		}
		if (type->Proc.result_count) valid &= swift_export_check_type(type->Proc.results->Tuple.variables[0]->type, false);
		if (!valid) {
			error(e->token, "Swift export: expected a synchronous Swift procedure without ABI parameter attributes, with i64, u64, f64, bool, flat scalar structs, or borrowed scalar slice parameters, and at most one scalar/struct result");
			continue;
		}
		SwiftExportProcedure proc = {};
		proc.entity = e;
		proc.name = swift_export_name(e->token.string, false);
		proc.symbol = make_string_c(gb_string_append_fmt(gb_string_make(permanent_allocator(), ""), "__odin_swift_%.*s_%.*s", LIT(build_context.swift_module_name), LIT(proc.name)));
		for (auto const &other : swift_export_procedures) {
			if (other.name == proc.name) error(e->token, "Swift export: name '%.*s' collides after case conversion", LIT(proc.name));
		}
		if (!swift_import_identifier(proc.name)) error(e->token, "Swift export: invalid name after case conversion");

		array_add(&swift_export_procedures, proc);
	}
	for (Type *type : swift_export_types) {
		String name = swift_export_type_name(type);
		if (!swift_import_identifier(name)) error(type->Named.type_name->token, "Swift export: invalid type name after case conversion");
		if (name == "Swift") {
			error(type->Named.type_name->token, "Swift export: type 'Swift' shadows a module name; rename the type");
		} else if (name == build_context.swift_module_name) {
			error(type->Named.type_name->token, "Swift export: type '%.*s' shadows a module name; rename the type or select another -swift-module-name", LIT(name));
		}
		for (Entity *field : base_type(type)->Struct.fields) {
			for (Entity *other : base_type(type)->Struct.fields) {
				if (field != other && swift_export_name(field->token.string, false) == swift_export_name(other->token.string, false)) {
					error(field->token, "Swift export: field '%.*s' collides after case conversion", LIT(field->token.string));
				}
			}
			if (!swift_import_identifier(swift_export_name(field->token.string, false))) error(field->token, "Swift export: invalid field name after case conversion");
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
	swift_export_node = swift_export_procedures[0].entity->identifier;
	char *directory = alloc_cstring(permanent_allocator(), swift_import_path(temporary_directory(permanent_allocator()), "odin-swift-export-XXXXXX"));
	if (!mkdtemp(directory)) {
		gb_printf_err("Swift export: cannot create temporary directory\n");
		return false;
	}
	swift_export_directory = make_string_c(directory);
	if (!swift_import_directories.allocator.proc) array_init(&swift_import_directories, permanent_allocator());
	array_add(&swift_import_directories, swift_export_directory);
	return true;
#endif
}

gb_internal bool swift_export_link(Array<String> const &objects) {
#if !defined(GB_SYSTEM_OSX)
	return false;
#else
	gbString source = gb_string_make(permanent_allocator(), "// Generated by Odin.\n");
	for (Type *type : swift_export_types) {
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
	}
	for (auto const &proc : swift_export_procedures) {
		Type *type = base_type(proc.entity->type);
		source = gb_string_append_fmt(source, "@_silgen_name(\"%.*s\")\npublic func `%.*s`(", LIT(proc.symbol), LIT(proc.name));
		for (isize i = 0; i < type->Proc.param_count; i++) {
			String name = swift_export_type_name(type->Proc.params->Tuple.variables[i]->type, true);
			source = gb_string_append_fmt(source, "%s_ p%td: %.*s", i ? ", " : "", i, LIT(name));
		}
		source = gb_string_appendc(source, ")");
		if (type->Proc.result_count) source = gb_string_append_fmt(source, " -> %.*s", LIT(swift_export_type_name(type->Proc.results->Tuple.variables[0]->type, true)));
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
	String output_dir = directory_from_path(output);
	String files[] = {module_file, interface_file, str_lit("exports.a")};
	for (isize i = 0; i < 3; i++) {
		String from = swift_import_path(dir, alloc_cstring(permanent_allocator(), files[i]));
		String to = i == 2 ? output : swift_import_path(output_dir, alloc_cstring(permanent_allocator(), files[i]));
		if (!gb_file_copy(alloc_cstring(permanent_allocator(), from), alloc_cstring(permanent_allocator(), to), false)) {
			gb_printf_err("Swift export: cannot write '%.*s'\n", LIT(to));
			return false;
		}
	}
	return true;
#endif
}
