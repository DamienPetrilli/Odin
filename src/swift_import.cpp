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

struct SwiftImportRejection {
	String name, reason, title;
};

struct SwiftImportPackage {
	String module, path, library;
	String directory;
	Array<SwiftImportRejection> unsupported;
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
	bool scalar_only; // Narrow scalars need per-aggregate layout checks.
};

// Keep source identity, Odin spelling and ABI spelling together. Swift.Int
// and Swift.UInt are pointer-width types on the supported Darwin arm64 target.
struct SwiftImportScalar {
	char const *usr;
	SwiftImportType type;
};

gb_global SwiftImportScalar const swift_import_scalars[] = {
	{"s:s6UInt64V", {"Swift.UInt64", "u64", "i64", nullptr}},
	{"s:s5Int64V",  {"Swift.Int64", "i64", "i64", nullptr}},
	{"s:s4Int8V", {"Swift.Int8", "i8", "i8", nullptr, true}},
	{"s:s5UInt8V", {"Swift.UInt8", "u8", "i8", nullptr, true}},
	{"s:s5Int16V", {"Swift.Int16", "i16", "i16", nullptr, true}},
	{"s:s6UInt16V", {"Swift.UInt16", "u16", "i16", nullptr, true}},
	{"s:s5Int32V", {"Swift.Int32", "i32", "i32", nullptr, true}},
	{"s:s6UInt32V", {"Swift.UInt32", "u32", "i32", nullptr, true}},
	{"s:Sf", {"Swift.Float", "f32", "float", nullptr, true}},
	{"s:Sd",       {"Swift.Double", "f64", "double", nullptr}},
	{"s:Sb",       {"Swift.Bool", "bool", "i1", nullptr}},
	{"s:Si",       {"Swift.Int", "int", "i64", nullptr}},
	{"s:Su",       {"Swift.UInt", "uint", "i64", nullptr}},
};

struct SwiftImportField {
	String name;
	SwiftImportType type;
	String swift_name;
	u64 offset;
};

struct SwiftImportCase {
	String name, symbol, tag_name;
	Array<SwiftImportField> fields;
	bool has_payload, available;
	u32 tag;
};

struct SwiftImportNominal {
	String name, swift_name, usr, symbol, mangled, indirect_llvm;
	String generic_parent, generic_suffix;
	String date_getter, date_initializer;
	String uuid_getter, uuid_initializer;
	String set_initializer;
	bool set_scalar;
	String set_hash, set_equal;
	SwiftImportNominal *set_array;
	JsonValue *declaration;
	SwiftImportNominal *argument;
	Array<SwiftImportCase> cases;
	Array<SwiftImportField> fields;
	Array<SwiftImportType> components;
	u64 size, alignment, stride;
	bool projected, owns, resolving, resolved, static_metadata;
	SwiftImportValueKind kind;
	bool supported, is_enum, is_frozen, is_template, is_optional, is_scalar, is_record, is_date, is_uuid, is_error;
};

enum SwiftImportBorrow {
	SwiftImportBorrow_None,
	SwiftImportBorrow_Pointer,
	SwiftImportBorrow_MutablePointer,
	SwiftImportBorrow_Buffer,
	SwiftImportBorrow_MutableBuffer,
};

struct SwiftImportParameter {
	String name, label;
	SwiftImportType type;
	bool empty_set;
	bool objc_controller;
	bool self_register;
	SwiftImportBorrow borrow;
	bool consumed;
};

struct SwiftImportFunction {
	String name, title, signature, symbol, odin_name, base_name, rejection;
	JsonValue *api, *available_since, *deprecated_since;
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
	bool record_inout; // The verified native storage is borrowed through a typed Odin pointer.
	bool value_receiver; // Lowered as the last Swift value argument, named first in Odin.
};

gb_internal bool swift_import_indirect(SwiftImportType const &type);
gb_internal bool swift_import_owns(SwiftImportType const &type);
gb_internal bool swift_import_native_owns(SwiftImportType const &type);

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
		"bool", "int", "uint", "rawptr", "string", "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64", "f32", "f64", "Maybe", "mem", "strings",
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

gb_internal SwiftImportType swift_import_nominal_type(SwiftImportNominal *type);

gb_internal bool swift_import_slice(SwiftImportNominal *type) {
	return type && type->kind == SwiftImportValue_Array;
}

gb_internal bool swift_import_value_slice(SwiftImportNominal *type) {
	return swift_import_slice(type) && !type->argument->is_scalar && type->argument->kind != SwiftImportValue_String;
}

gb_internal char const *swift_import_slice_element(SwiftImportNominal *type) {
	return swift_import_nominal_type(type->argument).odin;
}

gb_internal bool swift_import_scalar(String name, SwiftImportType *type) {
	for (auto const &scalar : swift_import_scalars) {
		if (name == make_string_c(scalar.usr) || name == make_string_c(scalar.type.swift)) {
			*type = scalar.type;
			return true;
		}
	}
	return false;
}

gb_internal SwiftImportType swift_import_nominal_type(SwiftImportNominal *type) {
	if (type->is_scalar) {
		SwiftImportType scalar = {};
		bool found = swift_import_scalar(type->swift_name, &scalar);
		GB_ASSERT(found);
		scalar.nominal = type;
		return scalar;
	}
	char const *odin = type->kind == SwiftImportValue_String ? "string" : alloc_cstring(permanent_allocator(), type->name);
	if (swift_import_slice(type) || type->kind == SwiftImportValue_Set) odin = gb_string_appendc(gb_string_make(permanent_allocator(), "[]"), swift_import_slice_element(type));
	char const *llvm = type->kind == SwiftImportValue_String ? "{ i64, ptr }" : type->kind == SwiftImportValue_Opaque ? "ptr noalias" : "ptr";
	return {alloc_cstring(permanent_allocator(), type->swift_name), odin, llvm, type};
}

gb_internal bool swift_import_named_type(String usr, SwiftImportType *type, Array<SwiftImportNominal *> const &types) {
	if (!swift_import_scalar(usr, type)) {
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
	if (parameter.nominal->kind == SwiftImportValue_Set || (swift_import_slice(parameter.nominal) && usr != "s:Sq")) return false;
	bool optional = usr == "s:Sq";
	bool array = usr == "s:Sa";
	// Bool buffer storage requires a separate conversion contract.
	if ((array || usr == "s:Sh") && make_string_c(parameter.swift) == "Swift.Bool") return false;
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
	instance->is_error = base && base->is_error;
	instance->kind = array ? SwiftImportValue_Array : set ? SwiftImportValue_Set : SwiftImportValue_Opaque;
	array_add(types, instance);
	if (set) {
		SwiftImportType storage = {};
		if (!swift_import_container_type(str_lit("s:Sa"), parameter, &storage, types)) return false;
		instance->set_array = storage.nominal;
	}
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
	// Foundation.Date is resilient. Project through its public Swift initializer
	// and getter, never by assuming that its native storage is one Double.
	if (usr == "s:10Foundation4DateV" && children.count == 0) {
		SwiftImportNominal *date = nullptr;
		for (auto candidate : *types) if (candidate->usr == usr) date = candidate;
		if (!date) {
			date = gb_alloc_item(permanent_allocator(), SwiftImportNominal);
			*date = {};
			date->name = str_lit("Date");
			date->swift_name = str_lit("Foundation.Date");
			date->usr = usr;
			date->symbol = str_lit("$s10Foundation4DateV");
			array_add(types, date);
		}
		date->is_date = true;
		*type = swift_import_nominal_type(date);
		return true;
	}
	if (usr == "s:10Foundation4UUIDV" && children.count == 0) {
		SwiftImportNominal *uuid = nullptr;
		for (auto candidate : *types) if (candidate->usr == usr) uuid = candidate;
		if (!uuid) {
			uuid = gb_alloc_item(permanent_allocator(), SwiftImportNominal);
			*uuid = {};
			uuid->name = str_lit("UUID");
			uuid->swift_name = str_lit("Foundation.UUID");
			uuid->usr = usr;
			uuid->symbol = str_lit("$s10Foundation4UUIDV");
			array_add(types, uuid);
		}
		uuid->is_uuid = true;
		*type = swift_import_nominal_type(uuid);
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
	if (!swift_import_api_type(children[0], &parameter, types, argument) || (parameter.scalar_only && usr != "s:Sq")) return false;
	if (!parameter.nominal) {
		if ((usr != "s:Sa" && usr != "s:Sq" && usr != "s:Sh") || !parameter.swift) return false;
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

gb_internal void swift_import_reject(SwiftImportPackage *pkg, String name, String reason = {}, String title = {}) {
	if (!reason.len) reason = str_lit("unsupported Swift declaration form");
	for (auto &rejection : pkg->unsupported) {
		if (rejection.name == name) {
			if (rejection.title != title) rejection.title = {};
			if (rejection.reason != reason) rejection.reason = concatenate3_strings(permanent_allocator(), rejection.reason, str_lit("\n\t"), reason);
			return;
		}
	}
	array_add(&pkg->unsupported, SwiftImportRejection{name, reason, title});
}

gb_internal void swift_import_reject_function(SwiftImportPackage *pkg, Array<SwiftImportRejection> *lookup, SwiftImportFunction const &fn, Array<String> *report) {
	if (report && fn.signature.len) {
		String why = fn.rejection.len ? fn.rejection : str_lit("unsupported Swift declaration form");
		array_add(report, make_string_c(gb_string_append_fmt(gb_string_make(temporary_allocator(), ""), "skipped %.*s: %.*s%s%.*s\n  %.*s\n",
			LIT(fn.odin_name), LIT(fn.owner ? fn.owner->swift_name : String{}), fn.owner ? ": " : "", LIT(fn.signature), LIT(why))));
	}
	swift_import_reject(pkg, fn.odin_name, fn.rejection, fn.title);
	if (fn.base_name != fn.odin_name) array_add(lookup, (SwiftImportRejection{fn.base_name, fn.rejection, fn.title}));
}

// Record the source type at the rejected parameter/result rather than exposing
// a generated Odin error. Type aliases and nested Optional/Array names come
// from the compiler's API description, not a guessed mangled symbol.
gb_internal String swift_import_type_rejection(JsonValue *api, String parameter = {}) {
	String type = swift_import_string(api, "printedName");
	if (!type.len) type = swift_import_string(api, "name");
	if (!type.len) type = str_lit("unknown");
	gbString text = gb_string_make(permanent_allocator(), "");
	if (parameter.len) text = gb_string_append_fmt(text, "parameter '%.*s' has unsupported type or modifier '%.*s'", LIT(parameter), LIT(type));
	else text = gb_string_append_fmt(text, "unsupported result type '%.*s'", LIT(type));
	return make_string_c(text);
}

// Only accept the concrete standard-library declaration and an unmodified
// scalar pointee. An optional, inout, or escaping async view needs another contract.
gb_internal bool swift_import_borrowed_parameter(JsonValue *api, Slice<JsonValue *> fragments, SwiftImportParameter *param) {
	String usr = swift_import_string(api, "usr");
	SwiftImportBorrow kind = SwiftImportBorrow_None;
	if (usr == "s:SP") kind = SwiftImportBorrow_Pointer;
	else if (usr == "s:Sp") kind = SwiftImportBorrow_MutablePointer;
	else if (usr == "s:SR") kind = SwiftImportBorrow_Buffer;
	else if (usr == "s:Sr") kind = SwiftImportBorrow_MutableBuffer;
	else return false;

	auto children = swift_import_array(api, "children");
	if (children.count != 1 || fragments.count != 6 ||
	    swift_import_string(fragments[1], "spelling") != ": " ||
	    swift_import_string(fragments[2], "preciseIdentifier") != usr ||
	    swift_import_string(fragments[3], "spelling") != "<" ||
	    swift_import_string(fragments[5], "spelling") != ">") return false;
	SwiftImportType element = {};
	String element_usr = swift_import_string(children[0], "usr");
	if (swift_import_string(fragments[4], "preciseIdentifier") != element_usr || !swift_import_scalar(element_usr, &element)) return false;
	bool buffer = kind == SwiftImportBorrow_Buffer || kind == SwiftImportBorrow_MutableBuffer;
	String odin = concatenate_strings(permanent_allocator(), buffer ? str_lit("[]") : str_lit("^"), make_string_c(element.odin));
	param->type = {alloc_cstring(permanent_allocator(), swift_import_string(api, "printedName")),
	               alloc_cstring(permanent_allocator(), odin), buffer ? "i64, i64" : "ptr", nullptr};
	param->borrow = kind;
	return true;
}

// A Swift tuple is a list of results. On Darwin arm64 up to four full-width
// numeric elements return directly. Match the target compiler's IR as usual.
gb_internal bool swift_import_tuple_result(JsonValue *api, SwiftImportFunction *fn) {
	auto elements = swift_import_array(api, "children");
	fn->rejection = str_lit("tuple results require two to four word-sized numeric scalars");
	if (elements.count < 2 || elements.count > 4) return false;
	if (fn->is_async || fn->owner) {
		fn->rejection = str_lit("tuple results currently require a synchronous free function");
		return false;
	}
	for (auto const &p : fn->parameters) {
		if (p.type.nominal || p.borrow != SwiftImportBorrow_None) {
			fn->rejection = str_lit("tuple results with converted or borrowed parameters are unsupported");
			return false;
		}
	}

	// The digester stores the labels in printedName and the canonical types
	// in children. Accept a label only after matching its element's spelling.
	String spelling = swift_import_string(api, "printedName");
	if (spelling.len < 2 || spelling[0] != '(' || spelling[spelling.len-1] != ')') return false;
	String_Iterator it = {substring(spelling, 1, spelling.len-1)};
	String labels[4] = {};
	SwiftImportType types[4] = {};
	bool named = false;
	for_array(i, elements) {
		SwiftImportType &type = types[i];
		if (!swift_import_scalar(swift_import_string(elements[i], "usr"), &type)) return false;
		if (make_string_c(type.llvm) != "i64" && make_string_c(type.llvm) != "double") return false;
		String item = string_trim_whitespace(string_split_iterator(&it, ','));
		isize colon = swift_import_index(item, str_lit(":"));
		if (colon >= 0) {
			String label = string_trim_whitespace(substring(item, 0, colon));
			if (!swift_import_identifier(label) || label == "_") return false;
			labels[i] = swift_import_name(label, true);
			named = true;
			item = string_trim_whitespace(substring(item, colon+1, item.len));
		}
		if (item != make_string_c(type.swift)) return false;
	}
	if (it.pos != it.str.len) return false;

	gbString swift = gb_string_make(permanent_allocator(), "(");
	gbString odin = gb_string_make(permanent_allocator(), "(");
	gbString llvm = gb_string_make(permanent_allocator(), "{ ");
	for_array(i, elements) {
		char const *separator = i ? ", " : "";
		swift = gb_string_append_fmt(swift, "%s%s", separator, types[i].swift);
		odin = gb_string_appendc(odin, separator);
		if (named) {
			if (!labels[i].len) labels[i] = make_string_c(gb_string_append_fmt(gb_string_make(permanent_allocator(), ""), "value_%td", i));
			for (isize j = 0; j < i; j++) {
				if (labels[j] == labels[i]) {
					fn->rejection = str_lit("tuple result labels collide after Odin name conversion");
					return false;
				}
			}
			for (auto const &p : fn->parameters) {
				if (p.name == labels[i]) {
					fn->rejection = str_lit("tuple result label collides with an Odin parameter name");
					return false;
				}
			}
			odin = gb_string_append_fmt(odin, "%.*s: ", LIT(labels[i]));
		}
		odin = gb_string_appendc(odin, types[i].odin);
		llvm = gb_string_append_fmt(llvm, "%s%s", separator, types[i].llvm);
	}
	fn->result = {gb_string_appendc(swift, ")"), gb_string_appendc(odin, ")"), gb_string_appendc(llvm, " }"), nullptr};
	fn->rejection = {};
	return true;
}

gb_internal bool swift_import_function(JsonValue *symbol, JsonValue *api, SwiftImportFunction *fn, Array<SwiftImportNominal *> *types) {
	fn->api = api;
	fn->name = swift_import_string(api, "name");
	fn->symbol = swift_import_string(api, "mangledName");
	if (!swift_import_identifier(fn->name) || !string_starts_with(fn->symbol, str_lit("$s")) ||
	    fn->symbol.len <= 2) return false;
	for (isize i = 2; i < fn->symbol.len; i++) {
		if (!(gb_char_is_alphanumeric(fn->symbol[i]) || fn->symbol[i] == '_')) return false;
	}
	String collection_parameter = {};
	if (auto generics = swift_import_member(symbol, "swiftGenerics")) {
		fn->rejection = str_lit("unsupported Swift generic constraints");
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
		fn->rejection = {};
	} else if (swift_import_member(api, "genericSig")) {
		fn->rejection = str_lit("unsupported Swift generic signature");
		return false;
	}
	auto fragments = swift_import_array(symbol, "declarationFragments");
	for (auto fragment : fragments) {
		fn->is_main_actor |= swift_import_string(fragment, "preciseIdentifier") == "s:ScM" && swift_import_string(fragment, "kind") == "attribute";
	}
	gbString declaration = gb_string_make(permanent_allocator(), "");
	for_array(i, fragments) {
		JsonValue *fragment = fragments[i];
		String word = swift_import_string(fragment, "spelling");
		declaration = gb_string_append_length(declaration, word.text, word.len);
		if (swift_import_string(fragment, "kind") == "attribute") {
			if (swift_import_string(fragment, "preciseIdentifier") == "s:ScM") continue;
			if (word == "@" && i+1 < fragments.count && swift_import_string(fragments[i+1], "kind") == "attribute") {
				if (swift_import_string(fragments[i+1], "preciseIdentifier") == "s:ScM") continue;
				word = concatenate_strings(permanent_allocator(), word, swift_import_string(fragments[i+1], "spelling"));
			}
			fn->rejection = concatenate3_strings(permanent_allocator(), str_lit("unsupported Swift attribute '"), word, str_lit("'"));
			return false;
		} else if (string_contains_char(word, '@')) {
			fn->rejection = concatenate3_strings(permanent_allocator(), str_lit("unsupported attributed Swift declaration fragment '"), word, str_lit("'"));
			return false;
		}
		if (swift_import_string(fragment, "kind") == "keyword") {
			if (word == "async") fn->is_async = true;
			else if (word == "throws") fn->is_throwing = true;
			else if (word == "mutating") fn->is_mutating = true;
			else if (word != "func" && word != "static" && !(fn->is_collection && word == "where") &&
			         !(fn->is_property && (word == "var" || word == "let" || word == "get" || word == "set")) &&
			         !(fn->is_initializer && word == "init")) {
				fn->rejection = concatenate3_strings(permanent_allocator(), str_lit("unsupported Swift declaration keyword '"), word, str_lit("'"));
				return false;
			}
		}
	}
	for (auto attribute : swift_import_array(api, "declAttributes")) {
		if (attribute->kind != Json_String) return false;
		String name = attribute->string;
		// Inline affects the optimizer. The call still requires a verified external entry point.
		if (name == "Available" || name == "Inline" || (fn->is_property && name == "HasStorage") || (fn->is_main_actor && name == "Custom")) continue;
		if (name == "AlwaysEmitIntoClient") name = str_lit("@_alwaysEmitIntoClient");
		if (name == "Inlinable") name = str_lit("@inlinable");
		fn->rejection = concatenate3_strings(permanent_allocator(), str_lit("unsupported Swift attribute '"), name, str_lit("'"));
		return false;
	}
	fn->signature = make_string_c(declaration);
	if (fn->is_main_actor && !fn->is_async) {
		fn->rejection = str_lit("synchronous @MainActor calls require actor isolation");
		return false;
	}
	if (fn->is_collection && (!fn->is_async || fn->is_initializer || fn->is_property || (fn->owner && !fn->is_static))) return false;
	if (fn->is_throwing && !fn->is_async) {
		fn->rejection = str_lit("synchronous throws is unsupported");
		return false;
	}
	if (fn->is_throwing && (swift_import_index(fn->signature, str_lit("throws(")) >= 0 || swift_import_index(fn->signature, str_lit("throws (")) >= 0)) {
		fn->rejection = str_lit("typed throws is unsupported");
		return false;
	}
	array_init(&fn->parameters, permanent_allocator());
	if (fn->is_property) {
		auto children = swift_import_array(api, "children");
		if (children.count != 1) return false;
		bool supported = swift_import_api_type(children[0], &fn->result, types);
		if (fn->result.nominal && fn->result.nominal->kind == SwiftImportValue_Set) supported = false;
		if (!supported) fn->rejection = swift_import_type_rejection(children[0]);
		return supported;
	}
	auto api_types = swift_import_array(api, "children");
	JsonValue *signature = swift_import_member(symbol, "functionSignature");
	JsonValue *returns = swift_import_member(signature, "returns");
	bool tuple = api_types.count && swift_import_string(api_types[0], "kind") == "TypeNominal" &&
	             swift_import_string(api_types[0], "name") == "Tuple" && !swift_import_string(api_types[0], "usr").len &&
	             swift_import_array(api_types[0], "children").count > 0;
	if (fn->is_initializer) {
		// Failable initializers return Optional<Self>, not Self. The digester
		// records that result even when the symbol graph omits a return clause.
		if (api_types.count == 0 || !swift_import_api_type(api_types[0], &fn->result, types)) {
			fn->rejection = swift_import_type_rejection(api_types.count ? api_types[0] : nullptr);
			return false;
		}
		// API digester names the initializing entry; calls use the allocating
		// entry. Both the inspected IR and library exports must confirm it.
		if (!string_ends_with(fn->symbol, str_lit("cfc"))) return false;
		fn->symbol = concatenate_strings(permanent_allocator(), substring(fn->symbol, 0, fn->symbol.len-1), str_lit("C"));
	} else if (!tuple && (!returns || returns->kind != Json_Array || returns->array.count == 0 ||
	           (!swift_import_type(returns->array, true, &fn->result, *types) &&
	            (api_types.count == 0 || !swift_import_api_type(api_types[0], &fn->result, types))))) {
		fn->rejection = swift_import_type_rejection(api_types.count ? api_types[0] : nullptr);
		return false;
	}
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
		JsonValue *operand = api_types.count > fn->parameters.count+1 ? api_types[fn->parameters.count+1] : nullptr;
		auto fragments = swift_import_array(parameter, "declarationFragments");
		// Accept a nonoptional, unmodified ObjC class operand only. SIL must
		// also confirm a borrow before an async capture can own its reference.
		if (fn->is_async && selected_subtarget != Subtarget_Default &&
		    swift_import_string(operand, "usr") == "c:objc(cs)UIViewController" &&
		    swift_import_string(operand, "printedName") == "UIKit.UIViewController" &&
		    fragments.count == 3 && swift_import_string(fragments[1], "spelling") == ": " &&
		    swift_import_string(fragments[2], "preciseIdentifier") == "c:objc(cs)UIViewController") {
			p.type = {"UIKit.UIViewController", "^_swift_ui.ViewController", "ptr", nullptr};
			p.objc_controller = true;
		} else if (swift_import_borrowed_parameter(operand, fragments, &p)) {
			if (fn->is_async) {
				fn->rejection = str_lit("a borrowed Swift pointer or buffer cannot be captured across suspension");
				return false;
			}
		} else if (fn->is_collection) {
			if (api_types.count != 2 || swift_import_string(api_types[1], "name") != "GenericTypeParam" || swift_import_string(api_types[1], "printedName") != collection_parameter) return false;
			if (!swift_import_container_type(str_lit("s:Sa"), swift_import_nominal_type(swift_import_string_type(types)), &p.type, types)) return false;
		} else if (!swift_import_type(swift_import_array(parameter, "declarationFragments"), false, &p.type, *types) &&
		    (api_types.count <= fn->parameters.count+1 || !swift_import_api_type(api_types[fn->parameters.count+1], &p.type, types))) {
			fn->rejection = swift_import_type_rejection(operand, name);
			return false;
		}
		if (p.type.nominal && p.type.nominal->kind == SwiftImportValue_Set) {
			// Preserve the explicit empty default alongside the slice overload.
			auto default_arg = swift_import_member(operand, "hasDefaultArg");
			// Only elide the last parameter and verify its own default expression.
			p.empty_set = fn->parameters.count+1 == parameters.count && default_arg && default_arg->kind == Json_Boolean && default_arg->boolean &&
			              swift_import_index(make_string_c(declaration), str_lit("= [])")) >= 0;
		}
		for (auto const &previous : fn->parameters) if (previous.name == p.name) return false;
		array_add(&fn->parameters, p);
	}
	if (fn->result.nominal && fn->result.nominal->kind == SwiftImportValue_Set) {
		fn->rejection = str_lit("Set results are not supported; only Set parameters map to Odin slices");
		return false;
	}
	return it.pos == labels.len && (!tuple || swift_import_tuple_result(api_types[0], fn));
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
			if (fn->value_receiver && &param == &fn->parameters[fn->parameters.count-1] &&
			    string_starts_with(argument, str_lit("@inout"))) return false;
			if (param.objc_controller) {
				if (argument != "@guaranteed UIViewController") return false;
				continue;
			}
			if (!param.type.nominal) continue;
			if (!swift_import_native_owns(param.type)) continue;
			// A fixed-layout value stays loadable in SIL even when its large
			// LLVM register tuple is lowered to an indirect ABI parameter.
			bool indirect = (swift_import_indirect(param.type) && !param.type.nominal->alignment) || fn->is_collection;
			param.consumed = string_starts_with(argument, indirect ? str_lit("@in ") : str_lit("@owned "));
			bool borrowed = string_starts_with(argument, indirect ? str_lit("@in_guaranteed ") : str_lit("@guaranteed "));
			if (!param.consumed && !borrowed) return false;
		}
		if (fn->record_inout) {
			String self = string_trim_whitespace(string_split_iterator(&parameters, ','));
			if (!string_starts_with(self, str_lit("@inout ")) || parameters.pos != parameters.str.len) return false;
		}
		if (swift_import_native_owns(fn->result)) {
			String result = string_trim_whitespace(substring(line, end+1, line.len));
			String convention = swift_import_indirect(fn->result) && !fn->result.nominal->alignment ? str_lit("@out ") : str_lit("@owned ");
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

gb_internal int swift_import_version_part(JsonValue *version, int index) {
	char const *keys[] = {"major", "minor", "patch"};
	JsonValue *part = swift_import_member(version, keys[index]);
	return part && part->kind == Json_Number ? cast(int)part->number : 0;
}

gb_internal bool swift_import_version_after_minimum(JsonValue *version, int const *minimum) {
	for (int i = 0; i < 3; i++) {
		int part = swift_import_version_part(version, i);
		if (part != minimum[i]) return part > minimum[i];
	}
	return false;
}

gb_internal gbString swift_import_append_version(gbString text, JsonValue *version) {
	text = gb_string_append_fmt(text, "%d.%d", swift_import_version_part(version, 0), swift_import_version_part(version, 1));
	int patch = swift_import_version_part(version, 2);
	if (patch) text = gb_string_append_fmt(text, ".%d", patch);
	return text;
}

gb_internal String swift_import_availability_rejection(JsonValue *symbol, SwiftImportFunction *fn = nullptr) {
	char const *domain = selected_subtarget == Subtarget_Default ? "macOS" : "iOS";
	int minimum[3] = {};
	sscanf(alloc_cstring(temporary_allocator(), build_context.minimum_os_version_string), "%d.%d.%d", minimum, minimum+1, minimum+2);
	for (JsonValue *availability : swift_import_array(symbol, "availability")) {
		String availability_domain = swift_import_string(availability, "domain");
		if (availability_domain.len && availability_domain != "*" && availability_domain != make_string_c(domain)) continue;
		char const *why = nullptr;
		JsonValue *version = nullptr;
		JsonValue *introduced = swift_import_member(availability, "introduced");
		JsonValue *deprecated = swift_import_member(availability, "deprecated");
		if (fn) {
			if (introduced) fn->available_since = introduced;
			if (deprecated) fn->deprecated_since = deprecated;
		}
		if (swift_import_member(availability, "isUnconditionallyUnavailable")) {
			why = "unavailable on";
		} else if (swift_import_member(availability, "isUnconditionallyDeprecated")) {
			why = "deprecated on";
		} else if (introduced && swift_import_version_after_minimum(introduced, minimum)) {
			why = "requires";
			version = introduced;
		} else if ((version = swift_import_member(availability, "obsoleted"))) {
			// An unguarded import also has to work on systems newer than the minimum.
			why = "marked obsolete in";
		} else if (deprecated && !swift_import_version_after_minimum(deprecated, minimum)) {
			why = "marked deprecated in";
			version = deprecated;
		}
		if (!why) continue;
		gbString text = gb_string_append_fmt(gb_string_make(permanent_allocator(), ""), "%s %s", why, domain);
		if (version) {
			text = swift_import_append_version(gb_string_appendc(text, " "), version);
		}
		return make_string_c(gb_string_append_fmt(text, " (deployment target %s %.*s)", domain, LIT(build_context.minimum_os_version_string)));
	}
	return {};
}

// Xcode's symbol graph can omit the synthesized RawRepresentable getter.
// The digester identifies the actual member and accessor on the public enum.
// Explicit declarations, including their availability, use the symbol graph.
gb_internal JsonValue *swift_import_implicit_raw_value(JsonValue *owner, StringSet *published) {
	if (!swift_import_string(owner, "enumRawTypeName").len || swift_import_member(owner, "genericSig")) return nullptr;
	for (auto attribute : swift_import_array(owner, "declAttributes")) {
		if (attribute->kind != Json_String || (attribute->string != "Available" && attribute->string != "Frozen")) return nullptr;
	}
	for (auto child : swift_import_array(owner, "children")) {
		if (swift_import_string(child, "kind") != "Var" || swift_import_string(child, "name") != "rawValue") continue;
		auto implicit = swift_import_member(child, "implicit");
		if (!implicit || implicit->kind != Json_Boolean || !implicit->boolean || swift_import_member(child, "declAttributes")) return nullptr;
		if (!string_set_exists(published, swift_import_string(child, "usr"))) return child;
	}
	return nullptr;
}

gb_internal bool swift_import_has_receiver(SwiftImportFunction const &fn) {
	return fn.owner && !fn.is_static && !fn.is_initializer && !fn.value_receiver;
}

gb_internal bool swift_import_kind(SwiftImportType const &type, SwiftImportValueKind kind) {
	return type.nominal && type.nominal->kind == kind;
}

gb_internal bool swift_import_string_array(SwiftImportType const &type) {
	return swift_import_kind(type, SwiftImportValue_Array) && type.nominal->argument->kind == SwiftImportValue_String;
}

#include "swift_import_enum.cpp"
#include "swift_import_array.cpp"
#include "swift_import_set.cpp"
#include "swift_import_struct.cpp"
#include "swift_import_date.cpp"
#include "swift_import_uuid.cpp"
#include "swift_import_error.cpp"

gb_internal gbString swift_import_emit_type(gbString source, SwiftImportNominal *type) {
	if (type->is_scalar) return source;
	if (type->kind == SwiftImportValue_Set) return swift_import_emit_set(source, type);
	if (type->is_date) return swift_import_emit_date(source, type);
	if (type->is_uuid) return swift_import_emit_uuid(source, type);
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
	if (type->is_record) return swift_import_emit_struct(source, type);
	if (type->projected) return swift_import_emit_enum(source, type);
	if (swift_import_value_slice(type)) return swift_import_emit_array(source, type);
	if (type->kind == SwiftImportValue_String || swift_import_slice(type)) return source;
	source = gb_string_append_fmt(source,
		"@(require_results)\n%.*s_copy :: proc(value: %.*s) -> (copy: %.*s, ok: bool) #optional_ok {\n"
		"\tstorage := swift.value_copy(rawptr(value), _swift_%.*s_metadata(0).type) or_return\n"
		"\treturn %.*s(storage), true\n}\n"
		"%.*s_destroy :: proc(value: %.*s) {\n\tswift.value_destroy(rawptr(value), _swift_%.*s_metadata(0).type)\n}\n\n",
		LIT(name), LIT(name), LIT(name), LIT(name), LIT(name), LIT(name), LIT(name), LIT(name));

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

gb_internal gbString swift_import_emit_value_declaration(gbString source, SwiftImportFunction const &fn) {
	bool receiver = swift_import_has_receiver(fn);
	bool indirect_result = swift_import_indirect(fn.result);
	bool empty_result = swift_import_empty(fn.result);
	String name = fn.odin_name;
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
		if (swift_import_empty(param.type)) continue;
		if (swift_import_kind(param.type, SwiftImportValue_String)) {
			source = gb_string_append_fmt(source, "%sarg%td_bits: u64, arg%td_object: rawptr", count++ ? ", " : "", i, i);
		} else source = gb_string_append_fmt(source, "%s%sarg%td: %s", count++ ? ", " : "", param.self_register ? "#swift_self " : "", i, swift_import_indirect(param.type) ? "rawptr" : swift_import_native_type(param.type));
	}
	if (fn.is_collection) source = gb_string_append_fmt(source, "%scollection_metadata, collection_witness: rawptr", count++ ? ", " : "");
	if (receiver) source = gb_string_append_fmt(source, "%s#swift_self receiver: rawptr", count ? ", " : "");
	source = gb_string_appendc(source, ")");
	if (!fn.is_async && fn.result.odin && !indirect_result && !empty_result) source = gb_string_append_fmt(source, " -> %s", swift_import_native_type(fn.result));
	source = gb_string_appendc(source, " ---\n");
	if (fn.is_async) source = gb_string_append_fmt(source, "\t@(link_name=\"%.*sTu\")\n\t_swift_%.*s_descriptor: runtime.Swift_Async_Descriptor\n", LIT(fn.symbol), LIT(name));
	source = gb_string_appendc(source, "}\n\n");
	return source;
}

// Take the parameter and result list directly from the declaration just emitted.
// Default-argument overloads have private entry names but share a public name.
gb_internal void swift_import_report_function(Array<String> *report, SwiftImportFunction const &fn, String name, gbString source, isize signature_start) {
	if (!report) return;
	String signature = make_string(cast(u8 *)source+signature_start, gb_string_length(source)-signature_start);
	gbString row = gb_string_make(temporary_allocator(), "");
	row = gb_string_append_fmt(row, "call %.*s :: proc%.*s\n  Swift: ", LIT(name), LIT(signature));
	if (fn.owner) row = gb_string_append_fmt(row, "%.*s: ", LIT(fn.owner->swift_name));
	row = gb_string_append_fmt(row, "%.*s\n", LIT(fn.signature));
	char const *platform = selected_subtarget == Subtarget_Default ? "macOS" : "iOS";
	if (fn.available_since) {
		row = swift_import_append_version(gb_string_append_fmt(row, "  introduced: %s ", platform), fn.available_since);
		row = gb_string_appendc(row, "\n");
	}
	if (fn.deprecated_since) {
		row = swift_import_append_version(gb_string_append_fmt(row, "  deprecated: %s ", platform), fn.deprecated_since);
		row = gb_string_appendc(row, "\n");
	}
	if (swift_import_has_receiver(fn) || fn.value_receiver) {
		char const *borrow = !fn.is_async ? (fn.is_mutating ? "exclusive borrow during call" : "borrowed during call") : fn.is_mutating ? "exclusive borrow through completion" : "copied for task";
		row = gb_string_append_fmt(row, "  receiver: %s\n", borrow);
	}
	for (auto const &param : fn.parameters) {
		if (param.empty_set || (fn.value_receiver && param.name == "receiver")) continue;
		if (param.objc_controller) row = gb_string_append_fmt(row, "  %.*s: retained through completion\n", LIT(param.name));
		else if (param.borrow != SwiftImportBorrow_None) {
			bool writable = param.borrow == SwiftImportBorrow_MutableBuffer || param.borrow == SwiftImportBorrow_MutablePointer;
			bool pointer = param.borrow == SwiftImportBorrow_Pointer || param.borrow == SwiftImportBorrow_MutablePointer;
			row = gb_string_append_fmt(row, "  %.*s: borrowed %s storage%s; caller controls lifetime\n", LIT(param.name), writable ? "mutable" : "read-only", pointer ? " (non-null pointer)" : "");
		} else if (param.type.nominal) row = gb_string_append_fmt(row, "  %.*s: caller keeps ownership\n", LIT(param.name));
	}
	if (fn.is_async) {
		row = gb_string_appendc(row, "  start: owned task (swift.task_release); false means no callback\n  completion: borrowed task");
		if (fn.is_throwing) row = gb_string_appendc(row, "; owned err (Async_Error_destroy); nil means success");
		else if (swift_import_owns(fn.result) && (swift_import_projected(fn.result) || swift_import_slice(fn.result.nominal) || swift_import_kind(fn.result, SwiftImportValue_String))) {
			row = gb_string_appendc(row, "; final bool reports result conversion");
		}
		if (fn.result.nominal && fn.result.nominal->is_optional) row = gb_string_appendc(row, "; nil is an absent value on success");
		row = gb_string_appendc(row, "\n");
	}
	if (swift_import_owns(fn.result)) {
		row = gb_string_appendc(row, "  owned result: ");
		row = swift_import_emit_destroy(row, fn.result, str_lit("result"));
	}
	array_add(report, make_string_c(row));
}

gb_internal void swift_import_report_type(Array<String> *report, SwiftImportNominal *type) {
	auto value = swift_import_nominal_type(type);
	char const *representation = "opaque owner";
	if (type->kind == SwiftImportValue_String) representation = "UTF-8 string";
	else if (swift_import_slice(type)) representation = "slice";
	else if (type->kind == SwiftImportValue_Set) representation = "input slice";
	else if (type->is_uuid) representation = "core:encoding/uuid.Identifier";
	else if (type->is_date) representation = "swift.Date";
	else if (type->is_record) representation = "struct";
	else if (type->projected && type->is_optional) representation = "Maybe";
	else if (type->projected && swift_import_plain_enum(type)) representation = "enum";
	else if (type->projected && type->is_enum) representation = "union";

	gbString row = gb_string_append_fmt(gb_string_make(temporary_allocator(), ""),
		"type %.*s -> %s (%s", LIT(type->swift_name), value.odin, representation);
	if (type->declaration) row = gb_string_appendc(row, type->is_frozen ? ", frozen" : ", resilient");
	row = gb_string_appendc(row, ")\n");
	if (type->projected && type->is_optional) row = gb_string_append_fmt(row, "  Maybe(%s)\n", swift_import_slice_element(type));
	if (type->kind == SwiftImportValue_Opaque && swift_import_owns(value)) {
		row = gb_string_append_fmt(row, "  owned value: %.*s_destroy; independent copy: %.*s_copy\n", LIT(type->name), LIT(type->name));
	}
	array_add(report, make_string_c(row));
}

gb_internal GB_COMPARE_PROC(swift_import_report_compare) {
	return string_compare(*cast(String const *)a, *cast(String const *)b);
}

gb_internal gbString swift_import_emit_value_function(gbString source, SwiftImportFunction const &fn, String native_name, Array<String> *report) {
	bool receiver = swift_import_has_receiver(fn);
	bool indirect_result = swift_import_indirect(fn.result);
	bool empty_result = swift_import_empty(fn.result);
	bool string_result = swift_import_kind(fn.result, SwiftImportValue_String);
	bool slice_result = swift_import_slice(fn.result.nominal);
	bool projected_result = swift_import_projected(fn.result);
	bool fixed_result = projected_result && fn.result.nominal->alignment;
	bool owned_result = fn.result.nominal && !string_result && !slice_result && !projected_result;
	bool allocated_result = owned_result || (projected_result && !fixed_result);
	bool converted_result = string_result || slice_result || (projected_result && fn.result.nominal->owns);
	bool fallible = projected_result ? fn.result.nominal->owns || !fixed_result : fn.result.nominal != nullptr;
	String name = fn.odin_name;
	bool entry_needs_capture = indirect_result || receiver || fn.is_collection;
	gbString params = gb_string_make(permanent_allocator(), "");
	gbString arguments = gb_string_make(permanent_allocator(), "");
	if (receiver || fn.value_receiver) params = gb_string_append_fmt(params, "receiver: %s%.*s", fn.record_inout ? "^" : "", LIT(fn.owner->name));
	for_array(i, fn.parameters) {
		auto const &param = fn.parameters[i];
		if (!param.empty_set && !(fn.value_receiver && i == fn.parameters.count-1)) params = gb_string_append_fmt(params, "%s%.*s: %s", gb_string_length(params) ? ", " : "", LIT(param.name), param.type.odin);
		fallible |= (swift_import_projected(param.type) && (param.type.nominal->owns || !param.type.nominal->alignment)) || swift_import_kind(param.type, SwiftImportValue_String) || swift_import_slice(param.type.nominal) || (swift_import_kind(param.type, SwiftImportValue_Set) && !param.empty_set) || (param.consumed && !param.empty_set);
		if (swift_import_empty(param.type)) continue;
		entry_needs_capture |= !param.empty_set;
		if (gb_string_length(arguments)) arguments = gb_string_appendc(arguments, ", ");
		if (param.empty_set) arguments = gb_string_appendc(arguments, "swift.empty_set()");
		else if (swift_import_projected(param.type)) {
			arguments = gb_string_append_fmt(arguments, "%s%sarg%td", swift_import_indirect(param.type) && param.type.nominal->alignment ? "&" : "", fn.is_async ? "capture." : "_swift_", i);
		} else if (swift_import_kind(param.type, SwiftImportValue_String)) {
			arguments = gb_string_append_fmt(arguments, "%sarg%td.bits, %sarg%td.object", fn.is_async ? "capture." : "_swift_", i, fn.is_async ? "capture." : "_swift_", i);
		} else if (swift_import_slice(param.type.nominal) || swift_import_kind(param.type, SwiftImportValue_Set)) {
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

	if (!fn.is_async) {
		if (string_starts_with(name, str_lit("_swift_"))) source = gb_string_appendc(source, "@(private)\n");
		if (fallible) source = gb_string_appendc(source, "@(require_results)\n");
		source = gb_string_append_fmt(source, "%.*s :: proc", LIT(name));
		isize signature_start = gb_string_length(source);
		source = gb_string_append_fmt(source, "(%s)", params);
		if (fallible && fn.result.odin) source = gb_string_append_fmt(source, " -> (_swift_result: %s, ok: bool) #optional_ok", fn.result.odin);
		else if (fallible) source = gb_string_appendc(source, " -> (ok: bool)");
		else if (fn.result.odin) source = gb_string_append_fmt(source, " -> %s", fn.result.odin);
		swift_import_report_function(report, fn, native_name, source, signature_start);
		source = gb_string_appendc(source, " {\n");
		gbString release_inputs = nullptr;
		bool consumes = false;
		for (auto const &param : fn.parameters) consumes |= param.consumed && !param.empty_set;
		if (consumes) source = gb_string_appendc(source, "\t_swift_called := false\n");
		bool has_date = fn.result.nominal && fn.result.nominal->is_date;
		bool has_uuid = fn.result.nominal && fn.result.nominal->is_uuid;
		for (auto const &param : fn.parameters) {
			has_date |= param.type.nominal && param.type.nominal->is_date;
			has_uuid |= param.type.nominal && param.type.nominal->is_uuid;
		}
		if (has_date) source = gb_string_appendc(source, "\t_swift_date_layout := _swift_Date_layout\n");
		if (has_uuid) source = gb_string_appendc(source, "\t_swift_uuid_layout := _swift_UUID_layout\n");
		if (receiver) source = gb_string_appendc(source, "\tassert(receiver != nil, \"Cannot borrow a nil Swift value\")\n");
		for_array(i, fn.parameters) {
			auto const &param = fn.parameters[i];
			if (param.empty_set) continue;
			if (swift_import_projected(param.type)) {
				auto type = param.type.nominal;
				if (type->alignment) source = gb_string_append_fmt(source, "\t_swift_arg%td: %s\n", i, swift_import_enum_native(type));
				else if (type->is_date) source = gb_string_append_fmt(source, "\t_swift_temporary%td: swift.Value_Temporary = ---\n\t_swift_arg%td := swift.value_temporary_from_layout(&_swift_temporary%td, _swift_date_layout) or_return\n\tdefer if !_swift_date_layout.inline_temporary { swift.value_free_uninitialized(_swift_arg%td) }\n", i, i, i, i);
				else if (type->is_uuid) source = gb_string_append_fmt(source, "\t_swift_temporary%td: swift.Value_Temporary = ---\n\t_swift_arg%td := swift.value_temporary_from_layout(&_swift_temporary%td, _swift_uuid_layout) or_return\n\tdefer if !_swift_uuid_layout.inline_temporary { swift.value_free_uninitialized(_swift_arg%td) }\n", i, i, i, i);
				else source = gb_string_append_fmt(source, "\t_swift_temporary%td: swift.Value_Temporary = ---\n\t_swift_arg%td := swift.value_temporary(&_swift_temporary%td, _swift_%.*s_metadata(0).type) or_return\n\tdefer swift.value_temporary_free(&_swift_temporary%td, _swift_arg%td)\n", i, i, i, LIT(type->name), i, i);
				if (fallible) source = gb_string_append_fmt(source, "\tif !_swift_%.*s_initialize(%s_swift_arg%td, %.*s) { return }\n", LIT(type->name), type->alignment ? "&" : "", i, LIT(param.name));
				else source = gb_string_append_fmt(source, "\t_swift_initialized%td := _swift_%.*s_initialize(%s_swift_arg%td, %.*s)\n\tassert(_swift_initialized%td)\n", i, LIT(type->name), type->alignment ? "&" : "", i, LIT(param.name), i);
				if (type->is_date) source = gb_string_append_fmt(source, "\tdefer %sswift.value_deinitialize_from_layout(_swift_arg%td, _swift_date_layout)%s\n", param.consumed ? "if !_swift_called { " : "", i, param.consumed ? " }" : "");
				else if (type->is_uuid) source = gb_string_append_fmt(source, "\tdefer %sswift.value_deinitialize_from_layout(_swift_arg%td, _swift_uuid_layout)%s\n", param.consumed ? "if !_swift_called { " : "", i, param.consumed ? " }" : "");
				else if (swift_import_native_owns(swift_import_nominal_type(type))) source = gb_string_append_fmt(source, "\tdefer %sswift.value_deinitialize(%s_swift_arg%td, _swift_%.*s_metadata(0).type)%s\n", param.consumed ? "if !_swift_called { " : "", type->alignment ? "&" : "", i, LIT(type->name), param.consumed ? " }" : "");
			} else if (swift_import_kind(param.type, SwiftImportValue_String)) {
				source = gb_string_append_fmt(source, "\t_swift_arg%td := swift.string_from_odin(%.*s) or_return\n\tdefer %sswift.string_destroy(&_swift_arg%td)%s\n", i, LIT(param.name), param.consumed ? "if !_swift_called { " : "", i, param.consumed ? " }" : "");
			} else if (swift_import_kind(param.type, SwiftImportValue_Set)) {
				source = gb_string_append_fmt(source, "\t_swift_arg%td := _swift_%.*s_from(%.*s) or_return\n", i, LIT(param.type.nominal->name), LIT(param.name));
				source = gb_string_append_fmt(source, "\tdefer %sswift.set_destroy(_swift_arg%td)%s\n", param.consumed ? "if !_swift_called { " : "", i, param.consumed ? " }" : "");
			} else if (swift_import_slice(param.type.nominal)) {
				source = gb_string_append_fmt(source, "\t_swift_arg%td := %.*s or_return\n", i, LIT(swift_import_array_from(param.type.nominal, param.name)));
				// An owned result may share the input array. Drop the temporary
				// reference before checking whether its elements can be taken.
				if (param.type.nominal == fn.result.nominal && !param.consumed && swift_import_native_owns(swift_import_nominal_type(param.type.nominal->argument))) {
					source = gb_string_append_fmt(source, "\tdefer if _swift_arg%td.storage != nil { swift.array_destroy(_swift_arg%td) }\n", i, i);
					if (!release_inputs) release_inputs = gb_string_make(temporary_allocator(), "");
					release_inputs = gb_string_append_fmt(release_inputs, "\tswift.array_destroy(_swift_arg%td)\n\t_swift_arg%td = {}\n", i, i);
				} else {
					source = gb_string_append_fmt(source, "\tdefer %sswift.array_destroy(_swift_arg%td)%s\n", param.consumed ? "if !_swift_called { " : "", i, param.consumed ? " }" : "");
				}
			} else if (param.type.nominal) {
				source = gb_string_append_fmt(source, "\tassert(%.*s != nil, \"Cannot borrow a nil Swift value\")\n", LIT(param.name));
				if (param.consumed) source = gb_string_append_fmt(source, "\t_swift_arg%td := swift.value_copy(rawptr(%.*s), _swift_%.*s_metadata(0).type) or_return\n", i, LIT(param.name), LIT(param.type.nominal->name));
			}
			if (param.type.nominal && !param.type.nominal->projected && param.type.nominal->kind != SwiftImportValue_String && !swift_import_slice(param.type.nominal) && !swift_import_kind(param.type, SwiftImportValue_Set) && param.consumed) {
				source = gb_string_append_fmt(source, "\tdefer if _swift_called { swift.value_free_uninitialized(_swift_arg%td) } else { swift.value_destroy(_swift_arg%td, _swift_%.*s_metadata(0).type) }\n", i, i, LIT(param.type.nominal->name));
			}
		}
		if (fixed_result) source = gb_string_append_fmt(source, "\t_swift_storage: %s\n", swift_import_enum_native(fn.result.nominal));
		if (projected_result && fn.result.nominal->is_date) source = gb_string_appendc(source, "\t_swift_result_temporary: swift.Value_Temporary = ---\n\t_swift_storage := swift.value_temporary_from_layout(&_swift_result_temporary, _swift_date_layout) or_return\n\tdefer if !_swift_date_layout.inline_temporary { swift.value_free_uninitialized(_swift_storage) }\n");
		else if (projected_result && fn.result.nominal->is_uuid) source = gb_string_appendc(source, "\t_swift_result_temporary: swift.Value_Temporary = ---\n\t_swift_storage := swift.value_temporary_from_layout(&_swift_result_temporary, _swift_uuid_layout) or_return\n\tdefer if !_swift_uuid_layout.inline_temporary { swift.value_free_uninitialized(_swift_storage) }\n");
		else if (projected_result && !fixed_result) source = gb_string_append_fmt(source, "\t_swift_result_temporary: swift.Value_Temporary = ---\n\t_swift_storage := swift.value_temporary(&_swift_result_temporary, _swift_%.*s_metadata(0).type) or_return\n\tdefer swift.value_temporary_free(&_swift_result_temporary, _swift_storage)\n", LIT(fn.result.nominal->name));
		else if (allocated_result) source = gb_string_append_fmt(source, "\t_swift_storage := swift.value_allocate(_swift_%.*s_metadata(0).type) or_return\n", LIT(fn.result.nominal->name));
		char const *assignment = !fn.result.odin || indirect_result || empty_result ? "" : projected_result ? "_swift_storage = " : owned_result ? "(cast(^rawptr)_swift_storage)^ = " : "_swift_value := ";
		source = gb_string_append_fmt(source, "\t%s_swift_%.*s_native(%s%s%s)\n", assignment, LIT(native_name), indirect_result ? (fixed_result ? "&_swift_storage" : "_swift_storage") : "", indirect_result && gb_string_length(arguments) ? ", " : "", arguments);
		if (consumes) source = gb_string_appendc(source, "\t_swift_called = true\n");
		if (release_inputs) source = gb_string_appendc(source, release_inputs);
		if (projected_result) {
			source = gb_string_append_fmt(source, "\t_swift_result_value, _swift_converted := _swift_%.*s_take(%s_swift_storage%s)\n", LIT(fn.result.nominal->name), fixed_result ? "&" : "", fn.result.nominal->is_date ? ", _swift_date_layout" : fn.result.nominal->is_uuid ? ", _swift_uuid_layout" : "");
			if (fallible) source = gb_string_appendc(source, "\treturn _swift_result_value, _swift_converted\n");
			else source = gb_string_appendc(source, "\tassert(_swift_converted)\n\treturn _swift_result_value\n");
		} else if (slice_result) source = gb_string_append_fmt(source, "\tdefer swift.array_destroy(swift.Native_Array{_swift_value})\n\treturn %.*s\n", LIT(swift_import_array_to(fn.result.nominal, str_lit("swift.Native_Array{_swift_value}"))));
		else if (string_result) source = gb_string_appendc(source, "\tdefer swift.string_destroy(&_swift_value)\n\treturn swift.string_to_odin(_swift_value)\n");
		else if (owned_result) source = gb_string_append_fmt(source, "\treturn %s(_swift_storage), true\n", fn.result.odin);
		else if (fn.result.odin) source = gb_string_append_fmt(source, "\treturn _swift_value%s\n", fallible ? ", true" : "");
		else if (fallible) source = gb_string_appendc(source, "\treturn true\n");
		return gb_string_appendc(source, "}\n\n");
	}

	if (string_starts_with(name, str_lit("_swift_"))) source = gb_string_appendc(source, "@(private)\n");
	source = gb_string_append_fmt(source, "@(require_results)\n%.*s :: proc", LIT(name));
	isize signature_start = gb_string_length(source);
	source = gb_string_append_fmt(source, "(%s%scompletion: proc(swift.Task", params, gb_string_length(params) ? ", " : "");
	if (fn.result.odin) source = gb_string_append_fmt(source, ", %s", fn.result.odin);
	if (fn.is_throwing) source = gb_string_appendc(source, ", Async_Error");
	if (converted_result && !fn.is_throwing) source = gb_string_appendc(source, ", bool");
	source = gb_string_appendc(source, ")) -> (task: swift.Task, ok: bool) #optional_ok");
	swift_import_report_function(report, fn, native_name, source, signature_start);
	source = gb_string_appendc(source, " {\n\tif completion == nil");
	if (receiver) source = gb_string_appendc(source, " || receiver == nil");
	for (auto const &param : fn.parameters) if (param.objc_controller || (param.type.nominal && !param.type.nominal->projected && !param.empty_set && !swift_import_kind(param.type, SwiftImportValue_String) && !swift_import_slice(param.type.nominal) && !swift_import_kind(param.type, SwiftImportValue_Set))) source = gb_string_append_fmt(source, " || %.*s == nil", LIT(param.name));
	source = gb_string_appendc(source, " { return }\n\tCapture :: struct {\n\t\tcompletion: type_of(completion),\n");
	if (receiver) source = gb_string_appendc(source, "\t\treceiver: rawptr,\n");
	for_array(i, fn.parameters) if (!fn.parameters[i].empty_set) source = gb_string_append_fmt(source, "\t\targ%td: %s,\n", i, swift_import_slice(fn.parameters[i].type.nominal) ? "swift.Native_Array" : swift_import_kind(fn.parameters[i].type, SwiftImportValue_Set) ? "swift.Native_Set" : swift_import_native_type(fn.parameters[i].type));
	if (fn.is_collection) source = gb_string_appendc(source, "\t\tcollection_metadata, collection_witness: rawptr,\n");
	if (fn.result.odin) source = gb_string_append_fmt(source, "\t\tresult: %s,\n", swift_import_native_type(fn.result));
	if (fn.is_throwing) source = gb_string_appendc(source, "\t\terror: swift.Error,\n");
	source = gb_string_appendc(source, "\t}\n\t_swift_capture := Capture{completion = completion}\n");
	if (receiver) {
		if (fn.is_mutating) source = gb_string_appendc(source, "\t_swift_capture.receiver = rawptr(receiver)\n");
		else source = gb_string_append_fmt(source, "\t_swift_capture.receiver = swift.value_copy(rawptr(receiver), _swift_%.*s_metadata(0).type) or_return\n\tdefer if !ok { swift.value_destroy(_swift_capture.receiver, _swift_%.*s_metadata(0).type) }\n", LIT(fn.owner->name), LIT(fn.owner->name));
	}
	for_array(i, fn.parameters) {
		auto const &param = fn.parameters[i];
		if (param.empty_set) continue;
		if (param.objc_controller) {
			source = gb_string_append_fmt(source, "\t_swift_capture.arg%td = %.*s\n\t_swift_ns.ObjectProtocol_retain(cast(^_swift_ns.ObjectProtocol)%.*s)\n\tdefer if !ok { _swift_ns.ObjectProtocol_release(cast(^_swift_ns.ObjectProtocol)%.*s) }\n", i, LIT(param.name), LIT(param.name), LIT(param.name));
		} else if (swift_import_projected(param.type)) {
			auto type = param.type.nominal;
			if (!type->alignment) source = gb_string_append_fmt(source, "\t_swift_capture.arg%td = swift.value_allocate(_swift_%.*s_metadata(0).type) or_return\n\tdefer if !ok { swift.value_free_uninitialized(_swift_capture.arg%td) }\n", i, LIT(type->name), i);
			source = gb_string_append_fmt(source, "\tif !_swift_%.*s_initialize(%s_swift_capture.arg%td, %.*s) { return }\n", LIT(type->name), type->alignment ? "&" : "", i, LIT(param.name));
			if (swift_import_native_owns(swift_import_nominal_type(type))) source = gb_string_append_fmt(source, "\tdefer if !ok { swift.value_deinitialize(%s_swift_capture.arg%td, _swift_%.*s_metadata(0).type) }\n", type->alignment ? "&" : "", i, LIT(type->name));
		} else if (swift_import_kind(param.type, SwiftImportValue_String)) {
			source = gb_string_append_fmt(source, "\t_swift_capture.arg%td = swift.string_from_odin(%.*s) or_return\n\tdefer if !ok { swift.string_destroy(&_swift_capture.arg%td) }\n", i, LIT(param.name), i);
		} else if (swift_import_kind(param.type, SwiftImportValue_Set)) {
			source = gb_string_append_fmt(source, "\t_swift_capture.arg%td = _swift_%.*s_from(%.*s) or_return\n\tdefer if !ok { swift.set_destroy(_swift_capture.arg%td) }\n", i, LIT(param.type.nominal->name), LIT(param.name), i);
		} else if (param.type.nominal) {
			if (swift_import_slice(param.type.nominal)) source = gb_string_append_fmt(source, "\t_swift_capture.arg%td = %.*s or_return\n", i, LIT(swift_import_array_from(param.type.nominal, param.name)));
			else source = gb_string_append_fmt(source, "\t_swift_capture.arg%td = swift.value_copy(rawptr(%.*s), _swift_%.*s_metadata(0).type) or_return\n", i, LIT(param.name), LIT(param.type.nominal->name));
			if (swift_import_slice(param.type.nominal)) source = gb_string_append_fmt(source, "\tdefer if !ok { swift.array_destroy(_swift_capture.arg%td) }\n", i);
			else source = gb_string_append_fmt(source, "\tdefer if !ok { swift.value_destroy(_swift_capture.arg%td, _swift_%.*s_metadata(0).type) }\n", i, LIT(param.type.nominal->name));
			if (fn.is_collection && swift_import_slice(param.type.nominal)) source = gb_string_append_fmt(source, "\t_swift_capture.collection_metadata = _swift_%.*s_metadata(0).type\n\t_swift_capture.collection_witness = swift.array_collection_witness(_swift_capture.collection_metadata)\n", LIT(param.type.nominal->name));
		} else source = gb_string_append_fmt(source, "\t_swift_capture.arg%td = %.*s\n", i, LIT(param.name));
	}
	if (allocated_result) source = gb_string_append_fmt(source, "\t_swift_capture.result = swift.value_allocate(_swift_%.*s_metadata(0).type) or_return\n\tdefer if !ok { swift.value_free_uninitialized(_swift_capture.result) }\n", LIT(fn.result.nominal->name));
	source = gb_string_appendc(source, "\tentry :: proc \"swift/async\" (#swift_async frame: rawptr, #swift_self _: rawptr) {\n");
	if (entry_needs_capture) source = gb_string_appendc(source, "\t\tcapture := cast(^Capture)runtime.swift_async_payload(frame)\n");
	source = gb_string_appendc(source, "\t\tchild := runtime.swift_async_prepare(frame, rawptr(resumed))\n");
	source = gb_string_append_fmt(source, "\t\t#must_tail _swift_%.*s_native(%scast(^runtime.Swift_Async_Frame)child%s%s)\n\t}\n", LIT(native_name), indirect_result ? (fixed_result ? "&capture.result, " : "capture.result, ") : "", gb_string_length(arguments) ? ", " : "", arguments);
	source = gb_string_appendc(source, "\tresumed :: proc \"swift/async\" (#swift_async child: ^runtime.Swift_Async_Frame");
	if (fn.result.odin && !indirect_result && !empty_result) source = gb_string_append_fmt(source, ", result: %s", swift_import_native_type(fn.result));
	if (fn.is_throwing) source = gb_string_appendc(source, ", #swift_self error: swift.Error");
	source = gb_string_appendc(source, ") {\n");
	if (fn.is_throwing || (fn.result.odin && !indirect_result && !empty_result)) {
		source = gb_string_appendc(source, "\t\tcapture := cast(^Capture)runtime.swift_async_payload(child.parent)\n");
		if (fn.is_throwing) source = gb_string_appendc(source, "\t\tcapture.error = error\n");
		if (fn.result.odin && !indirect_result && !empty_result) source = gb_string_append_fmt(source, "\t\t%s%s = result%s\n", fn.is_throwing ? "if error == nil { " : "", owned_result ? "(cast(^rawptr)capture.result)^" : "capture.result", fn.is_throwing ? " }" : "");
	}
	source = gb_string_appendc(source, "\t\t#must_tail runtime.swift_async_complete(child)\n\t}\n\tinvoke :: proc(pointer: rawptr) {\n\t\tcapture := cast(^Capture)pointer\n");
	if (receiver && !fn.is_mutating) source = gb_string_append_fmt(source, "\t\tswift.value_destroy(capture.receiver, _swift_%.*s_metadata(0).type)\n", LIT(fn.owner->name));
	for_array(i, fn.parameters) {
		auto const &param = fn.parameters[i];
		if (param.empty_set) continue;
		if (param.objc_controller) {
			source = gb_string_append_fmt(source, "\t\t_swift_ns.ObjectProtocol_release(cast(^_swift_ns.ObjectProtocol)capture.arg%td)\n", i);
		} else if (swift_import_projected(param.type)) {
			auto type = param.type.nominal;
			if (!param.consumed && swift_import_native_owns(param.type)) source = gb_string_append_fmt(source, "\t\tswift.value_deinitialize(%scapture.arg%td, _swift_%.*s_metadata(0).type)\n", type->alignment ? "&" : "", i, LIT(type->name));
			if (!type->alignment) source = gb_string_append_fmt(source, "\t\tswift.value_free_uninitialized(capture.arg%td)\n", i);
		} else if (param.consumed) {
			if (param.type.nominal && param.type.nominal->kind != SwiftImportValue_String && !swift_import_slice(param.type.nominal) && !swift_import_kind(param.type, SwiftImportValue_Set)) source = gb_string_append_fmt(source, "\t\tswift.value_free_uninitialized(capture.arg%td)\n", i);
		} else if (swift_import_kind(param.type, SwiftImportValue_String)) source = gb_string_append_fmt(source, "\t\tswift.string_destroy(&capture.arg%td)\n", i);
		else if (swift_import_kind(param.type, SwiftImportValue_Set)) source = gb_string_append_fmt(source, "\t\tswift.set_destroy(capture.arg%td)\n", i);
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
	if (string_result || slice_result) {
		source = gb_string_append_fmt(source, "\t\tresult: %s\n\t\tconverted := false\n", fn.result.odin);
		if (fn.is_throwing) source = gb_string_appendc(source, "\t\tif capture.error == nil {\n");
		// The native result owns its storage independently of the child frame
		// and inputs. Release it after conversion, including allocation failure.
		if (string_result) source = gb_string_appendc(source, "\t\tresult, converted = swift.string_to_odin(capture.result)\n\t\tswift.string_destroy(&capture.result)\n");
		else source = gb_string_append_fmt(source, "\t\tresult, converted = %.*s\n\t\tswift.array_destroy(swift.Native_Array{capture.result})\n", LIT(swift_import_array_to(fn.result.nominal, str_lit("swift.Native_Array{capture.result}"))));
		if (fn.is_throwing) source = gb_string_appendc(source, "\t\t}\n");
	}
	if (fn.is_throwing) {
		source = gb_string_appendc(source, "\t\terror := _swift_async_error_take(capture.error)\n");
		if (converted_result) source = gb_string_appendc(source, "\t\tif error == nil && !converted { error = swift.Result_Conversion_Failed{} }\n");
	}
	source = gb_string_appendc(source, "\t\tcapture.completion(swift.Task(runtime.swift_async_current())");
	if (string_result || slice_result || projected_result) source = gb_string_appendc(source, ", result");
	else if (fn.result.odin) source = gb_string_append_fmt(source, ", %s(capture.result)", fn.result.odin);
	if (fn.is_throwing) source = gb_string_appendc(source, ", error");
	if (converted_result && !fn.is_throwing) source = gb_string_appendc(source, ", converted");
	source = gb_string_append_fmt(source, ")\n\t}\n\ttask = swift.Task(runtime.swift_async_start(rawptr(entry), &_swift_%.*s_descriptor, &_swift_capture, size_of(Capture), invoke, rawptr(completion)))\n\tok = task != nil\n\treturn\n}\n\n", LIT(native_name));
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
	Array<String> rows = {};
	Array<String> *report = nullptr;
	if (build_context.show_swift_imports) {
		array_init(&rows, temporary_allocator());
		report = &rows;
	}
	// These names are useful for diagnostics but do not participate in overload selection.
	auto lookup_rejections = array_make<SwiftImportRejection>(temporary_allocator());
	for (JsonValue *symbol : swift_import_array(graph, "symbols")) {
		String kind = swift_import_string(swift_import_member(symbol, "kind"), "identifier");
		if (kind != "swift.struct" && kind != "swift.enum") continue;
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
		bool copyable = false, escapable = false, error_type = false;
		for (JsonValue *conformance : swift_import_array(declaration, "conformances")) {
			copyable |= swift_import_string(conformance, "usr") == "s:s8CopyableP";
			escapable |= swift_import_string(conformance, "usr") == "s:s9EscapableP";
			error_type |= swift_import_string(conformance, "usr") == "s:s5ErrorP";
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
		String reason = swift_import_availability_rejection(symbol);
		if (reason.len) {
			array_add(&lookup_rejections, (SwiftImportRejection{make_string_c(name), reason}));
			continue;
		}
		auto type = gb_alloc_item(permanent_allocator(), SwiftImportNominal);
		*type = {};
		type->name = make_string_c(name);
		type->swift_name = make_string_c(swift_name);
		type->usr = usr;
		type->symbol = swift_import_string(declaration, "mangledName");
		type->declaration = declaration;
		type->is_enum = kind == "swift.enum";
		type->is_error = type->is_enum && error_type;
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
	isize unavailable_type_count = lookup_rejections.count;
	array_init(&pkg->unsupported, permanent_allocator());
	StringSet published_raw_values = {};
	string_set_init(&published_raw_values, 16);
	defer (string_set_destroy(&published_raw_values));
	for (auto symbol : swift_import_array(graph, "symbols")) {
		if (swift_import_string(swift_import_member(symbol, "kind"), "identifier") == "swift.property" &&
		    swift_import_string(swift_import_member(symbol, "names"), "title") == "rawValue") {
			string_set_update(&published_raw_values, swift_import_string(swift_import_member(symbol, "identifier"), "precise"));
		}
	}
	for (JsonValue *symbol : swift_import_array(graph, "symbols")) {
		String kind = swift_import_string(swift_import_member(symbol, "kind"), "identifier");
		auto components = swift_import_array(symbol, "pathComponents");
		bool method = kind == "swift.method" || kind == "swift.type.method";
		bool property = kind == "swift.property" || kind == "swift.type.property";
		bool initializer = kind == "swift.init";
		bool implicit_raw = kind == "swift.enum";
		if (!(kind == "swift.func" && components.count == 1) && !method && !property && !initializer && !implicit_raw) continue;
		String usr = swift_import_string(swift_import_member(symbol, "identifier"), "precise");
		JsonValue *declaration = swift_import_find_api(api, usr);
		if (implicit_raw) {
			declaration = swift_import_implicit_raw_value(declaration, &published_raw_values);
			property = true;
		}
		if (!declaration) continue;
		String name = swift_import_name(swift_import_string(declaration, "name"));
		SwiftImportFunction fn = {};
		fn.is_static = kind == "swift.type.method" || kind == "swift.type.property";
		fn.is_property = property;
		fn.is_initializer = initializer;
		fn.title = implicit_raw ? str_lit("rawValue") : swift_import_string(swift_import_member(symbol, "names"), "title");
		fn.rejection = swift_import_availability_rejection(symbol, &fn);
		isize owner_count = implicit_raw ? components.count : components.count-1;
		if (owner_count > 0) {
			gbString owner_name = gb_string_make(permanent_allocator(), "");
			for (isize i = 0; i < owner_count; i++) {
				if (components[i]->kind != Json_String) continue;
				owner_name = gb_string_append_fmt(owner_name, "%s%.*s", i ? "_" : "", LIT(components[i]->string));
			}
			for (auto type : types) if (type->name == make_string_c(owner_name)) fn.owner = type;
			if (!fn.owner && !fn.rejection.len) {
				fn.rejection = str_lit("unsupported Swift receiver type");
				for (isize i = 0; i < unavailable_type_count; i++) {
					if (lookup_rejections[i].name == make_string_c(owner_name)) {
						fn.rejection = lookup_rejections[i].reason;
						break;
					}
				}
			}
			name = concatenate3_strings(permanent_allocator(), make_string_c(owner_name), str_lit("_"), name);
		}
		if (!fn.rejection.len && fn.owner && fn.owner->is_template) fn.rejection = str_lit("unsupported generic Swift receiver");
		bool supported = (!owner_count || fn.owner) && !fn.rejection.len && swift_import_function(implicit_raw ? nullptr : symbol, declaration, &fn, &types);
		if (implicit_raw) {
			auto result = swift_import_array(declaration, "children");
			String spelling = result.count == 1 ? swift_import_string(result[0], "printedName") : str_lit("RawValue");
			fn.signature = concatenate3_strings(permanent_allocator(), str_lit("var rawValue: "), spelling, str_lit(" { get }"));
		}
		if (report && !fn.signature.len) {
			gbString signature = gb_string_make(temporary_allocator(), "");
			for (auto fragment : swift_import_array(symbol, "declarationFragments")) {
				String part = swift_import_string(fragment, "spelling");
				signature = gb_string_append_length(signature, part.text, part.len);
			}
			fn.signature = make_string_c(signature);
		}
		fn.base_name = name;
		// Keep argument labels in distinct binding names, like Objective-C
		// selectors. A unique supported declaration also gets the short name.
		String title = fn.title;
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
				if (swift_import_string(accessor, "accessorKind") != "get") continue;
				if (!swift_import_member(accessor, "declAttributes")) {
					fn.symbol = swift_import_string(accessor, "mangledName");
					fn.rejection = {};
					supported = true;
					break;
				}
				auto attributes = swift_import_array(accessor, "declAttributes");
				if (attributes.count && attributes[0]->kind == Json_String) {
					fn.rejection = concatenate3_strings(permanent_allocator(), str_lit("unsupported Swift getter attribute '"), attributes[0]->string, str_lit("'"));
				}
			}
			if (!supported && !fn.rejection.len) fn.rejection = str_lit("no supported Swift getter");
		}
		fn.odin_name = name;
		if (!supported) {
			swift_import_reject_function(pkg, &lookup_rejections, fn, report);
			continue;
		}
		SwiftImportFunction const *collision = nullptr;
		for (auto const &previous : functions) if (previous.odin_name == name) { collision = &previous; break; }
		if (collision) {
			String reason = make_string_c(gb_string_append_fmt(gb_string_make(permanent_allocator(), ""),
				"ambiguous Swift binding for '%.*s' and '%.*s'", LIT(collision->signature), LIT(fn.signature)));
			swift_import_reject(pkg, name, reason);
		} else array_add(&functions, fn);
	}
	// A skipped sibling with the same Swift title cannot claim the Odin name.
	// Preserve real collisions, including names that coincide after normalization.
	for (isize i = functions.count; i-- > 0;) {
		for (auto const &rejection : pkg->unsupported) {
			if (functions[i].odin_name == rejection.name && functions[i].title != rejection.title) {
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
			bool available = false;
			String case_rejection = {};
			for (JsonValue *symbol : swift_import_array(graph, "symbols")) {
				if (swift_import_string(swift_import_member(symbol, "identifier"), "precise") == usr) {
					case_rejection = swift_import_availability_rejection(symbol);
					available = !case_rejection.len;
					String title = swift_import_string(swift_import_member(symbol, "names"), "title");
					isize open = string_index_byte(title, '(');
					if (open >= 0 && string_ends_with(title, str_lit(")"))) labels = substring(title, open+1, title.len-1);
					for (auto fragment : swift_import_array(symbol, "declarationFragments")) {
						if (swift_import_string(fragment, "spelling") == "indirect") c.available = false;
					}
					break;
				}
			}
			// Resilient enums preserve other tags in their owned Unknown variant.
			// Do not reference a case symbol unavailable on the deployment target.
			if (!available && !type->is_frozen) {
				if (case_rejection.len && swift_import_identifier(c.name)) {
					array_add(&lookup_rejections, (SwiftImportRejection{swift_import_case_name(type, c), case_rejection}));
				}
				continue;
			}
			c.available &= available;
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
							if (field.type.scalar_only) field.type = {};
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

	for_array(i, types) swift_import_struct_fields(types[i], graph, &types);
	if (!swift_import_check_type_names(node, types)) return false;

	bool inspect_set_storage = false;
	for (auto type : types) if (type->kind == SwiftImportValue_Set && type->argument->is_scalar) inspect_set_storage = true;
	gbString probe = gb_string_make(permanent_allocator(), "");
	probe = gb_string_append_fmt(probe, "import %.*s\n", LIT(pkg->module));
	bool probe_ui = false;
	for (auto const &fn : functions) for (auto const &param : fn.parameters) probe_ui |= param.objc_controller;
	if (probe_ui) probe = gb_string_appendc(probe, "import UIKit\n");
	for (auto type : types) if (type->is_date || type->is_uuid) { probe = gb_string_appendc(probe, "import Foundation\n"); break; }
	for_array(i, types) {
		if (types[i]->is_template) continue;
		if (types[i]->is_date) probe = swift_import_date_probe(probe, types[i], i);
		if (types[i]->is_uuid) probe = swift_import_uuid_probe(probe, types[i], i);
		if (types[i]->kind == SwiftImportValue_Set) probe = swift_import_set_probe(probe, types[i], i);
		probe = gb_string_append_fmt(probe, "@_silgen_name(\"odin_swift_import_metadata_%td\")\npublic func metadata_%td() -> Any.Type { %.*s.self }\n", i, i, LIT(types[i]->swift_name));
		if ((types[i]->is_enum && types[i]->cases.count) || types[i]->is_record) {
			probe = gb_string_append_fmt(probe,
				"@_silgen_name(\"odin_swift_import_load_%td\")\npublic func load_%td(_ value: Swift.UnsafePointer<%.*s>) -> %.*s { value.pointee }\n"
				"@_silgen_name(\"odin_swift_import_layout_%td\")\npublic func layout_%td() -> (Swift.Int, Swift.Int) { (Swift.MemoryLayout<%.*s>.size, Swift.MemoryLayout<%.*s>.alignment) }\n",
				i, i, LIT(types[i]->swift_name), LIT(types[i]->swift_name), i, i, LIT(types[i]->swift_name), LIT(types[i]->swift_name));
		}
		if (types[i]->is_record) probe = swift_import_struct_probe(probe, types[i], i);
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
	// Inspect ABI-public standard-library storage only; imported declarations
	// still come from the public symbol graph. This probe is never linked.
	if (inspect_set_storage) { array_add(&args, str_lit("-Xfrontend")); array_add(&args, str_lit("-disable-access-control")); }
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
	if (inspect_set_storage) { array_add(&args, str_lit("-Xfrontend")); array_add(&args, str_lit("-disable-access-control")); }
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
			                  (pkg->framework || type->is_date || type->is_uuid || swift_import_has_line(exports, exported, false));
		}
		if (!type->argument && type->is_frozen) {
			String symbol = concatenate_strings(permanent_allocator(), type->symbol, str_lit("N"));
			LLVMValueRef metadata = LLVMGetNamedGlobal(inspection, alloc_cstring(permanent_allocator(), symbol));
			if (metadata && (pkg->framework || swift_import_has_line(exports, concatenate_strings(permanent_allocator(), str_lit(" _"), symbol), false))) {
				type->static_metadata = true;
				type->supported = true;
			}
		}
		if (type->is_date) type->supported &= swift_import_date_layout(inspection, sil, type, i);
		if (type->is_uuid) type->supported &= swift_import_uuid_layout(inspection, sil, type, i);
		if (type->kind == SwiftImportValue_Set) type->supported &= swift_import_set_layout(inspection, layout, sil, type, i);
		if (type->is_enum) type->supported &= swift_import_enum_layout(inspection, layout, type, i);
		if (type->is_record) swift_import_struct_layout(inspection, layout, type, i);
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
		LLVMValueRef native = LLVMGetNamedFunction(inspection, alloc_cstring(permanent_allocator(), fn.symbol));
		// A nonmutating member of a projected value can receive self in the
		// ordinary argument registers. Check the actual declaration below.
		if (receiver && fn.owner->supported && fn.owner->projected && !fn.is_mutating) {
			SwiftImportParameter self = {};
			self.name = str_lit("receiver");
			self.type = swift_import_nominal_type(fn.owner);
			// Indirect self may occupy Swift's dedicated context register.
			// The signature verifier also checks the full parameter list.
			if (swift_import_indirect(self.type) && native && LLVMCountParams(native)) {
				unsigned attr = LLVMGetEnumAttributeKindForName("swiftself", 9);
				self.self_register = LLVMGetEnumAttributeAtIndex(native, LLVMCountParams(native), attr) != nullptr;
			}
			array_add(&fn.parameters, self);
			fn.value_receiver = true;
			receiver = false;
		}
		bool indirect_result = swift_import_indirect(fn.result);
		bool record_parameters = false;
		unsigned native_index = 0;
		String &reason = fn.rejection;
		auto api_types = swift_import_array(fn.api, "children");
		if (receiver && fn.owner->projected && fn.is_mutating) {
			// Borrow storage directly only when every bit pattern of each Odin
			// field is a valid Swift value. Bool and owned fields need conversion.
			fn.record_inout = fn.owner->is_record && fn.owner->size != 0 && !fn.owner->owns;
			for (auto const &field : fn.owner->fields) {
				if (make_string_c(field.type.odin) == "bool") fn.record_inout = false;
			}
			if (!fn.record_inout) reason = str_lit("mutating a projected Swift receiver requires write-back to the Odin value");
		} else if (fn.owner && !fn.is_static && !fn.owner->supported) {
			reason = str_lit("unsupported Swift receiver representation");
		}
		if (!reason.len && fn.result.nominal && !fn.result.nominal->supported) {
			reason = swift_import_type_rejection(api_types.count ? api_types[0] : nullptr);
		}
		for_array(i, fn.parameters) {
			auto const &param = fn.parameters[i];
			if (!reason.len && param.type.nominal && !param.type.nominal->supported) {
				reason = swift_import_type_rejection(i+1 < api_types.count ? api_types[i+1] : nullptr, param.name);
			}
		}
		if (!reason.len && !swift_import_ownership(sil, &fn)) reason = str_lit("Swift parameter or result ownership could not be verified");
		if (reason.len) {
			swift_import_reject_function(pkg, &lookup_rejections, fn, report);
			array_ordered_remove(&functions, index);
			continue;
		}
		gbString declaration = gb_string_make(permanent_allocator(), "");
		declaration = gb_string_append_fmt(declaration, "declare %s %s @\"%.*s\"(", fn.is_async ? "swifttailcc" : "swiftcc",
			fn.is_async || indirect_result || swift_import_empty(fn.result) || !fn.result.llvm ? "void" : swift_import_projected(fn.result) ? alloc_cstring(permanent_allocator(), swift_import_enum_llvm(fn.result.nominal, true)) : fn.result.llvm, LIT(fn.symbol));
		isize count = 0;
		if (indirect_result) {
			if (fn.result.nominal->projected && fn.result.nominal->alignment) {
				record_parameters = true;
				if (!reason.len && !swift_import_struct_parameter(native, native_index, fn.result.nominal, true)) reason = str_lit("unsupported indirect Swift result layout");
				if (fn.is_async) declaration = gb_string_appendc(declaration, "ptr noalias");
				else declaration = gb_string_append_fmt(declaration, "ptr noalias sret(%%%.*s)", LIT(fn.result.nominal->indirect_llvm));
			} else declaration = gb_string_appendc(declaration, fn.is_async ? "ptr noalias" : "ptr noalias sret(%swift.opaque)");
			count++;
			native_index++;
		}
		if (fn.is_async) {
			declaration = gb_string_append_fmt(declaration, "%sptr swiftasync", count++ ? ", " : "");
			native_index++;
		}
		for (auto const &param : fn.parameters) {
			if (swift_import_empty(param.type)) continue;
			char const *llvm = swift_import_kind(param.type, SwiftImportValue_String) ? "i64, ptr" : swift_import_projected(param.type) ? alloc_cstring(permanent_allocator(), swift_import_enum_llvm(param.type.nominal, false)) : param.type.llvm;
			if (fn.is_collection && swift_import_string_array(param.type)) llvm = "ptr noalias";
			if (swift_import_indirect(param.type) && param.type.nominal->projected && param.type.nominal->alignment) {
				record_parameters = true;
				if (!reason.len && !swift_import_struct_parameter(native, native_index, param.type.nominal, false)) {
					reason = concatenate3_strings(permanent_allocator(), str_lit("unsupported indirect layout for parameter '"), param.name, str_lit("'"));
				}
				llvm = "ptr noalias";
			}
			declaration = gb_string_append_fmt(declaration, "%s%s%s", count++ ? ", " : "", llvm, param.self_register ? " swiftself" : "");
			if (fn.is_collection && swift_import_string_array(param.type)) native_index++;
			else if (swift_import_kind(param.type, SwiftImportValue_String) || param.borrow == SwiftImportBorrow_Buffer || param.borrow == SwiftImportBorrow_MutableBuffer) native_index += 2;
			else if (swift_import_projected(param.type) && !swift_import_indirect(param.type)) native_index += cast(unsigned)param.type.nominal->components.count;
			else native_index++;
		}
		if (fn.is_collection) declaration = gb_string_append_fmt(declaration, "%sptr, ptr", count++ ? ", " : "");
		if (fn.record_inout) {
			record_parameters = true;
			if (!reason.len && !swift_import_struct_parameter(native, native_index, fn.owner, false)) reason = str_lit("unsupported mutable Swift record receiver layout");
		}
		if (receiver) declaration = gb_string_append_fmt(declaration, "%s%s", count ? ", " : "", fn.is_mutating ? "ptr swiftself" : "ptr noalias swiftself");
		declaration = gb_string_appendc(declaration, ")");
		String exported = concatenate_strings(permanent_allocator(), str_lit(" _"), fn.symbol);
		char *native_declaration = record_parameters && native ? LLVMPrintValueToString(native) : nullptr;
		defer (if (native_declaration) LLVMDisposeMessage(native_declaration));
		String inspected = native_declaration ? make_string_c(native_declaration) : ir;
		if (!reason.len && !swift_import_has_line(inspected, make_string_c(declaration), true)) reason = str_lit("unsupported native Swift calling sequence");
		if (!reason.len && !pkg->framework) {
			if (!swift_import_has_line(exports, exported, false)) reason = str_lit("Swift library does not export the function symbol");
			else if (fn.is_async && !swift_import_has_line(exports, concatenate_strings(permanent_allocator(), exported, str_lit("Tu")), false)) reason = str_lit("Swift library does not export the async descriptor");
		}
		if (reason.len) {
			swift_import_reject_function(pkg, &lookup_rejections, fn, report);
			array_ordered_remove(&functions, index);
		}
	}

	// Validate the whole emitted namespace, including ownership helpers. Never
	// let an unsupported Swift member silently resolve to one of our helpers.
	bool has_throwing = false;
	for (auto const &fn : functions) has_throwing |= fn.is_throwing;
	auto names = array_make<String>(permanent_allocator());
	if (has_throwing) {
		char const *error_names[] = {"Async_Error", "Async_Error_copy", "Async_Error_destroy"};
		for (char const *name : error_names) array_add(&names, make_string_c(name));
		// Unsupported nominal declarations must not silently become our helpers.
		for (JsonValue *symbol : swift_import_array(graph, "symbols")) {
			String kind = swift_import_string(swift_import_member(symbol, "kind"), "identifier");
			if (kind != "swift.struct" && kind != "swift.enum" && kind != "swift.class" &&
			    kind != "swift.protocol" && kind != "swift.typealias") continue;
			gbString name = gb_string_make(permanent_allocator(), "");
			for (JsonValue *part : swift_import_array(symbol, "pathComponents")) {
				if (part->kind != Json_String) continue;
				name = gb_string_append_fmt(name, "%s%.*s", gb_string_length(name) ? "_" : "", LIT(part->string));
			}
			for (String reserved : names) {
				if (make_string_c(name) == reserved) {
					syntax_error(node, "Swift import: declaration '%.*s' conflicts with generated async error declarations", LIT(reserved));
					return false;
				}
			}
		}
	}
	for (auto type : types) {
		if (!type->supported || type->is_scalar || type->kind == SwiftImportValue_Set || type->kind == SwiftImportValue_String || (swift_import_slice(type) && !swift_import_value_slice(type))) continue;
		if (!swift_import_add_name(node, &names, type->name)) return false;
		if (type->is_date || type->is_uuid) continue;
		if (type->is_error && type->projected && !swift_import_add_name(node, &names, concatenate_strings(permanent_allocator(), type->name, str_lit("_from_error")))) return false;
		if (type->is_record) {
			auto members = array_make<String>(permanent_allocator());
			for (auto const &field : type->fields) if (!swift_import_add_name(node, &members, field.name)) return false;
			if (type->owns) {
				if (!swift_import_add_name(node, &names, concatenate_strings(permanent_allocator(), type->name, str_lit("_copy")))) return false;
				if (!swift_import_add_name(node, &names, concatenate_strings(permanent_allocator(), type->name, str_lit("_destroy")))) return false;
			}
			continue;
		}
		if (swift_import_plain_enum(type)) {
			auto members = array_make<String>(permanent_allocator());
			for (auto const &c : type->cases) {
				if (!swift_import_add_name(node, &members, swift_import_case_member(c))) return false;
			}
			continue;
		}
		if (type->projected || swift_import_value_slice(type)) {
			char const *ownership_suffixes[] = {"_copy", "_destroy"};
			for (char const *suffix : ownership_suffixes) {
				if (!swift_import_add_name(node, &names, concatenate_strings(permanent_allocator(), type->name, make_string_c(suffix)))) return false;
			}
			if (type->projected && !type->is_optional) {
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
	for (auto const &rejection : pkg->unsupported) {
		String name = rejection.name;
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
	bool has_values = false, has_scalar_async = false, has_value_async = false, has_set = false, has_ui = false;
	for (auto type : types) {
		has_values |= type->supported;
		has_set |= type->supported && type->kind == SwiftImportValue_Set;
	}
	for (auto const &fn : functions) {
		bool values = fn.owner || fn.result.nominal || fn.is_throwing;
		for (auto const &param : fn.parameters) {
			values |= param.type.nominal != nullptr || param.objc_controller;
			has_ui |= param.objc_controller;
		}
		has_values |= values;
		has_scalar_async |= fn.is_async && !values;
		has_value_async |= fn.is_async && values;
	}
	source = gb_string_append_fmt(source, "package swift_%.*s_%llx\n\n",
		LIT(pkg->module), cast(unsigned long long)fnv64a(identity.text, identity.len));
	if (has_ui) source = gb_string_appendc(source, "import _swift_ui \"vendor:darwin/UIKit\"\nimport _swift_ns \"core:sys/darwin/Foundation\"\n");
	if (has_scalar_async) source = gb_string_appendc(source, "import \"base:intrinsics\"\n");
	if (has_value_async || has_set) source = gb_string_appendc(source, "import \"base:runtime\"\n");
	for (auto type : types) if (type->supported && type->is_uuid) { source = gb_string_appendc(source, "import _swift_uuid \"core:encoding/uuid\"\n"); break; }
	if (has_values) source = gb_string_appendc(source, "@(require)\nimport \"core:mem\"\n@(require)\nimport \"core:strings\"\n");
	if (has_values || has_scalar_async || has_value_async) source = gb_string_appendc(source, "import swift \"core:sys/darwin/Swift\"\n");
	source = gb_string_appendc(source, "\n");
	String quoted_flags = quote_to_ascii(permanent_allocator(), make_string_c(flags));
	String quoted_library = quote_to_ascii(permanent_allocator(), pkg->framework ? pkg->library : swift_import_relative(pkg->directory, pkg->library));
	source = gb_string_append_fmt(source,
		"@(require, extra_linker_flags=%.*s)\n"
		"foreign import swift_library {\n\t%.*s,\n\t\"system:swiftCore\",\n\t\"system:swift_Concurrency\",\n}\n\n",
		LIT(quoted_flags), LIT(quoted_library));
	source = swift_import_emit_enum_tags(source, types);
	for (auto type : types) {
		if (type->supported) {
			source = swift_import_emit_type(source, type);
			if (report && !type->is_scalar && !type->is_template) swift_import_report_type(report, type);
			if (type->is_error && type->projected) source = swift_import_emit_error(source, type);
		}
	}
	if (has_throwing) source = swift_import_emit_async_error(source, types);
	for (auto const &fn : functions) {
		bool values = fn.owner || fn.result.nominal || fn.is_throwing;
		for (auto const &param : fn.parameters) values |= param.type.nominal != nullptr || param.objc_controller;
		if (values) {
			source = swift_import_emit_value_declaration(source, fn);
			bool defaults = false;
			for (auto const &param : fn.parameters) defaults |= param.empty_set;
			if (defaults) {
				SwiftImportFunction explicit_fn = fn;
				explicit_fn.odin_name = concatenate3_strings(permanent_allocator(), str_lit("_swift_"), fn.odin_name, str_lit("_explicit"));
				explicit_fn.parameters = array_make<SwiftImportParameter>(permanent_allocator());
				for (auto param : fn.parameters) { param.empty_set = false; array_add(&explicit_fn.parameters, param); }
				SwiftImportFunction default_fn = fn;
				default_fn.odin_name = concatenate3_strings(permanent_allocator(), str_lit("_swift_"), fn.odin_name, str_lit("_default"));
				source = swift_import_emit_value_function(source, explicit_fn, fn.odin_name, report);
				source = swift_import_emit_value_function(source, default_fn, fn.odin_name, report);
				source = gb_string_append_fmt(source, "%.*s :: proc{ %.*s, %.*s }\n\n", LIT(fn.odin_name), LIT(explicit_fn.odin_name), LIT(default_fn.odin_name));
			} else source = swift_import_emit_value_function(source, fn, fn.odin_name, report);
			continue;
		}
		gbString params = gb_string_make(permanent_allocator(), "");
		for_array(i, fn.parameters) params = gb_string_append_fmt(params, "%s%.*s: %s", i ? ", " : "", LIT(fn.parameters[i].name), fn.parameters[i].type.odin);
		if (!fn.is_async) {
			source = gb_string_append_fmt(source, "foreign swift_library {\n\t@(link_name=\"%.*s\")\n\t%.*s :: proc \"swift\" ", LIT(fn.symbol), LIT(fn.odin_name));
			isize signature_start = gb_string_length(source);
			source = gb_string_append_fmt(source, "(%s)", params);
			if (fn.result.odin) source = gb_string_append_fmt(source, " -> %s", fn.result.odin);
			swift_import_report_function(report, fn, fn.odin_name, source, signature_start);
			source = gb_string_appendc(source, " ---\n}\n\n");
			continue;
		}
		source = gb_string_append_fmt(source, "@(require_results)\n%.*s :: proc", LIT(fn.odin_name));
		isize signature_start = gb_string_length(source);
		source = gb_string_append_fmt(source, "(%s%scompletion: proc(swift.Task", params, gb_string_length(params) ? ", " : "");
		if (fn.result.odin) source = gb_string_append_fmt(source, ", %s", fn.result.odin);
		source = gb_string_appendc(source, ")) -> (task: swift.Task, ok: bool) #optional_ok");
		swift_import_report_function(report, fn, fn.odin_name, source, signature_start);
		source = gb_string_appendc(source, " {\n");
		source = gb_string_append_fmt(source, "\ttask = swift.Task(intrinsics.swift_async_call(\"%.*s\", completion", LIT(fn.symbol));
		for (auto const &param : fn.parameters) source = gb_string_append_fmt(source, ", %.*s", LIT(param.name));
		source = gb_string_appendc(source, "))\n\treturn task, task != nil\n}\n\n");
	}
	for (auto const &fn : functions) {
		if (fn.base_name == fn.odin_name) continue;
		isize count = 0;
		SwiftImportFunction const *default_fn = nullptr;
		isize default_count = 0;
		for (auto const &other : functions) {
			if (other.base_name != fn.base_name && other.odin_name != fn.base_name) continue;
			count++;
			// The only supported default is the trailing empty Set. Preserve
			// the zero-argument short call when a labeled overload is added.
			if (other.parameters.count == 1+other.value_receiver && other.parameters[0].empty_set) {
				default_fn = &other;
				default_count++;
			}
		}
		if (count > 1 && default_count == 1) {
			if (default_fn != &fn) continue;
			count = 1;
		}
		for (auto name : names) if (name == fn.base_name) count++;
		for (auto const &rejection : pkg->unsupported) if (rejection.name == fn.base_name) count++;
		if (count == 1) {
			if (report) array_add(report, make_string_c(gb_string_append_fmt(gb_string_make(temporary_allocator(), ""),
				"alias %.*s = %.*s\n", LIT(fn.base_name), LIT(fn.odin_name))));
			source = gb_string_append_fmt(source, "%.*s :: %.*s\n", LIT(fn.base_name), LIT(fn.odin_name));
		} else {
			swift_import_reject(pkg, fn.base_name, str_lit("ambiguous Swift overload or binding name; use its argument-label binding"));
		}
	}
	for (auto const &rejection : lookup_rejections) swift_import_reject(pkg, rejection.name, rejection.reason, rejection.title);
	if (!swift_import_write(node, swift_import_path(pkg->directory, "import.odin"), source)) return false;
	if (report) {
		for (auto const &rejection : pkg->unsupported) {
			gbString row = gb_string_append_fmt(gb_string_make(temporary_allocator(), ""), "lookup fallback %.*s", LIT(rejection.name));
			if (rejection.title.len) row = gb_string_append_fmt(row, " (%.*s)", LIT(rejection.title));
			array_add(report, make_string_c(gb_string_append_fmt(row, ": %.*s\n", LIT(rejection.reason))));
		}
		array_sort(rows, swift_import_report_compare);
		gb_printf("Swift imports: %.*s (%.*s)\n", LIT(pkg->module), LIT(build_context.metrics.target_triplet));
		for (String row : rows) gb_printf("%.*s", LIT(row));
	}
	return true;
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

gb_internal String swift_import_unsupported(String path, String name) {
#if defined(GB_SYSTEM_OSX)
	mutex_lock(&swift_import_mutex);
	defer (mutex_unlock(&swift_import_mutex));
	for (auto const &pkg : swift_import_packages) {
		if (pkg.directory != path) continue;
		for (auto const &rejection : pkg.unsupported) if (rejection.name == name) return rejection.reason;
	}
#endif
	return {};
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
