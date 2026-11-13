// Swift modules are inspected at build time. Only the original library is
// linked; the inspection source and its IR never become application code.

#if defined(GB_SYSTEM_OSX)
#include <spawn.h>
#include <sys/wait.h>
#include <removefile.h>
#include <llvm-c/Core.h>
#include <llvm-c/IRReader.h>
#include <llvm-c/Target.h>

extern char **environ;

struct SwiftImportPackage {
	String module, path, library;
	String directory;
	Array<String> unsupported;
	bool framework;
};

struct SwiftImportNominal;

enum SwiftImportValueKind {
	SwiftImportValue_Opaque,
	SwiftImportValue_String,
	SwiftImportValue_Array,
	SwiftImportValue_Set,
};

struct SwiftImportType {
	char const *swift;
	char const *odin;
	char const *llvm;
	SwiftImportNominal *nominal;
};

struct SwiftImportField {
	String name;
	SwiftImportType type;
};

struct SwiftImportCase {
	String name, symbol;
	Array<SwiftImportField> fields;
	bool has_payload, available;
	u32 tag;
};

struct SwiftImportNominal {
	String name, swift_name, usr, symbol, mangled;
	String generic_parent, generic_suffix;
	JsonValue *declaration;
	SwiftImportNominal *argument;
	Array<SwiftImportCase> cases;
	Array<SwiftImportType> components;
	u64 size, alignment;
	bool projected, owns, resolving, resolved, static_metadata;
	SwiftImportValueKind kind;
	bool supported, is_enum, is_frozen, is_template, is_optional, is_scalar;
};

struct SwiftImportParameter {
	String name, label;
	SwiftImportType type;
	bool empty_set;
	bool consumed;
};

struct SwiftImportFunction {
	String name, title, symbol, odin_name, base_name;
	SwiftImportNominal *owner;
	Array<SwiftImportParameter> parameters;
	SwiftImportType result;
	bool is_async;
	bool is_throwing;
	bool is_mutating;
	bool is_static;
	bool is_property;
	bool is_initializer;
	bool is_main_actor;
	bool is_collection;
};

gb_internal bool swift_import_indirect(SwiftImportType const &type);
gb_internal bool swift_import_owns(SwiftImportType const &type);

gb_global BlockingMutex swift_import_mutex;
gb_global Array<SwiftImportPackage> swift_import_packages;
gb_global Array<String> swift_import_directories;

gb_internal JsonValue *swift_import_member(JsonValue *value, char const *key) {
	if (value && value->kind == Json_Object) {
		for (auto const &entry : value->object) {
			if (entry.key == make_string_c(key)) return entry.value;
		}
	}
	return nullptr;
}

gb_internal String swift_import_string(JsonValue *value, char const *key) {
	value = swift_import_member(value, key);
	return value && value->kind == Json_String ? value->string : String{};
}

gb_internal Slice<JsonValue *> swift_import_array(JsonValue *value, char const *key) {
	value = swift_import_member(value, key);
	return value && value->kind == Json_Array ? value->array : Slice<JsonValue *>{};
}

gb_internal bool swift_import_identifier(String value) {
	if (value.len == 0 || !(gb_char_is_alpha(value[0]) || value[0] == '_')) return false;
	for (isize i = 0; i < value.len; i++) {
		u8 c = value[i];
		if (!(gb_char_is_alphanumeric(c) || c == '_')) return false;
	}
	return true;
}

gb_internal isize swift_import_index(String text, String part) {
	for (isize i = 0; i <= text.len-part.len; i++) {
		if (substring(text, i, i+part.len) == part) return i;
	}
	return -1;
}

// These names are used unqualified by the generated Odin declarations.
// A foreign declaration must not change their meaning or calling convention.
gb_internal bool swift_import_reserved_name(String name) {
	char const *reserved[] = {
		"_", "context", "nil", "true", "false", "intrinsics", "runtime", "swift_library", "swift", "main",
		"bool", "int", "rawptr", "string", "u8", "u16", "u32", "u64", "i64", "f64", "Maybe", "mem", "strings",
	};
	for (auto value : reserved) if (name == make_string_c(value)) return true;
	if (string_starts_with(name, str_lit("_swift_"))) return true;
	for (isize i = Token__KeywordBegin+1; i < Token__KeywordEnd; i++) {
		if (name == token_strings[i]) return true;
	}
	for (auto const &proc : builtin_procs) {
		if (proc.pkg == BuiltinProcPkg_builtin && name == proc.name) return true;
	}
	return false;
}

gb_internal String swift_import_name(String name, bool parameter = false) {
	gbString result = gb_string_make(permanent_allocator(), "");
	for (isize i = 0; i < name.len; i++) {
		if (i > 0 && (name[i] >= 'A' && name[i] <= 'Z') && ((name[i-1] >= 'a' && name[i-1] <= 'z') || gb_char_is_digit(name[i-1]))) {
			result = gb_string_appendc(result, "_");
		}
		char c = gb_char_to_lower(name[i]);
		result = gb_string_append_length(result, &c, 1);
	}
	String s = make_string_c(result);
	bool reserved = swift_import_reserved_name(s);
	reserved |= parameter && (s == "completion" || s == "receiver" || s == "task" || s == "ok" ||
	                          s == "entry" || s == "resumed" || s == "invoke");
	if (reserved) result = gb_string_appendc(result, "_");
	return make_string_c(result);
}

gb_internal String swift_import_path(String directory, char const *name) {
	return concatenate3_strings(permanent_allocator(), directory, str_lit("/"), make_string_c(name));
}

gb_internal String swift_import_read(String path) {
	gbFileContents contents = gb_file_read_contents(permanent_allocator(), true, alloc_cstring(permanent_allocator(), path));
	return make_string(cast(u8 *)contents.data, contents.size);
}

gb_internal bool swift_import_write(Ast *node, String path, gbString text, bool exporting = false) {
	char const *label = exporting ? "Swift export" : "Swift import";
	gbFile file = {};
	if (gb_file_create(&file, alloc_cstring(permanent_allocator(), path)) != gbFileError_None) {
		syntax_error(node, "%s: could not create '%.*s'", label, LIT(path));
		return false;
	}
	bool ok = gb_file_write(&file, text, gb_string_length(text));
	gb_file_close(&file);
	if (!ok) syntax_error(node, "%s: could not write '%.*s'", label, LIT(path));
	return ok;
}

// Use an argument vector, not a shell command. SDK/module/library paths may
// contain spaces or shell metacharacters. Parsing workers may run concurrently.
gb_internal bool swift_import_exec(Ast *node, String directory, Array<String> const &args, String *output, bool exporting = false) {
	char const *label = exporting ? "Swift export" : "Swift import";
	u64 started = time_stamp_time_now();
	defer (if (build_context.show_more_timings) {
		gb_printf_err("%s %.*s: %.3f s\n", exporting ? "Swift export" : "Swift inspection", LIT(args[0]), cast(f64)(time_stamp_time_now()-started)/time_stamp__freq());
	});
	auto argv = array_make<char *>(permanent_allocator());
	array_add(&argv, cast(char *)"/usr/bin/xcrun");
	for (String arg : args) array_add(&argv, alloc_cstring(permanent_allocator(), arg));
	array_add(&argv, cast(char *)nullptr);
	String out_path = swift_import_path(directory, "command.out");
	String err_path = swift_import_path(directory, "command.err");
	posix_spawn_file_actions_t actions;
	int status = posix_spawn_file_actions_init(&actions);
	if (status != 0) {
		syntax_error(node, "%s: cannot initialize tool process: %s", label, strerror(status));
		return false;
	}
	defer (posix_spawn_file_actions_destroy(&actions));
	status = posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, alloc_cstring(permanent_allocator(), out_path), O_CREAT|O_WRONLY|O_TRUNC, 0600);
	if (status == 0) status = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, alloc_cstring(permanent_allocator(), err_path), O_CREAT|O_WRONLY|O_TRUNC, 0600);
	pid_t pid = 0;
	if (status == 0) status = posix_spawn(&pid, argv[0], &actions, nullptr, argv.data, environ);
	if (status != 0) {
		syntax_error(node, "%s: cannot run Xcode tool: %s", label, strerror(status));
		return false;
	}
	int wait_status = 0;
	while (waitpid(pid, &wait_status, 0) < 0) {
		if (errno == EINTR) continue;
		syntax_error(node, "%s: cannot wait for Xcode tool: %s", label, strerror(errno));
		return false;
	}
	if (!WIFEXITED(wait_status) || WEXITSTATUS(wait_status) != 0) {
		String message = swift_import_read(err_path);
		message.len = gb_min(message.len, 4096);
		syntax_error(node, "%s: %.*s failed\n%.*s", label, LIT(args[0]), LIT(message));
		return false;
	}
	if (output) *output = swift_import_read(out_path);
	return true;
}

gb_internal JsonValue *swift_import_json(Ast *node, String text) {
	JsonValue *result = nullptr;
	JsonError error = {};
	if (!json_parse(permanent_allocator(), text, &result, &error)) {
		syntax_error(node, "Swift import: invalid tool JSON (%d:%d): %s", error.line, error.column, error.message);
		return nullptr;
	}
	return result;
}

gb_internal bool swift_import_slice(SwiftImportNominal *type) {
	return type && type->kind == SwiftImportValue_Array &&
	       (type->argument->is_scalar || type->argument->kind == SwiftImportValue_String);
}

gb_internal char const *swift_import_slice_element(SwiftImportNominal *type) {
	String name = type->argument->name;
	return name == "UInt64" ? "u64" : name == "Int64" ? "i64" : name == "Double" ? "f64" : "string";
}

gb_internal SwiftImportType swift_import_nominal_type(SwiftImportNominal *type) {
	if (type->is_scalar) {
		char const *odin = type->name == "UInt64" ? "u64" : type->name == "Int64" ? "i64" : "f64";
		return {alloc_cstring(permanent_allocator(), type->swift_name), odin, type->name == "Double" ? "double" : "i64", type};
	}
	char const *odin = type->kind == SwiftImportValue_String ? "string" : alloc_cstring(permanent_allocator(), type->name);
	if (swift_import_slice(type)) odin = gb_string_appendc(gb_string_make(permanent_allocator(), "[]"), swift_import_slice_element(type));
	char const *llvm = type->kind == SwiftImportValue_String ? "{ i64, ptr }" : type->kind == SwiftImportValue_Opaque ? "ptr noalias" : "ptr";
	return {alloc_cstring(permanent_allocator(), type->swift_name), odin, llvm, type};
}

gb_internal bool swift_import_named_type(String usr, SwiftImportType *type, Array<SwiftImportNominal *> const &types) {
	if (usr == "s:s6UInt64V") *type = {"Swift.UInt64", "u64", "i64", nullptr};
	else if (usr == "s:s5Int64V") *type = {"Swift.Int64", "i64", "i64", nullptr};
	else if (usr == "s:Sd") *type = {"Swift.Double", "f64", "double", nullptr};
	else {
		for (SwiftImportNominal *nominal : types) {
			if (nominal->usr == usr && !nominal->is_template && !nominal->argument) {
				*type = swift_import_nominal_type(nominal);
				return true;
			}
		}
		return false;
	}
	return true;
}

gb_internal SwiftImportNominal *swift_import_string_type(Array<SwiftImportNominal *> *types) {
	for (auto type : *types) if (type->kind == SwiftImportValue_String) return type;
	auto type = gb_alloc_item(permanent_allocator(), SwiftImportNominal);
	*type = {};
	type->name = str_lit("String");
	type->swift_name = str_lit("Swift.String");
	type->usr = str_lit("s:SS");
	type->mangled = str_lit("SS");
	type->kind = SwiftImportValue_String;
	array_add(types, type);
	return type;
}

gb_internal bool swift_import_container_type(String usr, SwiftImportType parameter, SwiftImportType *type, Array<SwiftImportNominal *> *types) {
	// Nested projected arrays need recursive ownership and failure handling.
	if (swift_import_slice(parameter.nominal) && usr != "s:Sq") return false;
	bool optional = usr == "s:Sq";
	bool array = usr == "s:Sa";
	bool set = usr == "s:Sh";

	SwiftImportNominal *base = nullptr;
	for (auto candidate : *types) {
		if (candidate->usr != usr) continue;
		if (candidate->argument == parameter.nominal) {
			*type = swift_import_nominal_type(candidate);
			return true;
		}
		if (candidate->is_template) base = candidate;
	}
	if (!optional && !array && !set && !base) return false;
	auto instance = gb_alloc_item(permanent_allocator(), SwiftImportNominal);
	*instance = {};
	String builtin_name = optional ? str_lit("Optional") : array ? str_lit("Array") : set ? str_lit("Set") : String{};
	String base_name = builtin_name.len ? builtin_name : base->name;
	String swift_name = builtin_name.len ? concatenate_strings(permanent_allocator(), str_lit("Swift."), builtin_name) : base->swift_name;
	instance->name = concatenate3_strings(permanent_allocator(), base_name, str_lit("_"), parameter.nominal->name);
	instance->swift_name = concatenate4_strings(permanent_allocator(), swift_name, str_lit("<"), parameter.nominal->swift_name, str_lit(">"));
	instance->usr = usr;
	instance->declaration = builtin_name.len ? nullptr : base->declaration;
	if (base && base->generic_parent.len) {
		instance->swift_name = make_string_c(gb_string_append_fmt(gb_string_make(permanent_allocator(), ""), "%.*s<%.*s>%.*s", LIT(base->generic_parent), LIT(parameter.nominal->swift_name), LIT(base->generic_suffix)));
		String parent_name = substring(base->name, 0, base->name.len-base->generic_suffix.len+2);
		instance->name = make_string_c(gb_string_append_fmt(gb_string_make(permanent_allocator(), ""), "%.*s_%.*s_%.*s", LIT(parent_name), LIT(parameter.nominal->name), LIT(substring(base->generic_suffix, 2, base->generic_suffix.len-1))));
	}
	instance->argument = parameter.nominal;
	instance->is_enum = optional || !builtin_name.len;
	instance->is_frozen = builtin_name.len || base->is_frozen;
	instance->is_optional = optional;
	instance->kind = array ? SwiftImportValue_Array : set ? SwiftImportValue_Set : SwiftImportValue_Opaque;
	array_add(types, instance);
	*type = swift_import_nominal_type(instance);
	return true;
}

// Resolve concrete SDK types. An instantiated enum or collection remains a
// Swift runtime type; this does not implement unrestricted Swift generics.
gb_internal bool swift_import_api_type(JsonValue *api, SwiftImportType *type, Array<SwiftImportNominal *> *types, SwiftImportNominal *argument = nullptr) {
	auto children = swift_import_array(api, "children");
	String kind = swift_import_string(api, "kind");
	String name = swift_import_string(api, "name");
	if (kind == "TypeNameAlias" && children.count == 1) return swift_import_api_type(children[0], type, types, argument);
	if (kind != "TypeNominal") return false;
	String usr = swift_import_string(api, "usr");
	if (name == "GenericTypeParam" && !usr.len && argument) {
		*type = swift_import_nominal_type(argument);
		return true;
	}
	if (usr == "s:SS" && children.count == 0) {
		*type = swift_import_nominal_type(swift_import_string_type(types));
		return true;
	}
	if (children.count == 0) {
		if (argument) {
			for (auto candidate : *types) {
				if (candidate->usr == usr && candidate->is_template && candidate->generic_parent.len) {
					return swift_import_container_type(usr, swift_import_nominal_type(argument), type, types);
				}
			}
		}
		return swift_import_named_type(usr, type, *types);
	}
	if (children.count != 1) return false;
	SwiftImportType parameter = {};
	if (!swift_import_api_type(children[0], &parameter, types, argument)) return false;
	if (!parameter.nominal) {
		if ((usr != "s:Sa" && usr != "s:Sq") || !parameter.swift) return false;
		String swift_name = make_string_c(parameter.swift);
		String name = substring(swift_name, 6, swift_name.len);
		for (auto candidate : *types) if (candidate->is_scalar && candidate->name == name) parameter.nominal = candidate;
		if (!parameter.nominal) {
			auto scalar = gb_alloc_item(permanent_allocator(), SwiftImportNominal);
			*scalar = {};
			scalar->name = name;
			scalar->swift_name = swift_name;
			scalar->is_scalar = true;
			array_add(types, scalar);
			parameter.nominal = scalar;
		}
	}
	return swift_import_container_type(usr, parameter, type, types);
}

gb_internal bool swift_import_type(Slice<JsonValue *> fragments, bool result, SwiftImportType *type, Array<SwiftImportNominal *> const &types) {
	gbString spelling = gb_string_make(permanent_allocator(), "");
	String usr = {};
	isize count = 0;
	for (JsonValue *fragment : fragments) {
		String part = swift_import_string(fragment, "spelling");
		spelling = gb_string_append_length(spelling, part.text, part.len);
		if (swift_import_string(fragment, "kind") == "typeIdentifier") {
			usr = swift_import_string(fragment, "preciseIdentifier");
			count++;
		}
	}
	String text = make_string_c(spelling);
	if (result && (text.len == 0 || text == "()" ||
	    ((text == "Void" || text == "Swift.Void") && usr == "s:s4Voida"))) return true;
	if (count == 0) return false;
	if (!swift_import_named_type(usr, type, types)) return false;
	for (isize i = 0; i < text.len; i++) {
		if (text[i] == ':') {
			text = substring(text, i+1, text.len);
			break;
		}
	}
	text = string_trim_whitespace(text);
	if (type->nominal) {
		// The precise identifier resolves qualification; reject modifiers such
		// as inout, consuming, optionals or generic arguments in this subset.
		for (isize i = 0; i < text.len; i++) {
			u8 c = text[i];
			if (!(gb_char_is_alphanumeric(c) || c == '_' || c == '.')) return false;
		}
		return text.len != 0;
	}
	String swift_name = make_string_c(type->swift);
	return text == swift_name || text == substring(swift_name, 6, swift_name.len);
}

gb_internal bool swift_import_function(JsonValue *symbol, JsonValue *api, SwiftImportFunction *fn, Array<SwiftImportNominal *> *types) {
	fn->name = swift_import_string(api, "name");
	fn->title = swift_import_string(swift_import_member(symbol, "names"), "title");
	fn->symbol = swift_import_string(api, "mangledName");
	if (!swift_import_identifier(fn->name) || !string_starts_with(fn->symbol, str_lit("$s")) ||
	    fn->symbol.len <= 2) return false;
	for (isize i = 2; i < fn->symbol.len; i++) {
		if (!(gb_char_is_alphanumeric(fn->symbol[i]) || fn->symbol[i] == '_')) return false;
	}
	String collection_parameter = {};
	if (auto generics = swift_import_member(symbol, "swiftGenerics")) {
		auto parameters = swift_import_array(generics, "parameters");
		auto constraints = swift_import_array(generics, "constraints");
		if (parameters.count != 1 || constraints.count != 2) return false;
		collection_parameter = swift_import_string(parameters[0], "name");
		if (!swift_import_identifier(collection_parameter)) return false;
		bool collection = false, strings = false;
		String element = concatenate_strings(permanent_allocator(), collection_parameter, str_lit(".Element"));
		for (auto constraint : constraints) {
			String kind = swift_import_string(constraint, "kind");
			String lhs = swift_import_string(constraint, "lhs");
			String rhs = swift_import_string(constraint, "rhsPrecise");
			collection |= kind == "conformance" && lhs == collection_parameter && rhs == "s:Sl";
			strings |= kind == "sameType" && lhs == element && rhs == "s:SS";
		}
		if (!collection || !strings) return false;
		fn->is_collection = true;
	} else if (swift_import_member(api, "genericSig")) return false;
	for (auto fragment : swift_import_array(symbol, "declarationFragments")) {
		fn->is_main_actor |= swift_import_string(fragment, "preciseIdentifier") == "s:ScM" && swift_import_string(fragment, "kind") == "attribute";
	}
	for (auto attribute : swift_import_array(api, "declAttributes")) {
		if (attribute->kind != Json_String) return false;
		String name = attribute->string;
		if (name != "Available" && !(fn->is_property && name == "HasStorage") && !(fn->is_main_actor && name == "Custom")) return false;
	}
	gbString declaration = gb_string_make(permanent_allocator(), "");
	for (JsonValue *fragment : swift_import_array(symbol, "declarationFragments")) {
		String word = swift_import_string(fragment, "spelling");
		declaration = gb_string_append_length(declaration, word.text, word.len);
		if (swift_import_string(fragment, "kind") == "attribute") {
			if (!fn->is_main_actor || (word != "@" && swift_import_string(fragment, "preciseIdentifier") != "s:ScM")) return false;
		} else if (string_contains_char(word, '@')) {
			return false;
		}
		if (swift_import_string(fragment, "kind") == "keyword") {
			if (word == "async") fn->is_async = true;
			else if (word == "throws") fn->is_throwing = true;
			else if (word == "mutating") fn->is_mutating = true;
			else if (word != "func" && word != "static" && !(fn->is_collection && word == "where") &&
			         !(fn->is_property && (word == "var" || word == "let" || word == "get" || word == "set")) &&
			         !(fn->is_initializer && word == "init")) return false;
		}
	}
	if (fn->is_main_actor && !fn->is_async) return false;
	if (fn->is_collection && (!fn->is_async || fn->is_initializer || fn->is_property || (fn->owner && !fn->is_static))) return false;
	if (fn->is_throwing && (!fn->is_async || swift_import_index(make_string_c(declaration), str_lit("throws(")) >= 0 ||
	                       swift_import_index(make_string_c(declaration), str_lit("throws (")) >= 0)) return false;
	fn->odin_name = swift_import_name(fn->name);
	array_init(&fn->parameters, permanent_allocator());
	if (fn->is_property) {
		auto children = swift_import_array(api, "children");
		if (children.count != 1) return false;
		return swift_import_api_type(children[0], &fn->result, types);
	}
	auto api_types = swift_import_array(api, "children");
	JsonValue *signature = swift_import_member(symbol, "functionSignature");
	JsonValue *returns = swift_import_member(signature, "returns");
	if (fn->is_initializer) {
		fn->result = {alloc_cstring(permanent_allocator(), fn->owner->swift_name), alloc_cstring(permanent_allocator(), fn->owner->name), "ptr noalias", fn->owner};
		// API digester names the initializing entry; calls use the allocating
		// entry. Both the inspected IR and library exports must confirm it.
		if (!string_ends_with(fn->symbol, str_lit("cfc"))) return false;
		fn->symbol = concatenate_strings(permanent_allocator(), substring(fn->symbol, 0, fn->symbol.len-1), str_lit("C"));
	} else if (!returns || returns->kind != Json_Array || returns->array.count == 0 ||
	           (!swift_import_type(returns->array, true, &fn->result, *types) &&
	            (api_types.count == 0 || !swift_import_api_type(api_types[0], &fn->result, types)))) {
		return false;
	}
	// A UTF-8 result needs an Odin allocation after completion. Keep that
	// failure separate from Swift throws before exposing asynchronous strings.
	if (fn->is_async && fn->result.nominal && fn->result.nominal->kind == SwiftImportValue_String) return false;
	if (!string_starts_with(fn->title, fn->name) || fn->title.len < fn->name.len+2 ||
	    fn->title[fn->name.len] != '(' || fn->title[fn->title.len-1] != ')') {
		return false;
	}
	String labels = substring(fn->title, fn->name.len+1, fn->title.len-1);
	String_Iterator it = {labels};
	auto parameters = swift_import_array(signature, "parameters");
	if (fn->is_collection && parameters.count != 1) return false;
	for (JsonValue *parameter : parameters) {
		SwiftImportParameter p = {};
		String name = swift_import_string(parameter, "name");
		if (!swift_import_identifier(name)) return false;
		p.name = swift_import_name(name, true);
		p.label = string_split_iterator(&it, ':');
		if (!swift_import_identifier(p.label)) return false;
		if (fn->is_collection) {
			if (api_types.count != 2 || swift_import_string(api_types[1], "name") != "GenericTypeParam" || swift_import_string(api_types[1], "printedName") != collection_parameter) return false;
			if (!swift_import_container_type(str_lit("s:Sa"), swift_import_nominal_type(swift_import_string_type(types)), &p.type, types)) return false;
		} else if (!swift_import_type(swift_import_array(parameter, "declarationFragments"), false, &p.type, *types) &&
		    (api_types.count <= fn->parameters.count+1 || !swift_import_api_type(api_types[fn->parameters.count+1], &p.type, types))) return false;
		if (p.type.nominal && p.type.nominal->kind == SwiftImportValue_Set) {
			// Only the SDK's explicit empty default is synthesized. Arbitrary
			// Set construction needs separate Hashable and ownership support.
			auto default_arg = api_types.count == 2 ? swift_import_member(api_types[1], "hasDefaultArg") : nullptr;
			p.empty_set = parameters.count == 1 && default_arg && default_arg->kind == Json_Boolean && default_arg->boolean &&
			              swift_import_index(make_string_c(declaration), str_lit("= []")) >= 0;
			if (!p.empty_set) return false;
		}
		for (auto const &previous : fn->parameters) if (previous.name == p.name) return false;
		array_add(&fn->parameters, p);
	}
	return it.pos == labels.len;
}

gb_internal bool swift_import_has_line(String text, String wanted, bool prefix) {
	String_Iterator it = {text};
	while (it.pos < text.len) {
		String line = string_split_iterator(&it, '\n');
		if (prefix ? string_starts_with(line, wanted) : string_ends_with(line, wanted)) return true;
	}
	return false;
}

// Register lowering does not describe ownership. In particular, an initializer
// consumes its String argument while an ordinary function normally borrows it.
// Read the imported declaration's SIL convention instead of inferring it from
// the source spelling or treating every native pointer as borrowed.
gb_internal bool swift_import_ownership(String sil, SwiftImportFunction *fn) {
	String anchor = concatenate3_strings(permanent_allocator(), str_lit(" @"), fn->symbol, str_lit(" : $@convention("));
	String_Iterator lines = {sil};
	while (lines.pos < sil.len) {
		String line = string_split_iterator(&lines, '\n');
		if (!string_starts_with(line, str_lit("sil "))) continue;
		isize match = swift_import_index(line, anchor);
		if (match < 0) continue;
		isize begin = match+anchor.len;
		while (begin < line.len && line[begin] != ')') begin++;
		while (begin < line.len && line[begin] != '(') begin++;
		if (begin == line.len) return false;
		isize end = begin+1;
		while (end < line.len && line[end] != ')') end++;
		if (end == line.len) return false;
		String_Iterator parameters = {substring(line, begin+1, end)};
		for (auto &param : fn->parameters) {
			if (parameters.pos >= parameters.str.len) return false;
			String argument = string_trim_whitespace(string_split_iterator(&parameters, ','));
			if (!param.type.nominal) continue;
			if (!swift_import_owns(param.type)) continue;
			bool indirect = swift_import_indirect(param.type) || fn->is_collection;
			param.consumed = string_starts_with(argument, indirect ? str_lit("@in ") : str_lit("@owned "));
			bool borrowed = string_starts_with(argument, indirect ? str_lit("@in_guaranteed ") : str_lit("@guaranteed "));
			if (!param.consumed && !borrowed) return false;
		}
		if (swift_import_owns(fn->result)) {
			String result = string_trim_whitespace(substring(line, end+1, line.len));
			String convention = swift_import_indirect(fn->result) ? str_lit("@out ") : str_lit("@owned ");
			if (swift_import_index(result, convention) < 0) return false;
		}
		return true;
	}
	return false;
}

gb_internal String swift_import_concrete_metadata(String ir, isize index) {
	gbString anchor = gb_string_append_fmt(gb_string_make(permanent_allocator(), ""), "define swiftcc ptr @odin_swift_import_metadata_%td(", index);
	String_Iterator lines = {ir};
	bool inside = false;
	while (lines.pos < ir.len) {
		String line = string_split_iterator(&lines, '\n');
		if (string_starts_with(line, make_string_c(anchor))) inside = true;
		if (!inside) continue;
		if (line == "}") break;
		if (swift_import_index(line, str_lit("@__swift_instantiateConcreteTypeFromMangledName")) < 0) continue;
		isize begin = swift_import_index(line, str_lit("ptr @\"$s"));
		if (begin < 0) continue;
		String tail = substring(line, begin+8, line.len);
		isize end = swift_import_index(tail, str_lit("Md\""));
		if (end > 0) {
			String name = substring(tail, 0, end);
			for (isize i = 0; i < name.len; i++) {
				if (!gb_char_is_alphanumeric(name[i]) && name[i] != '_') return {};
			}
			return name;
		}
	}
	return {};
}

gb_internal String swift_import_relative(String directory, String path) {
	gbString text = gb_string_make(permanent_allocator(), "");
	String_Iterator it = {directory};
	String part;
	while (string_split_iterator_next(&it, '/', &part)) text = gb_string_appendc(text, "../");
	text = gb_string_append_length(text, path.text+1, path.len-1);
	return make_string_c(text);
}

gb_internal JsonValue *swift_import_find_api(JsonValue *api, String usr) {
	if (swift_import_member(api, "declKind") && swift_import_string(api, "usr") == usr) return api;
	for (JsonValue *child : swift_import_array(api, "children")) {
		if (JsonValue *found = swift_import_find_api(child, usr)) return found;
	}
	return nullptr;
}

gb_internal bool swift_import_available(JsonValue *symbol) {
	char const *domain = selected_subtarget == Subtarget_Default ? "macOS" : "iOS";
	int minimum[3] = {};
	sscanf(alloc_cstring(temporary_allocator(), build_context.minimum_os_version_string), "%d.%d.%d", minimum, minimum+1, minimum+2);
	for (JsonValue *availability : swift_import_array(symbol, "availability")) {
		String availability_domain = swift_import_string(availability, "domain");
		if (availability_domain.len && availability_domain != "*" && availability_domain != make_string_c(domain)) continue;
		if (swift_import_member(availability, "isUnconditionallyUnavailable") ||
		    swift_import_member(availability, "isUnconditionallyDeprecated")) return false;
		JsonValue *introduced = swift_import_member(availability, "introduced");
		char const *keys[] = {"major", "minor", "patch"};
		for (isize i = 0; i < 3; i++) {
			JsonValue *part = swift_import_member(introduced, keys[i]);
			int version = part && part->kind == Json_Number ? cast(int)part->number : 0;
			if (version != minimum[i]) {
				if (version > minimum[i]) return false;
				break;
			}
		}
		if (swift_import_member(availability, "deprecated") || swift_import_member(availability, "obsoleted")) return false;
	}
	return true;
}

gb_internal bool swift_import_has_receiver(SwiftImportFunction const &fn) {
	return fn.owner && !fn.is_static && !fn.is_initializer;
}

gb_internal bool swift_import_kind(SwiftImportType const &type, SwiftImportValueKind kind) {
	return type.nominal && type.nominal->kind == kind;
}

gb_internal bool swift_import_string_array(SwiftImportType const &type) {
	return swift_import_kind(type, SwiftImportValue_Array) && type.nominal->argument->kind == SwiftImportValue_String;
}

#include "swift_import_enum.cpp"

gb_internal gbString swift_import_emit_type(gbString source, SwiftImportNominal *type) {
	if (type->is_scalar) return source;
	String name = type->name;
	if (!type->projected && type->kind != SwiftImportValue_String && !swift_import_slice(type)) source = gb_string_append_fmt(source,
		"// Typed address of a Swift value. Assignment aliases; copy creates an owned value.\n"
		"%.*s :: distinct rawptr\n", LIT(name));
	if (type->static_metadata) {
		source = gb_string_append_fmt(source, "@(private)\nforeign swift_library {\n\t@(link_name=\"%.*sN\")\n\t_swift_%.*s_metadata_value: u8\n}\n@(private)\n_swift_%.*s_metadata :: proc(_: u64) -> swift.Metadata_Response {return {&_swift_%.*s_metadata_value, 0}}\n", LIT(type->symbol), LIT(name), LIT(name), LIT(name));
	} else if (type->mangled.len) {
		source = gb_string_append_fmt(source, "@(private)\n_swift_%.*s_metadata_cache: rawptr\n@(private)\n_swift_%.*s_metadata :: proc(_: u64) -> swift.Metadata_Response {\n\treturn {swift.metadata_from_name_cached(&_swift_%.*s_metadata_cache, \"%.*s\"), 0}\n}\n", LIT(name), LIT(name), LIT(name), LIT(type->mangled));
	} else {
		source = gb_string_append_fmt(source,
			"@(private)\nforeign swift_library {\n\t@(link_name=\"%.*sMa\")\n"
			"\t_swift_%.*s_metadata :: proc \"swift\" (request: u64) -> swift.Metadata_Response ---\n}\n", LIT(type->symbol), LIT(name));
	}
	if (type->projected) return swift_import_emit_enum(source, type);
	if (type->kind == SwiftImportValue_String || swift_import_slice(type)) return source;
	source = gb_string_append_fmt(source,
		"@(require_results)\n%.*s_copy :: proc(value: %.*s) -> (copy: %.*s, ok: bool) #optional_ok {\n"
		"\tstorage := swift.value_copy(rawptr(value), _swift_%.*s_metadata(0).type) or_return\n"
		"\treturn %.*s(storage), true\n}\n"
		"%.*s_destroy :: proc(value: %.*s) {\n\tswift.value_destroy(rawptr(value), _swift_%.*s_metadata(0).type)\n}\n\n",
		LIT(name), LIT(name), LIT(name), LIT(name), LIT(name), LIT(name), LIT(name), LIT(name));
	if (type->kind == SwiftImportValue_Array && type->argument->supported) {
		auto element = type->argument;
		char const *result = element->kind == SwiftImportValue_String ? "string" : alloc_cstring(permanent_allocator(), element->name);
		source = gb_string_append_fmt(source,
			"%.*s_count :: proc(value: %.*s) -> int {\n\tassert(value != nil)\n\treturn swift.array_count(rawptr(value), _swift_%.*s_metadata(0).type)\n}\n"
			"@(require_results)\n%.*s_get :: proc(value: %.*s, index: int) -> (result: %s, ok: bool) #optional_ok {\n"
			"\tif value == nil { return }\n\tmetadata := _swift_%.*s_metadata(0).type\n"
			"\tstorage := swift.value_allocate(metadata) or_return\n"
			"\tif !swift.array_get(storage, rawptr(value), metadata, index) {\n\t\tswift.value_free_uninitialized(storage)\n\t\treturn\n\t}\n",
			LIT(name), LIT(name), LIT(element->name), LIT(name), LIT(name), result, LIT(element->name));
		if (element->kind == SwiftImportValue_String) {
			source = gb_string_appendc(source, "\tdefer swift.value_destroy(storage, metadata)\n\treturn swift.string_to_odin((cast(^swift.Native_String)storage)^)\n}\n");
		} else if (element->projected) source = gb_string_append_fmt(source, "\tdefer swift.value_free_uninitialized(storage)\n\treturn _swift_%.*s_take(storage)\n}\n", LIT(element->name));
		else source = gb_string_append_fmt(source, "\treturn %s(storage), true\n}\n", result);
	}
	return gb_string_appendc(source, "\n");
}

// The generated procedures are compiler implementation details. They use the
// same checked native conventions as handwritten foreign declarations, but
// keep layout, allocator ownership and continuation state out of application
// code. Only the original Swift symbol is called.
gb_internal char const *swift_import_native_type(SwiftImportType const &type) {
	if (swift_import_projected(type)) return swift_import_enum_native(type.nominal);
	if (swift_import_kind(type, SwiftImportValue_String)) return "swift.Native_String";
	return type.nominal ? "rawptr" : type.odin;
}

gb_internal gbString swift_import_emit_value_function(gbString source, SwiftImportFunction const &fn) {
	bool receiver = swift_import_has_receiver(fn);
	bool indirect_result = swift_import_indirect(fn.result);
	bool string_result = swift_import_kind(fn.result, SwiftImportValue_String);
	bool slice_result = swift_import_slice(fn.result.nominal);
	bool projected_result = swift_import_projected(fn.result);
	bool fixed_result = projected_result && fn.result.nominal->alignment;
	bool owned_result = fn.result.nominal && !string_result && !slice_result && !projected_result;
	bool allocated_result = owned_result || (projected_result && !fixed_result);
	bool converted_result = slice_result || (projected_result && fn.result.nominal->owns);
	bool fallible = projected_result ? fn.result.nominal->owns || !fixed_result : fn.result.nominal != nullptr;
	String name = fn.odin_name;
	gbString params = gb_string_make(permanent_allocator(), "");
	gbString arguments = gb_string_make(permanent_allocator(), "");
	if (receiver) params = gb_string_append_fmt(params, "receiver: %.*s", LIT(fn.owner->name));
	for_array(i, fn.parameters) {
		auto const &param = fn.parameters[i];
		if (!param.empty_set) params = gb_string_append_fmt(params, "%s%.*s: %s", gb_string_length(params) ? ", " : "", LIT(param.name), param.type.odin);
		fallible |= (swift_import_projected(param.type) && (param.type.nominal->owns || !param.type.nominal->alignment)) || swift_import_kind(param.type, SwiftImportValue_String) || swift_import_slice(param.type.nominal) || (param.consumed && !param.empty_set);
		if (i) arguments = gb_string_appendc(arguments, ", ");
		if (param.empty_set) arguments = gb_string_appendc(arguments, "swift.empty_set()");
		else if (swift_import_projected(param.type)) {
			arguments = gb_string_append_fmt(arguments, "%s%sarg%td", swift_import_indirect(param.type) && param.type.nominal->alignment ? "&" : "", fn.is_async ? "capture." : "_swift_", i);
		} else if (swift_import_kind(param.type, SwiftImportValue_String)) {
			arguments = gb_string_append_fmt(arguments, "%sarg%td.bits, %sarg%td.object", fn.is_async ? "capture." : "_swift_", i, fn.is_async ? "capture." : "_swift_", i);
		} else if (swift_import_slice(param.type.nominal)) {
			arguments = gb_string_append_fmt(arguments, "%s%sarg%td%s", fn.is_collection ? "&" : "", fn.is_async ? "capture." : "_swift_", i, fn.is_collection ? "" : ".storage");
		} else if (param.type.nominal) {
			bool load = param.type.nominal->kind != SwiftImportValue_Opaque && !fn.is_collection;
			if (load) arguments = gb_string_appendc(arguments, "(cast(^rawptr)");
			if (fn.is_async) arguments = gb_string_append_fmt(arguments, "capture.arg%td", i);
			else if (param.consumed) arguments = gb_string_append_fmt(arguments, "_swift_arg%td", i);
			else arguments = gb_string_append_fmt(arguments, "rawptr(%.*s)", LIT(param.name));
			if (load) arguments = gb_string_appendc(arguments, ")^");
		} else {
			if (fn.is_async) arguments = gb_string_append_fmt(arguments, "capture.arg%td", i);
			else arguments = gb_string_append_fmt(arguments, "%.*s", LIT(param.name));
		}
	}
	if (fn.is_collection) arguments = gb_string_append_fmt(arguments, "%scapture.collection_metadata, capture.collection_witness", gb_string_length(arguments) ? ", " : "");
	if (receiver) arguments = gb_string_append_fmt(arguments, "%s%s", gb_string_length(arguments) ? ", " : "", fn.is_async ? "capture.receiver" : "rawptr(receiver)");

	source = gb_string_append_fmt(source, "@(private)\nforeign swift_library {\n\t@(link_name=\"%.*s\")\n\t_swift_%.*s_native :: proc \"%s\" (",
		LIT(fn.symbol), LIT(name), fn.is_async ? "swift/async" : "swift");
	isize count = 0;
	if (indirect_result) {
		source = gb_string_append_fmt(source, "%sresult: rawptr", fn.is_async ? "" : "#swift_result ");
		count++;
	}
	if (fn.is_async) source = gb_string_append_fmt(source, "%s#swift_async frame: ^runtime.Swift_Async_Frame", count++ ? ", " : "");
	for_array(i, fn.parameters) {
		auto const &param = fn.parameters[i];
		if (swift_import_kind(param.type, SwiftImportValue_String)) {
			source = gb_string_append_fmt(source, "%sarg%td_bits: u64, arg%td_object: rawptr", count++ ? ", " : "", i, i);
		} else source = gb_string_append_fmt(source, "%sarg%td: %s", count++ ? ", " : "", i, swift_import_native_type(param.type));
	}
	if (fn.is_collection) source = gb_string_append_fmt(source, "%scollection_metadata, collection_witness: rawptr", count++ ? ", " : "");
	if (receiver) source = gb_string_append_fmt(source, "%s#swift_self receiver: rawptr", count ? ", " : "");
	source = gb_string_appendc(source, ")");
	if (!fn.is_async && fn.result.odin && !indirect_result) source = gb_string_append_fmt(source, " -> %s", swift_import_native_type(fn.result));
	source = gb_string_appendc(source, " ---\n");
	if (fn.is_async) source = gb_string_append_fmt(source, "\t@(link_name=\"%.*sTu\")\n\t_swift_%.*s_descriptor: runtime.Swift_Async_Descriptor\n", LIT(fn.symbol), LIT(name));
	source = gb_string_appendc(source, "}\n\n");

	if (!fn.is_async) {
		if (fallible) source = gb_string_appendc(source, "@(require_results)\n");
		source = gb_string_append_fmt(source, "%.*s :: proc(%s)", LIT(name), params);
		if (fallible && fn.result.odin) source = gb_string_append_fmt(source, " -> (_swift_result: %s, ok: bool) #optional_ok", fn.result.odin);
		else if (fallible) source = gb_string_appendc(source, " -> (ok: bool)");
		else if (fn.result.odin) source = gb_string_append_fmt(source, " -> %s", fn.result.odin);
		source = gb_string_appendc(source, " {\n");
		bool consumes = false;
		for (auto const &param : fn.parameters) consumes |= param.consumed && !param.empty_set;
		if (consumes) source = gb_string_appendc(source, "\t_swift_called := false\n");
		if (receiver) source = gb_string_appendc(source, "\tassert(receiver != nil, \"Cannot borrow a nil Swift value\")\n");
		for_array(i, fn.parameters) {
			auto const &param = fn.parameters[i];
			if (param.empty_set) continue;
			if (swift_import_projected(param.type)) {
				auto type = param.type.nominal;
				if (type->alignment) source = gb_string_append_fmt(source, "\t_swift_arg%td: %s\n", i, swift_import_enum_native(type));
				else source = gb_string_append_fmt(source, "\t_swift_arg%td := swift.value_allocate(_swift_%.*s_metadata(0).type) or_return\n\tdefer swift.value_free_uninitialized(_swift_arg%td)\n", i, LIT(type->name), i);
				if (fallible) source = gb_string_append_fmt(source, "\tif !_swift_%.*s_initialize(%s_swift_arg%td, %.*s) { return }\n", LIT(type->name), type->alignment ? "&" : "", i, LIT(param.name));
				else source = gb_string_append_fmt(source, "\t_swift_initialized%td := _swift_%.*s_initialize(%s_swift_arg%td, %.*s)\n\tassert(_swift_initialized%td)\n", i, LIT(type->name), type->alignment ? "&" : "", i, LIT(param.name), i);
				if (type->owns) source = gb_string_append_fmt(source, "\tdefer %sswift.value_deinitialize(%s_swift_arg%td, _swift_%.*s_metadata(0).type)%s\n", param.consumed ? "if !_swift_called { " : "", type->alignment ? "&" : "", i, LIT(type->name), param.consumed ? " }" : "");
			} else if (swift_import_kind(param.type, SwiftImportValue_String)) {
				source = gb_string_append_fmt(source, "\t_swift_arg%td := swift.string_from_odin(%.*s) or_return\n\tdefer %sswift.string_destroy(&_swift_arg%td)%s\n", i, LIT(param.name), param.consumed ? "if !_swift_called { " : "", i, param.consumed ? " }" : "");
			} else if (swift_import_slice(param.type.nominal)) {
				source = gb_string_append_fmt(source, "\t_swift_arg%td := swift.array_from_odin(%.*s) or_return\n", i, LIT(param.name));
				source = gb_string_append_fmt(source, "\tdefer %sswift.array_destroy(_swift_arg%td)%s\n", param.consumed ? "if !_swift_called { " : "", i, param.consumed ? " }" : "");
			} else if (param.type.nominal) {
				source = gb_string_append_fmt(source, "\tassert(%.*s != nil, \"Cannot borrow a nil Swift value\")\n", LIT(param.name));
				if (param.consumed) source = gb_string_append_fmt(source, "\t_swift_arg%td := swift.value_copy(rawptr(%.*s), _swift_%.*s_metadata(0).type) or_return\n", i, LIT(param.name), LIT(param.type.nominal->name));
			}
			if (param.type.nominal && !param.type.nominal->projected && param.type.nominal->kind != SwiftImportValue_String && !swift_import_slice(param.type.nominal) && param.consumed) {
				source = gb_string_append_fmt(source, "\tdefer if _swift_called { swift.value_free_uninitialized(_swift_arg%td) } else { swift.value_destroy(_swift_arg%td, _swift_%.*s_metadata(0).type) }\n", i, i, LIT(param.type.nominal->name));
			}
		}
		if (fixed_result) source = gb_string_append_fmt(source, "\t_swift_storage: %s\n", swift_import_enum_native(fn.result.nominal));
		if (allocated_result) source = gb_string_append_fmt(source, "\t_swift_storage := swift.value_allocate(_swift_%.*s_metadata(0).type) or_return\n", LIT(fn.result.nominal->name));
		if (projected_result && !fixed_result) source = gb_string_appendc(source, "\tdefer swift.value_free_uninitialized(_swift_storage)\n");
		char const *assignment = !fn.result.odin || indirect_result ? "" : projected_result ? "_swift_storage = " : owned_result ? "(cast(^rawptr)_swift_storage)^ = " : "_swift_value := ";
		source = gb_string_append_fmt(source, "\t%s_swift_%.*s_native(%s%s%s)\n", assignment, LIT(name), indirect_result ? (fixed_result ? "&_swift_storage" : "_swift_storage") : "", indirect_result && gb_string_length(arguments) ? ", " : "", arguments);
		if (consumes) source = gb_string_appendc(source, "\t_swift_called = true\n");
		if (projected_result) {
			source = gb_string_append_fmt(source, "\t_swift_result_value, _swift_converted := _swift_%.*s_take(%s_swift_storage)\n", LIT(fn.result.nominal->name), fixed_result ? "&" : "");
			if (fallible) source = gb_string_appendc(source, "\treturn _swift_result_value, _swift_converted\n");
			else source = gb_string_appendc(source, "\tassert(_swift_converted)\n\treturn _swift_result_value\n");
		} else if (slice_result) source = gb_string_append_fmt(source, "\tdefer swift.array_destroy(swift.Native_Array{_swift_value})\n\treturn swift.array_to_odin(swift.Native_Array{_swift_value}, %s)\n", swift_import_slice_element(fn.result.nominal));
		else if (string_result) source = gb_string_appendc(source, "\tdefer swift.string_destroy(&_swift_value)\n\treturn swift.string_to_odin(_swift_value)\n");
		else if (owned_result) source = gb_string_append_fmt(source, "\treturn %s(_swift_storage), true\n", fn.result.odin);
		else if (fn.result.odin) source = gb_string_append_fmt(source, "\treturn _swift_value%s\n", fallible ? ", true" : "");
		else if (fallible) source = gb_string_appendc(source, "\treturn true\n");
		return gb_string_appendc(source, "}\n\n");
	}

	source = gb_string_append_fmt(source, "@(require_results)\n%.*s :: proc(%s%scompletion: proc(swift.Task", LIT(name), params, gb_string_length(params) ? ", " : "");
	if (fn.result.odin) source = gb_string_append_fmt(source, ", %s", fn.result.odin);
	if (fn.is_throwing) source = gb_string_appendc(source, ", swift.Error");
	if (converted_result) source = gb_string_appendc(source, ", bool");
	source = gb_string_appendc(source, ")) -> (task: swift.Task, ok: bool) #optional_ok {\n\tif completion == nil");
	if (receiver) source = gb_string_appendc(source, " || receiver == nil");
	for (auto const &param : fn.parameters) if (param.type.nominal && !param.type.nominal->projected && !param.empty_set && !swift_import_kind(param.type, SwiftImportValue_String) && !swift_import_slice(param.type.nominal)) source = gb_string_append_fmt(source, " || %.*s == nil", LIT(param.name));
	source = gb_string_appendc(source, " { return }\n\tCapture :: struct {\n\t\tcompletion: type_of(completion),\n");
	if (receiver) source = gb_string_appendc(source, "\t\treceiver: rawptr,\n");
	for_array(i, fn.parameters) if (!fn.parameters[i].empty_set) source = gb_string_append_fmt(source, "\t\targ%td: %s,\n", i, swift_import_slice(fn.parameters[i].type.nominal) ? "swift.Native_Array" : swift_import_native_type(fn.parameters[i].type));
	if (fn.is_collection) source = gb_string_appendc(source, "\t\tcollection_metadata, collection_witness: rawptr,\n");
	if (fn.result.odin) source = gb_string_append_fmt(source, "\t\tresult: %s,\n", projected_result ? swift_import_enum_native(fn.result.nominal) : (owned_result || slice_result) ? "rawptr" : fn.result.odin);
	if (fn.is_throwing) source = gb_string_appendc(source, "\t\terror: swift.Error,\n");
	source = gb_string_appendc(source, "\t}\n\t_swift_capture := Capture{completion = completion}\n");
	if (receiver) {
		if (fn.is_mutating) source = gb_string_appendc(source, "\t_swift_capture.receiver = rawptr(receiver)\n");
		else source = gb_string_append_fmt(source, "\t_swift_capture.receiver = swift.value_copy(rawptr(receiver), _swift_%.*s_metadata(0).type) or_return\n\tdefer if !ok { swift.value_destroy(_swift_capture.receiver, _swift_%.*s_metadata(0).type) }\n", LIT(fn.owner->name), LIT(fn.owner->name));
	}
	for_array(i, fn.parameters) {
		auto const &param = fn.parameters[i];
		if (param.empty_set) continue;
		if (swift_import_projected(param.type)) {
			auto type = param.type.nominal;
			if (!type->alignment) source = gb_string_append_fmt(source, "\t_swift_capture.arg%td = swift.value_allocate(_swift_%.*s_metadata(0).type) or_return\n\tdefer if !ok { swift.value_free_uninitialized(_swift_capture.arg%td) }\n", i, LIT(type->name), i);
			source = gb_string_append_fmt(source, "\tif !_swift_%.*s_initialize(%s_swift_capture.arg%td, %.*s) { return }\n", LIT(type->name), type->alignment ? "&" : "", i, LIT(param.name));
			if (type->owns) source = gb_string_append_fmt(source, "\tdefer if !ok { swift.value_deinitialize(%s_swift_capture.arg%td, _swift_%.*s_metadata(0).type) }\n", type->alignment ? "&" : "", i, LIT(type->name));
		} else if (swift_import_kind(param.type, SwiftImportValue_String)) {
			source = gb_string_append_fmt(source, "\t_swift_capture.arg%td = swift.string_from_odin(%.*s) or_return\n\tdefer if !ok { swift.string_destroy(&_swift_capture.arg%td) }\n", i, LIT(param.name), i);
		} else if (param.type.nominal) {
			if (swift_import_slice(param.type.nominal)) source = gb_string_append_fmt(source, "\t_swift_capture.arg%td = swift.array_from_odin(%.*s) or_return\n", i, LIT(param.name));
			else source = gb_string_append_fmt(source, "\t_swift_capture.arg%td = swift.value_copy(rawptr(%.*s), _swift_%.*s_metadata(0).type) or_return\n", i, LIT(param.name), LIT(param.type.nominal->name));
			if (swift_import_slice(param.type.nominal)) source = gb_string_append_fmt(source, "\tdefer if !ok { swift.array_destroy(_swift_capture.arg%td) }\n", i);
			else source = gb_string_append_fmt(source, "\tdefer if !ok { swift.value_destroy(_swift_capture.arg%td, _swift_%.*s_metadata(0).type) }\n", i, LIT(param.type.nominal->name));
			if (fn.is_collection && swift_import_slice(param.type.nominal)) source = gb_string_append_fmt(source, "\t_swift_capture.collection_metadata = _swift_%.*s_metadata(0).type\n\t_swift_capture.collection_witness = swift.array_collection_witness(_swift_capture.collection_metadata)\n", LIT(param.type.nominal->name));
		} else source = gb_string_append_fmt(source, "\t_swift_capture.arg%td = %.*s\n", i, LIT(param.name));
	}
	if (allocated_result) source = gb_string_append_fmt(source, "\t_swift_capture.result = swift.value_allocate(_swift_%.*s_metadata(0).type) or_return\n\tdefer if !ok { swift.value_free_uninitialized(_swift_capture.result) }\n", LIT(fn.result.nominal->name));
	source = gb_string_appendc(source, "\tentry :: proc \"swift/async\" (#swift_async frame: rawptr, #swift_self _: rawptr) {\n\t\tcapture := cast(^Capture)runtime.swift_async_payload(frame)\n\t\tchild := runtime.swift_async_prepare(frame, rawptr(resumed))\n");
	source = gb_string_append_fmt(source, "\t\t#must_tail _swift_%.*s_native(%scast(^runtime.Swift_Async_Frame)child%s%s)\n\t}\n", LIT(name), indirect_result ? (fixed_result ? "&capture.result, " : "capture.result, ") : "", gb_string_length(arguments) ? ", " : "", arguments);
	source = gb_string_appendc(source, "\tresumed :: proc \"swift/async\" (#swift_async child: ^runtime.Swift_Async_Frame");
	if (fn.result.odin && !indirect_result) source = gb_string_append_fmt(source, ", result: %s", swift_import_native_type(fn.result));
	if (fn.is_throwing) source = gb_string_appendc(source, ", #swift_self error: swift.Error");
	source = gb_string_appendc(source, ") {\n");
	if (fn.is_throwing || (fn.result.odin && !indirect_result)) {
		source = gb_string_appendc(source, "\t\tcapture := cast(^Capture)runtime.swift_async_payload(child.parent)\n");
		if (fn.is_throwing) source = gb_string_appendc(source, "\t\tcapture.error = error\n");
		if (fn.result.odin && !indirect_result) source = gb_string_append_fmt(source, "\t\t%s%s = result%s\n", fn.is_throwing ? "if error == nil { " : "", owned_result ? "(cast(^rawptr)capture.result)^" : "capture.result", fn.is_throwing ? " }" : "");
	}
	source = gb_string_appendc(source, "\t\t#must_tail runtime.swift_async_complete(child)\n\t}\n\tinvoke :: proc(pointer: rawptr) {\n\t\tcapture := cast(^Capture)pointer\n");
	if (receiver && !fn.is_mutating) source = gb_string_append_fmt(source, "\t\tswift.value_destroy(capture.receiver, _swift_%.*s_metadata(0).type)\n", LIT(fn.owner->name));
	for_array(i, fn.parameters) {
		auto const &param = fn.parameters[i];
		if (param.empty_set) continue;
		if (swift_import_projected(param.type)) {
			auto type = param.type.nominal;
			if (!param.consumed && type->owns) source = gb_string_append_fmt(source, "\t\tswift.value_deinitialize(%scapture.arg%td, _swift_%.*s_metadata(0).type)\n", type->alignment ? "&" : "", i, LIT(type->name));
			if (!type->alignment) source = gb_string_append_fmt(source, "\t\tswift.value_free_uninitialized(capture.arg%td)\n", i);
		} else if (param.consumed) {
			if (param.type.nominal && param.type.nominal->kind != SwiftImportValue_String && !swift_import_slice(param.type.nominal)) source = gb_string_append_fmt(source, "\t\tswift.value_free_uninitialized(capture.arg%td)\n", i);
		} else if (swift_import_kind(param.type, SwiftImportValue_String)) source = gb_string_append_fmt(source, "\t\tswift.string_destroy(&capture.arg%td)\n", i);
		else if (swift_import_slice(param.type.nominal)) source = gb_string_append_fmt(source, "\t\tswift.array_destroy(capture.arg%td)\n", i);
		else if (param.type.nominal) source = gb_string_append_fmt(source, "\t\tswift.value_destroy(capture.arg%td, _swift_%.*s_metadata(0).type)\n", i, LIT(param.type.nominal->name));
	}
	if (fn.is_throwing && owned_result) source = gb_string_appendc(source, "\t\tif capture.error != nil {\n\t\t\tswift.value_free_uninitialized(capture.result)\n\t\t\tcapture.result = nil\n\t\t}\n");
	if (projected_result) {
		source = gb_string_append_fmt(source, "\t\tresult: %s\n\t\tconverted := false\n", fn.result.odin);
		if (fn.is_throwing) source = gb_string_appendc(source, "\t\tif capture.error == nil {\n");
		source = gb_string_append_fmt(source, "\t\tresult, converted = _swift_%.*s_take(%scapture.result)\n", LIT(fn.result.nominal->name), fixed_result ? "&" : "");
		if (fn.is_throwing) source = gb_string_appendc(source, "\t\t}\n");
		if (!fixed_result) source = gb_string_appendc(source, "\t\tswift.value_free_uninitialized(capture.result)\n");
		if (!converted_result) source = gb_string_append_fmt(source, "\t\tassert(%sconverted)\n", fn.is_throwing ? "capture.error != nil || " : "");
	}
	if (slice_result) {
		source = gb_string_append_fmt(source, "\t\tresult: %s\n\t\tconverted := false\n", fn.result.odin);
		if (fn.is_throwing) source = gb_string_appendc(source, "\t\tif capture.error == nil {\n");
		source = gb_string_append_fmt(source, "\t\tresult, converted = swift.array_to_odin(swift.Native_Array{capture.result}, %s)\n\t\tswift.array_destroy(swift.Native_Array{capture.result})\n", swift_import_slice_element(fn.result.nominal));
		if (fn.is_throwing) source = gb_string_appendc(source, "\t\t}\n");
	}
	source = gb_string_appendc(source, "\t\tcapture.completion(swift.Task(runtime.swift_async_current())");
	if (slice_result || projected_result) source = gb_string_appendc(source, ", result");
	else if (fn.result.odin) source = gb_string_append_fmt(source, ", %s(capture.result)", fn.result.odin);
	if (fn.is_throwing) source = gb_string_appendc(source, ", capture.error");
	if (converted_result) source = gb_string_appendc(source, ", converted");
	source = gb_string_append_fmt(source, ")\n\t}\n\ttask = swift.Task(runtime.swift_async_start(rawptr(entry), &_swift_%.*s_descriptor, &_swift_capture, size_of(Capture), invoke, rawptr(completion)))\n\tok = task != nil\n\treturn\n}\n\n", LIT(name));
	return source;
}

gb_internal bool swift_import_check_type_names(Ast *node, Array<SwiftImportNominal *> const &types) {
	for_array(i, types) {
		auto type = types[i];
		if (type->is_scalar) continue;
		if (swift_import_reserved_name(type->name)) {
			syntax_error(node, "Swift import: type '%.*s' conflicts with a name used by generated Odin declarations", LIT(type->name));
			return false;
		}
		for (isize j = 0; j < i; j++) {
			if (!types[j]->is_scalar && types[j]->name == type->name) {
				syntax_error(node, "Swift import: types '%.*s' and '%.*s' map to the same Odin name '%.*s'",
					LIT(types[j]->swift_name), LIT(type->swift_name), LIT(type->name));
				return false;
			}
		}
	}
	return true;
}

gb_internal bool swift_import_add_name(Ast *node, Array<String> *names, String name) {
	for (auto previous : *names) {
		if (previous == name) {
			syntax_error(node, "Swift import: generated Odin name '%.*s' is ambiguous", LIT(name));
			return false;
		}
	}
	array_add(names, name);
	return true;
}

gb_internal bool swift_import_generate(Ast *node, SwiftImportPackage *pkg) {
	char const *sdk_name = "macosx";
	if (selected_subtarget == Subtarget_iPhone) sdk_name = "iphoneos";
	if (selected_subtarget == Subtarget_iPhoneSimulator) sdk_name = "iphonesimulator";
	auto args = array_make<String>(permanent_allocator());
	array_add(&args, str_lit("--sdk"));
	array_add(&args, make_string_c(sdk_name));
	array_add(&args, str_lit("--show-sdk-path"));
	String sdk = {};
	if (!swift_import_exec(node, pkg->directory, args, &sdk)) return false;
	sdk = string_trim_whitespace(sdk);
	auto common = array_make<String>(permanent_allocator());
	array_add(&common, str_lit("-sdk"));
	array_add(&common, sdk);
	array_add(&common, str_lit("-target"));
	array_add(&common, build_context.metrics.target_triplet);
	array_add(&common, str_lit("-I"));
	array_add(&common, pkg->path);
	// Swift validates cached modules against their dependencies and toolchain.
	// Keep this cache between imports, but always inspect the current API/ABI.
	array_add(&common, str_lit("-module-cache-path"));
	array_add(&common, swift_import_path(temporary_directory(permanent_allocator()), "odin-swift-module-cache"));

	array_clear(&args);
	array_add(&args, str_lit("swift-symbolgraph-extract"));
	for (String arg : common) array_add(&args, arg);
	array_add(&args, str_lit("-module-name"));
	array_add(&args, pkg->module);
	array_add(&args, str_lit("-minimum-access-level"));
	array_add(&args, str_lit("public"));
	array_add(&args, str_lit("-output-dir"));
	array_add(&args, pkg->directory);
	if (!swift_import_exec(node, pkg->directory, args, nullptr)) return false;
	String graph_path = swift_import_path(pkg->directory, alloc_cstring(permanent_allocator(), concatenate_strings(permanent_allocator(), pkg->module, str_lit(".symbols.json"))));
	JsonValue *graph = swift_import_json(node, swift_import_read(graph_path));
	if (!graph) return false;
	array_clear(&args);
	array_add(&args, str_lit("swift-api-digester"));
	for (String arg : common) array_add(&args, arg);
	array_add(&args, str_lit("-dump-sdk"));
	array_add(&args, str_lit("-module"));
	array_add(&args, pkg->module);
	array_add(&args, str_lit("-o"));
	array_add(&args, swift_import_path(pkg->directory, "api.json"));
	if (!swift_import_exec(node, pkg->directory, args, nullptr)) return false;
	JsonValue *api = swift_import_member(swift_import_json(node, swift_import_read(swift_import_path(pkg->directory, "api.json"))), "ABIRoot");
	JsonValue *version = swift_import_member(api, "json_format_version");
	if (!version || version->kind != Json_Number || version->number != 8) {
		syntax_error(node, "Swift import: unsupported API digester format");
		return false;
	}
	auto types = array_make<SwiftImportNominal *>(permanent_allocator());
	for (JsonValue *symbol : swift_import_array(graph, "symbols")) {
		String kind = swift_import_string(swift_import_member(symbol, "kind"), "identifier");
		if ((kind != "swift.struct" && kind != "swift.enum") || !swift_import_available(symbol)) continue;
		String usr = swift_import_string(swift_import_member(symbol, "identifier"), "precise");
		JsonValue *declaration = swift_import_find_api(api, usr);
		if (!declaration) continue;
		bool generic = swift_import_member(symbol, "swiftGenerics") || swift_import_member(declaration, "genericSig");
		if (generic) {
			String signature = swift_import_string(declaration, "genericSig");
			if (kind != "swift.enum" || swift_import_array(symbol, "pathComponents").count > 2 ||
			    signature.len < 3 || signature[0] != '<' || signature[signature.len-1] != '>' ||
			    !swift_import_identifier(substring(signature, 1, signature.len-1))) continue;
		}
		bool copyable = false, escapable = false;
		for (JsonValue *conformance : swift_import_array(declaration, "conformances")) {
			copyable |= swift_import_string(conformance, "usr") == "s:s8CopyableP";
			escapable |= swift_import_string(conformance, "usr") == "s:s9EscapableP";
		}
		if (!copyable || !escapable) continue;
		gbString name = gb_string_make(permanent_allocator(), "");
		gbString swift_name = gb_string_append_fmt(gb_string_make(permanent_allocator(), ""), "%.*s", LIT(pkg->module));
		bool valid = true;
		for (JsonValue *part : swift_import_array(symbol, "pathComponents")) {
			if (part->kind != Json_String || !swift_import_identifier(part->string)) { valid = false; break; }
			if (gb_string_length(name)) name = gb_string_appendc(name, "_");
			name = gb_string_append_length(name, part->string.text, part->string.len);
			swift_name = gb_string_append_fmt(swift_name, ".`%.*s`", LIT(part->string));
		}
		if (!valid || gb_string_length(name) == 0) continue;
		auto type = gb_alloc_item(permanent_allocator(), SwiftImportNominal);
		*type = {};
		type->name = make_string_c(name);
		type->swift_name = make_string_c(swift_name);
		type->usr = usr;
		type->symbol = swift_import_string(declaration, "mangledName");
		type->declaration = declaration;
		type->is_enum = kind == "swift.enum";
		type->is_template = generic;
		if (generic && swift_import_array(symbol, "pathComponents").count == 2) {
			auto parts = swift_import_array(symbol, "pathComponents");
			type->generic_parent = make_string_c(gb_string_append_fmt(gb_string_make(permanent_allocator(), ""), "%.*s.`%.*s`", LIT(pkg->module), LIT(parts[0]->string)));
			type->generic_suffix = make_string_c(gb_string_append_fmt(gb_string_make(permanent_allocator(), ""), ".`%.*s`", LIT(parts[1]->string)));
		}
		for (auto attribute : swift_import_array(declaration, "declAttributes")) {
			if (attribute->kind == Json_String && attribute->string == "Frozen") type->is_frozen = true;
		}
		array_add(&types, type);
	}

	if (!swift_import_check_type_names(node, types)) return false;

	auto functions = array_make<SwiftImportFunction>(permanent_allocator());
	array_init(&pkg->unsupported, permanent_allocator());
	for (JsonValue *symbol : swift_import_array(graph, "symbols")) {
		String kind = swift_import_string(swift_import_member(symbol, "kind"), "identifier");
		auto components = swift_import_array(symbol, "pathComponents");
		bool method = kind == "swift.method" || kind == "swift.type.method";
		bool property = kind == "swift.property" || kind == "swift.type.property";
		bool initializer = kind == "swift.init";
		if (!(kind == "swift.func" && components.count == 1) && !method && !property && !initializer) continue;
		String usr = swift_import_string(swift_import_member(symbol, "identifier"), "precise");
		JsonValue *declaration = swift_import_find_api(api, usr);
		if (!declaration) continue;
		String name = swift_import_name(swift_import_string(declaration, "name"));
		SwiftImportFunction fn = {};
		fn.is_static = kind == "swift.type.method" || kind == "swift.type.property";
		fn.is_property = property;
		fn.is_initializer = initializer;
		if (components.count > 1) {
			gbString owner_name = gb_string_make(permanent_allocator(), "");
			for (isize i = 0; i < components.count-1; i++) {
				if (components[i]->kind != Json_String) continue;
				owner_name = gb_string_append_fmt(owner_name, "%s%.*s", i ? "_" : "", LIT(components[i]->string));
			}
			for (auto type : types) if (type->name == make_string_c(owner_name)) fn.owner = type;
			name = concatenate3_strings(permanent_allocator(), make_string_c(owner_name), str_lit("_"), name);
		}
		bool supported = (components.count == 1 || fn.owner) && swift_import_available(symbol) &&
		                 (!fn.owner || !fn.owner->is_template) && swift_import_function(symbol, declaration, &fn, &types);
		fn.base_name = name;
		// Keep argument labels in distinct binding names, like Objective-C
		// selectors. A unique supported declaration also gets the short name.
		String title = swift_import_string(swift_import_member(symbol, "names"), "title");
		isize open = string_index_byte(title, '(');
		if (!property && open >= 0 && string_ends_with(title, str_lit(")"))) {
			String_Iterator labels = {substring(title, open+1, title.len-1)};
			while (labels.pos < labels.str.len) {
				String label = string_split_iterator(&labels, ':');
				if (label != "_" && swift_import_identifier(label)) {
					name = concatenate3_strings(permanent_allocator(), name, str_lit("_"), swift_import_name(label));
				}
			}
		}
		if (property && supported) {
			supported = false;
			for (JsonValue *accessor : swift_import_array(declaration, "accessors")) {
				if (swift_import_string(accessor, "accessorKind") == "get" && !swift_import_member(accessor, "declAttributes")) {
					fn.symbol = swift_import_string(accessor, "mangledName");
					supported = true;
				}
			}
		}
		if (!supported) {
			array_add(&pkg->unsupported, name);
			continue;
		}
		fn.odin_name = name;
		bool collision = false;
		for (auto const &previous : functions) collision |= previous.odin_name == name;
		if (collision) array_add(&pkg->unsupported, name);
		else array_add(&functions, fn);
	}
	// A name must identify one supported declaration. Never choose an overload
	// based on whichever order a tool happens to serialize its symbols.
	for (isize i = functions.count; i-- > 0;) {
		for (String name : pkg->unsupported) {
			if (functions[i].odin_name == name) {
				array_ordered_remove(&functions, i);
				break;
			}
		}
	}

	// Case payload resolution may add concrete enum specializations.
	for (isize i = 0; i < types.count; i++) {
		auto type = types[i];
		if (!type->is_enum || type->is_template) continue;
		array_init(&type->cases, permanent_allocator());
		if (type->is_optional) {
			SwiftImportCase some = {};
			some.name = str_lit("some");
			some.available = true;
			some.has_payload = true;
			array_init(&some.fields, permanent_allocator());
			array_add(&some.fields, (SwiftImportField{str_lit("value"), swift_import_nominal_type(type->argument)}));
			array_add(&type->cases, some);
			SwiftImportCase none = {};
			none.name = str_lit("none");
			none.available = true;
			none.tag = 1;
			array_add(&type->cases, none);
			continue;
		}
		bool indirect = false;
		for (auto attribute : swift_import_array(type->declaration, "declAttributes")) {
			indirect |= attribute->kind == Json_String && attribute->string == "Indirect";
		}
		u32 payloads = 0;
		for (JsonValue *element : swift_import_array(type->declaration, "children")) {
			if (swift_import_string(element, "declKind") != "EnumElement") continue;
			SwiftImportCase c = {};
			c.name = swift_import_string(element, "name");
			c.available = !indirect && swift_import_identifier(c.name);
			for (auto attribute : swift_import_array(element, "declAttributes")) {
				if (attribute->kind == Json_String && attribute->string == "Indirect") c.available = false;
			}
			String usr = swift_import_string(element, "usr");
			String labels = {};
			for (JsonValue *symbol : swift_import_array(graph, "symbols")) {
				if (swift_import_string(swift_import_member(symbol, "identifier"), "precise") == usr) {
					c.available &= swift_import_available(symbol);
					String title = swift_import_string(swift_import_member(symbol, "names"), "title");
					isize open = string_index_byte(title, '(');
					if (open >= 0 && string_ends_with(title, str_lit(")"))) labels = substring(title, open+1, title.len-1);
					for (auto fragment : swift_import_array(symbol, "declarationFragments")) {
						if (swift_import_string(fragment, "spelling") == "indirect") c.available = false;
					}
					break;
				}
			}
			c.symbol = concatenate_strings(permanent_allocator(), swift_import_string(element, "mangledName"), str_lit("WC"));
			auto children = swift_import_array(element, "children");
			if (children.count == 1) {
				auto signature = swift_import_array(children[0], "children");
				if (signature.count > 0 && swift_import_string(signature[0], "kind") == "TypeFunc") {
					c.has_payload = true;
					payloads++;
					auto payload = swift_import_array(signature[0], "children");
					if (payload.count == 2) {
						array_init(&c.fields, permanent_allocator());
						bool tuple = swift_import_string(payload[1], "name") == "Tuple" && !swift_import_string(payload[1], "usr").len;
						auto fields = tuple ? swift_import_array(payload[1], "children") : Slice<JsonValue *>{&payload[1], 1};
						String_Iterator it = {labels};
						for (isize j = 0; j < fields.count; j++) {
							SwiftImportField field = {};
							String label = it.pos < labels.len ? string_split_iterator(&it, ':') : str_lit("_");
							if (label != "_" && swift_import_identifier(label)) field.name = swift_import_name(label, true);
							else field.name = fields.count == 1 ? str_lit("value") : make_string_c(gb_string_append_fmt(gb_string_make(permanent_allocator(), ""), "value_%td", j));
							for (auto const &previous : c.fields) if (previous.name == field.name) c.available = false;
							swift_import_api_type(fields[j], &field.type, &types, type->argument);
							array_add(&c.fields, field);
						}
					}
				}
			}
			array_add(&type->cases, c);
		}
		u32 payload = 0, empty = payloads;
		for (auto &c : type->cases) c.tag = c.has_payload ? payload++ : empty++;
	}

	if (!swift_import_check_type_names(node, types)) return false;

	gbString probe = gb_string_make(permanent_allocator(), "");
	probe = gb_string_append_fmt(probe, "import %.*s\n", LIT(pkg->module));
	for_array(i, types) {
		if (types[i]->is_template) continue;
		probe = gb_string_append_fmt(probe, "@_silgen_name(\"odin_swift_import_metadata_%td\")\npublic func metadata_%td() -> Any.Type { %.*s.self }\n", i, i, LIT(types[i]->swift_name));
		if (types[i]->is_enum && types[i]->cases.count) {
			probe = gb_string_append_fmt(probe,
				"@_silgen_name(\"odin_swift_import_load_%td\")\npublic func load_%td(_ value: Swift.UnsafePointer<%.*s>) -> %.*s { value.pointee }\n"
				"@_silgen_name(\"odin_swift_import_layout_%td\")\npublic func layout_%td() -> (Swift.Int, Swift.Int) { (Swift.MemoryLayout<%.*s>.size, Swift.MemoryLayout<%.*s>.alignment) }\n",
				i, i, LIT(types[i]->swift_name), LIT(types[i]->swift_name), i, i, LIT(types[i]->swift_name), LIT(types[i]->swift_name));
		}
		for_array(j, types[i]->cases) {
			auto const &c = types[i]->cases[j];
			if (!c.available) continue;
			probe = gb_string_append_fmt(probe, "public func case_%td_%td(_ value: %.*s) -> Swift.Bool { if case .`%.*s` = value { return true }; return false }\n", i, j, LIT(types[i]->swift_name), LIT(c.name));
		}
	}
	for_array(i, functions) {
		auto const &fn = functions[i];
		bool receiver = swift_import_has_receiver(fn);
		if (fn.is_main_actor) probe = gb_string_appendc(probe, "@MainActor\n");
		probe = gb_string_append_fmt(probe, "public func probe_%td(", i);
		if (receiver) probe = gb_string_append_fmt(probe, "_ receiver: %s%.*s", fn.is_mutating ? "inout " : "", LIT(fn.owner->swift_name));
		for_array(j, fn.parameters) probe = gb_string_append_fmt(probe, "%s_ arg%td: %s", j || receiver ? ", " : "", j, fn.parameters[j].type.swift);
		probe = gb_string_append_fmt(probe, ")%s%s", fn.is_async ? " async" : "", fn.is_throwing ? " throws" : "");
		if (fn.result.swift) probe = gb_string_append_fmt(probe, " -> %s", fn.result.swift);
		String owner = receiver ? str_lit("receiver") : fn.owner ? fn.owner->swift_name : pkg->module;
		probe = gb_string_append_fmt(probe, " { %s%s%.*s", fn.is_throwing ? "try " : "", fn.is_async ? "await " : "", LIT(owner));
		if (!fn.is_initializer) probe = gb_string_append_fmt(probe, ".%.*s", LIT(fn.name));
		if (!fn.is_property) {
			probe = gb_string_appendc(probe, "(");
			for_array(j, fn.parameters) {
				auto const &p = fn.parameters[j];
				if (j) probe = gb_string_appendc(probe, ", ");
				if (p.label != "_") probe = gb_string_append_fmt(probe, "%.*s: ", LIT(p.label));
				probe = gb_string_append_fmt(probe, "arg%td", j);
			}
			probe = gb_string_appendc(probe, ")");
		}
		probe = gb_string_appendc(probe, " }\n");
	}
	String probe_path = swift_import_path(pkg->directory, "Probe.swift");
	if (!swift_import_write(node, probe_path, probe)) return false;
	array_clear(&args);
	array_add(&args, str_lit("swiftc"));
	for (String arg : common) array_add(&args, arg);
	char const *probe_flags[] = {"-module-name", "OdinSwiftImportProbe", "-parse-as-library", "-warnings-as-errors", "-Onone", "-emit-ir"};
	for (char const *flag : probe_flags) array_add(&args, make_string_c(flag));
	array_add(&args, probe_path);
	array_add(&args, str_lit("-o"));
	array_add(&args, swift_import_path(pkg->directory, "Probe.ll"));
	if (!swift_import_exec(node, pkg->directory, args, nullptr)) return false;
	String ir = swift_import_read(swift_import_path(pkg->directory, "Probe.ll"));
	array_clear(&args);
	array_add(&args, str_lit("swiftc"));
	for (String arg : common) array_add(&args, arg);
	char const *ownership_flags[] = {"-module-name", "OdinSwiftImportProbe", "-parse-as-library", "-warnings-as-errors", "-emit-silgen"};
	for (char const *flag : ownership_flags) array_add(&args, make_string_c(flag));
	array_add(&args, probe_path);
	array_add(&args, str_lit("-o"));
	array_add(&args, swift_import_path(pkg->directory, "Probe.sil"));
	if (!swift_import_exec(node, pkg->directory, args, nullptr)) return false;
	String sil = swift_import_read(swift_import_path(pkg->directory, "Probe.sil"));
	array_clear(&args);
	array_add(&args, str_lit("nm"));
	array_add(&args, str_lit("-gU"));
	array_add(&args, pkg->library);
	String exports = {};
	if (!pkg->framework && !swift_import_exec(node, pkg->directory, args, &exports)) return false;
	LLVMContextRef inspection_context = LLVMContextCreate();
	defer (LLVMContextDispose(inspection_context));
	LLVMMemoryBufferRef buffer = LLVMCreateMemoryBufferWithMemoryRangeCopy(cast(char const *)ir.text, ir.len, "Swift import");
	LLVMModuleRef inspection = nullptr;
	char *diagnostic = nullptr;
	if (LLVMParseIRInContext(inspection_context, buffer, &inspection, &diagnostic)) {
		syntax_error(node, "Swift import: cannot read the toolchain's LLVM lowering: %s", diagnostic ? diagnostic : "invalid IR");
		LLVMDisposeMessage(diagnostic);
		return false;
	}
	defer (LLVMDisposeModule(inspection));
	LLVMTargetDataRef layout = LLVMCreateTargetData(LLVMGetDataLayoutStr(inspection));
	defer (LLVMDisposeTargetData(layout));
	for_array(i, types) {
		auto type = types[i];
		if (type->is_template) continue;
		if (type->is_scalar) {
			type->supported = true;
		} else if (type->kind == SwiftImportValue_String) {
			type->supported = swift_import_has_line(ir, str_lit("@\"$sSSN\" = external global %swift.type"), true);
		} else if (type->argument) {
			type->mangled = swift_import_concrete_metadata(ir, i);
			type->supported = type->mangled.len != 0;
		} else {
			gbString declaration = gb_string_append_fmt(gb_string_make(permanent_allocator(), ""),
				"declare swiftcc %%swift.metadata_response @\"%.*sMa\"(i64)", LIT(type->symbol));
			String exported = concatenate3_strings(permanent_allocator(), str_lit(" _"), type->symbol, str_lit("Ma"));
			type->supported = swift_import_has_line(ir, make_string_c(declaration), true) &&
			                  (pkg->framework || swift_import_has_line(exports, exported, false));
		}
		if (type->is_enum && !type->argument && type->is_frozen) {
			String symbol = concatenate_strings(permanent_allocator(), type->symbol, str_lit("N"));
			LLVMValueRef metadata = LLVMGetNamedGlobal(inspection, alloc_cstring(permanent_allocator(), symbol));
			if (metadata && (pkg->framework || swift_import_has_line(exports, concatenate_strings(permanent_allocator(), str_lit(" _"), symbol), false))) {
				type->static_metadata = true;
				type->supported = true;
			}
		}
		if (type->is_enum) type->supported &= swift_import_enum_layout(inspection, layout, type, i);
		if (type->is_enum && !type->is_frozen) {
			for (auto const &c : type->cases) {
				if (!c.available) continue;
				String global = concatenate3_strings(permanent_allocator(), str_lit("@\""), c.symbol, str_lit("\" = external global i32"));
				String constant = concatenate3_strings(permanent_allocator(), str_lit("@\""), c.symbol, str_lit("\" = external constant i32"));
				String exported = concatenate_strings(permanent_allocator(), str_lit(" _"), c.symbol);
				type->supported &= (swift_import_has_line(ir, global, true) || swift_import_has_line(ir, constant, true)) &&
				                   (pkg->framework || swift_import_has_line(exports, exported, false));
			}
		}
	}
	for (auto type : types) if (!type->is_template) swift_import_resolve_enum(type);
	for (isize index = functions.count; index-- > 0;) {
		auto &fn = functions[index];
		bool receiver = swift_import_has_receiver(fn);
		bool indirect_result = swift_import_indirect(fn.result);
		bool supported = (!fn.owner || fn.is_static || (fn.owner->supported && !fn.owner->projected)) && swift_import_ownership(sil, &fn);
		if (fn.result.nominal) supported &= fn.result.nominal->supported;
		for (auto const &param : fn.parameters) if (param.type.nominal) supported &= param.type.nominal->supported;
		gbString declaration = gb_string_make(permanent_allocator(), "");
		declaration = gb_string_append_fmt(declaration, "declare %s %s @\"%.*s\"(", fn.is_async ? "swifttailcc" : "swiftcc",
			fn.is_async || indirect_result || !fn.result.llvm ? "void" : swift_import_projected(fn.result) ? alloc_cstring(permanent_allocator(), swift_import_enum_llvm(fn.result.nominal, true)) : fn.result.llvm, LIT(fn.symbol));
		isize count = 0;
		if (indirect_result) {
			declaration = gb_string_appendc(declaration, fn.is_async ? "ptr noalias" : "ptr noalias sret(%swift.opaque)");
			count++;
		}
		if (fn.is_async) {
			declaration = gb_string_append_fmt(declaration, "%sptr swiftasync", count++ ? ", " : "");
		}
		for (auto const &param : fn.parameters) {
			char const *llvm = swift_import_kind(param.type, SwiftImportValue_String) ? "i64, ptr" : swift_import_projected(param.type) ? alloc_cstring(permanent_allocator(), swift_import_enum_llvm(param.type.nominal, false)) : param.type.llvm;
			if (fn.is_collection && swift_import_string_array(param.type)) llvm = "ptr noalias";
			declaration = gb_string_append_fmt(declaration, "%s%s", count++ ? ", " : "", llvm);
		}
		if (fn.is_collection) declaration = gb_string_append_fmt(declaration, "%sptr, ptr", count++ ? ", " : "");
		if (receiver) declaration = gb_string_append_fmt(declaration, "%s%s", count ? ", " : "", fn.is_mutating ? "ptr swiftself" : "ptr noalias swiftself");
		declaration = gb_string_appendc(declaration, ")");
		String exported = concatenate_strings(permanent_allocator(), str_lit(" _"), fn.symbol);
		if (!supported || !swift_import_has_line(ir, make_string_c(declaration), true) ||
		    (!pkg->framework && (!swift_import_has_line(exports, exported, false) ||
		    (fn.is_async && !swift_import_has_line(exports, concatenate_strings(permanent_allocator(), exported, str_lit("Tu")), false))))) {
			array_add(&pkg->unsupported, fn.odin_name);
			array_ordered_remove(&functions, index);
		}
	}

	// Validate the whole emitted namespace, including ownership helpers. Never
	// let an unsupported Swift member silently resolve to one of our helpers.
	auto names = array_make<String>(permanent_allocator());
	for (auto type : types) {
		if (!type->supported || type->is_scalar || type->kind == SwiftImportValue_String || swift_import_slice(type)) continue;
		if (!swift_import_add_name(node, &names, type->name)) return false;
		if (type->projected) {
			char const *ownership_suffixes[] = {"_copy", "_destroy"};
			for (char const *suffix : ownership_suffixes) {
				if (!swift_import_add_name(node, &names, concatenate_strings(permanent_allocator(), type->name, make_string_c(suffix)))) return false;
			}
			if (!type->is_optional) {
				for (auto const &c : type->cases) if (!swift_import_add_name(node, &names, swift_import_case_name(type, c))) return false;
				if (!type->is_frozen && !swift_import_add_name(node, &names, concatenate_strings(permanent_allocator(), type->name, str_lit("_Unknown")))) return false;
			}
			continue;
		}
		char const *suffixes[] = {"_copy", "_destroy", "_count", "_get"};
		for (isize i = 0; i < gb_count_of(suffixes); i++) {
			if (i >= 2 && i <= 3 && !(type->kind == SwiftImportValue_Array && type->argument->supported)) continue;
			String name = concatenate_strings(permanent_allocator(), type->name, make_string_c(suffixes[i]));
			if (!swift_import_add_name(node, &names, name)) return false;
		}

	}
	for (auto name : pkg->unsupported) {
		for (auto generated : names) {
			if (name == generated) {
				syntax_error(node, "Swift import: unsupported declaration '%.*s' conflicts with a generated Odin helper", LIT(name));
				return false;
			}
		}
	}
	for (auto const &fn : functions) {
		if (!swift_import_add_name(node, &names, fn.odin_name)) return false;
	}

	// The target's Swift driver identifies its runtime search paths. Let the
	// normal Odin linker link the original object/archive and its autolinks.
	array_clear(&args);
	array_add(&args, str_lit("swiftc"));
	for (String arg : common) array_add(&args, arg);
	array_add(&args, str_lit("-print-target-info"));
	String target_info;
	if (!swift_import_exec(node, pkg->directory, args, &target_info)) return false;
	JsonValue *target = swift_import_json(node, target_info);
	if (!target) return false;
	gbString flags = gb_string_make(permanent_allocator(), "");
	auto paths = swift_import_array(swift_import_member(target, "paths"), "runtimeLibraryPaths");
	if (paths.count == 0) {
		syntax_error(node, "Swift import: missing runtime library paths");
		return false;
	}
	for (JsonValue *path : paths) {
		if (path->kind != Json_String || string_contains_char(path->string, '\0') || string_contains_char(path->string, '"')) {
			syntax_error(node, "Swift import: invalid runtime library path");
			return false;
		}
		// Preserve UTF-8 here. These are linker arguments; source escaping is
		// applied to the complete attribute below, not to individual paths.
		flags = gb_string_append_fmt(flags, "-L\"%.*s\" ", LIT(path->string));
	}
	flags = gb_string_appendc(flags, "-Wl,-rpath,/usr/lib/swift");
	gbString source = gb_string_make(permanent_allocator(), "");
	String identity = pkg->framework ? pkg->module : pkg->library;
	bool has_values = false, has_scalar_async = false, has_value_async = false;
	for (auto type : types) has_values |= type->supported;
	for (auto const &fn : functions) {
		bool values = fn.owner || fn.result.nominal || fn.is_throwing;
		for (auto const &param : fn.parameters) values |= param.type.nominal != nullptr;
		has_values |= values;
		has_scalar_async |= fn.is_async && !values;
		has_value_async |= fn.is_async && values;
	}
	source = gb_string_append_fmt(source, "package swift_%.*s_%llx\n\n",
		LIT(pkg->module), cast(unsigned long long)fnv64a(identity.text, identity.len));
	if (has_scalar_async) source = gb_string_appendc(source, "import \"base:intrinsics\"\n");
	if (has_value_async) source = gb_string_appendc(source, "import \"base:runtime\"\n");
	if (has_values) source = gb_string_appendc(source, "@(require)\nimport \"core:mem\"\n@(require)\nimport \"core:strings\"\n");
	if (has_values || has_scalar_async || has_value_async) source = gb_string_appendc(source, "import swift \"core:sys/darwin/Swift\"\n");
	source = gb_string_appendc(source, "\n");
	String quoted_flags = quote_to_ascii(permanent_allocator(), make_string_c(flags));
	String quoted_library = quote_to_ascii(permanent_allocator(), pkg->framework ? pkg->library : swift_import_relative(pkg->directory, pkg->library));
	source = gb_string_append_fmt(source,
		"@(require, extra_linker_flags=%.*s)\n"
		"foreign import swift_library {\n\t%.*s,\n\t\"system:swiftCore\",\n\t\"system:swift_Concurrency\",\n}\n\n",
		LIT(quoted_flags), LIT(quoted_library));
	for (auto type : types) {
		if (type->supported) source = swift_import_emit_type(source, type);
	}
	for (auto const &fn : functions) {
		bool values = fn.owner || fn.result.nominal || fn.is_throwing;
		for (auto const &param : fn.parameters) values |= param.type.nominal != nullptr;
		if (values) {
			source = swift_import_emit_value_function(source, fn);
			continue;
		}
		gbString params = gb_string_make(permanent_allocator(), "");
		for_array(i, fn.parameters) params = gb_string_append_fmt(params, "%s%.*s: %s", i ? ", " : "", LIT(fn.parameters[i].name), fn.parameters[i].type.odin);
		if (!fn.is_async) {
			source = gb_string_append_fmt(source, "foreign swift_library {\n\t@(link_name=\"%.*s\")\n\t%.*s :: proc \"swift\" (%s)", LIT(fn.symbol), LIT(fn.odin_name), params);
			if (fn.result.odin) source = gb_string_append_fmt(source, " -> %s", fn.result.odin);
			source = gb_string_appendc(source, " ---\n}\n\n");
			continue;
		}
		source = gb_string_append_fmt(source, "@(require_results)\n%.*s :: proc(%s%scompletion: proc(swift.Task", LIT(fn.odin_name), params, gb_string_length(params) ? ", " : "");
		if (fn.result.odin) source = gb_string_append_fmt(source, ", %s", fn.result.odin);
		source = gb_string_appendc(source, ")) -> (task: swift.Task, ok: bool) #optional_ok {\n");
		source = gb_string_append_fmt(source, "\ttask = swift.Task(intrinsics.swift_async_call(\"%.*s\", completion", LIT(fn.symbol));
		for (auto const &param : fn.parameters) source = gb_string_append_fmt(source, ", %.*s", LIT(param.name));
		source = gb_string_appendc(source, "))\n\treturn task, task != nil\n}\n\n");
	}
	for (auto const &fn : functions) {
		if (fn.base_name == fn.odin_name) continue;
		isize count = 0;
		for (auto const &other : functions) {
			if (other.base_name == fn.base_name || other.odin_name == fn.base_name) count++;
		}
		for (auto name : names) if (name == fn.base_name) count++;
		for (auto name : pkg->unsupported) if (name == fn.base_name) count++;
		if (count == 1) {
			source = gb_string_append_fmt(source, "%.*s :: %.*s\n", LIT(fn.base_name), LIT(fn.odin_name));
		} else {
			array_add(&pkg->unsupported, fn.base_name);
		}
	}
	return swift_import_write(node, swift_import_path(pkg->directory, "import.odin"), source);
}
#endif

// Foreign Swift imports become normal Odin package scopes after inspection.
gb_internal bool swift_import_setup(Ast *node, String base_dir, String spec, String *import_path) {
#if !defined(GB_SYSTEM_OSX)
	syntax_error(node, "Swift imports require a macOS host with Xcode");
	return false;
#else
	if (build_context.metrics.os != TargetOs_darwin || build_context.metrics.arch != TargetArch_arm64) {
		syntax_error(node, "Swift imports currently require a Darwin arm64 target");
		return false;
	}
#if LLVM_VERSION_MAJOR < 18
	syntax_error(node, "Swift imports require LLVM 18 or newer");
	return false;
#endif
	if (build_context.cached) {
		syntax_error(node, "Swift imports do not yet support -internal-cached builds");
		return false;
	}
	String module = spec;
	isize slash = -1;
	for (isize i = 0; i < spec.len; i++) if (spec[i] == '/') slash = i;
	if (slash >= 0) module = substring(spec, slash+1, spec.len);
	if (!swift_import_identifier(module) || !is_import_path_valid(spec) || is_import_path_absolute(spec) ||
	    node->ForeignImportDecl.library_name.string.len == 0 || node->ForeignImportDecl.attributes.count != 0) {
		syntax_error(node, "Swift import requires an explicit name and a relative module path, without attributes");
		return false;
	}
	String module_path = slash < 0 ? base_dir : get_fullpath_relative(permanent_allocator(), base_dir, substring(spec, 0, slash), nullptr);
	module_path = path_to_full_path(permanent_allocator(), module_path);
	String library = {};
	char const *suffixes[] = {".o", ".a"};
	for (isize i = 0; i < 2; i++) {
		String name = concatenate_strings(permanent_allocator(), module, make_string_c(suffixes[i]));
		if (i == 1) name = concatenate_strings(permanent_allocator(), str_lit("lib"), name);
		String candidate = swift_import_path(module_path, alloc_cstring(permanent_allocator(), name));
		if (gb_file_exists(alloc_cstring(permanent_allocator(), candidate))) {
			if (library.len) {
				syntax_error(node, "Swift import: ambiguous object/archive for '%.*s'", LIT(module));
				return false;
			}
			library = candidate;
		}
	}
	bool framework = library.len == 0;
	if (framework) {
		String module_file = swift_import_path(module_path, alloc_cstring(permanent_allocator(), concatenate_strings(permanent_allocator(), module, str_lit(".swiftmodule"))));
		if (slash >= 0 || gb_file_exists(alloc_cstring(permanent_allocator(), module_file))) {
			syntax_error(node, "Swift import: expected %.*s.o or lib%.*s.a beside the module", LIT(module), LIT(module));
			return false;
		}
		library = concatenate3_strings(permanent_allocator(), str_lit("system:"), module, str_lit(".framework"));
	}
	mutex_lock(&swift_import_mutex);
	defer (mutex_unlock(&swift_import_mutex));
	for (auto const &pkg : swift_import_packages) {
		if (pkg.module == module && (pkg.framework || pkg.path == module_path) && pkg.library == library) {
			*import_path = pkg.directory;
			return true;
		}
	}
	if (!swift_import_packages.allocator.proc) {
		array_init(&swift_import_packages, permanent_allocator());
		array_init(&swift_import_directories, permanent_allocator());
	}
	String temp = temporary_directory(permanent_allocator());
	String pattern = swift_import_path(temp, "odin-swift-XXXXXX");
	char *directory = alloc_cstring(permanent_allocator(), pattern);
	if (!mkdtemp(directory)) {
		syntax_error(node, "Swift import: cannot create temporary directory");
		return false;
	}
	String path = path_to_full_path(permanent_allocator(), make_string_c(directory));
	array_add(&swift_import_directories, path);
	SwiftImportPackage pkg = {};
	pkg.module = module;
	pkg.path = module_path;
	pkg.library = library;
	pkg.directory = path;
	pkg.framework = framework;
	if (!swift_import_generate(node, &pkg)) return false;
	array_add(&swift_import_packages, pkg);
	*import_path = path;
	return true;
#endif
}

gb_internal bool swift_import_unsupported(String path, String name) {
#if defined(GB_SYSTEM_OSX)
	mutex_lock(&swift_import_mutex);
	defer (mutex_unlock(&swift_import_mutex));
	for (auto const &pkg : swift_import_packages) {
		if (pkg.directory != path) continue;
		for (String unsupported : pkg.unsupported) if (unsupported == name) return true;
	}
#endif
	return false;
}

gb_internal void swift_import_cleanup(void) {
#if defined(GB_SYSTEM_OSX)
	for (String directory : swift_import_directories) {
		if (build_context.keep_temp_files) {
			gb_printf_err("Swift import files: %.*s\n", LIT(directory));
		} else {
			removefile(alloc_cstring(permanent_allocator(), directory), nullptr, REMOVEFILE_RECURSIVE);
		}
	}
#endif
}
