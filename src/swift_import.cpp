// Swift modules are inspected at build time. Only the original library is
// linked; the inspection source and its IR never become application code.

#if defined(GB_SYSTEM_OSX)
#include <spawn.h>
#include <sys/wait.h>
#include <removefile.h>

extern char **environ;

struct SwiftImportPackage {
	String module, path, library;
	String directory;
	Array<String> unsupported;
	bool framework;
};

struct SwiftImportScalar {
	char const *swift;
	char const *odin;
	char const *llvm;
};

struct SwiftImportParameter {
	String name, label;
	SwiftImportScalar type;
};

struct SwiftImportFunction {
	String name, title, symbol, odin_name;
	String receiver;
	Array<SwiftImportParameter> parameters;
	SwiftImportScalar result;
	bool is_async;
};

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

gb_internal String swift_import_name(String name) {
	gbString result = gb_string_make(permanent_allocator(), "");
	for (isize i = 0; i < name.len; i++) {
		if (i > 0 && (name[i] >= 'A' && name[i] <= 'Z') && ((name[i-1] >= 'a' && name[i-1] <= 'z') || gb_char_is_digit(name[i-1]))) {
			result = gb_string_appendc(result, "_");
		}
		char c = gb_char_to_lower(name[i]);
		result = gb_string_append_length(result, &c, 1);
	}
	String s = make_string_c(result);
	bool reserved = s == "_" || s == "context" || s == "nil" || s == "true" || s == "false" ||
	                s == "user_data" || s == "completion" || s == "intrinsics" || s == "swift_library" ||
	                s == "swift" || s == "receiver" || s == "id" || s == "ok" || s == "main";
	for (isize i = Token__KeywordBegin+1; i < Token__KeywordEnd; i++) {
		reserved |= s == token_strings[i];
	}
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

gb_internal bool swift_import_write(Ast *node, String path, gbString text) {
	gbFile file = {};
	if (gb_file_create(&file, alloc_cstring(permanent_allocator(), path)) != gbFileError_None) {
		syntax_error(node, "Swift import: could not create '%.*s'", LIT(path));
		return false;
	}
	bool ok = gb_file_write(&file, text, gb_string_length(text));
	gb_file_close(&file);
	if (!ok) syntax_error(node, "Swift import: could not write '%.*s'", LIT(path));
	return ok;
}

// Use an argument vector, not a shell command. SDK/module/library paths may
// contain spaces or shell metacharacters. Parsing workers may run concurrently.
gb_internal bool swift_import_exec(Ast *node, String directory, Array<String> const &args, String *output) {
	auto argv = array_make<char *>(permanent_allocator());
	array_add(&argv, cast(char *)"/usr/bin/xcrun");
	for (String arg : args) array_add(&argv, alloc_cstring(permanent_allocator(), arg));
	array_add(&argv, cast(char *)nullptr);
	String out_path = swift_import_path(directory, "command.out");
	String err_path = swift_import_path(directory, "command.err");
	posix_spawn_file_actions_t actions;
	int status = posix_spawn_file_actions_init(&actions);
	if (status != 0) {
		syntax_error(node, "Swift import: cannot initialize tool process: %s", strerror(status));
		return false;
	}
	defer (posix_spawn_file_actions_destroy(&actions));
	status = posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, alloc_cstring(permanent_allocator(), out_path), O_CREAT|O_WRONLY|O_TRUNC, 0600);
	if (status == 0) status = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, alloc_cstring(permanent_allocator(), err_path), O_CREAT|O_WRONLY|O_TRUNC, 0600);
	pid_t pid = 0;
	if (status == 0) status = posix_spawn(&pid, argv[0], &actions, nullptr, argv.data, environ);
	if (status != 0) {
		syntax_error(node, "Swift import: cannot run Xcode tool: %s", strerror(status));
		return false;
	}
	int wait_status = 0;
	while (waitpid(pid, &wait_status, 0) < 0) {
		if (errno == EINTR) continue;
		syntax_error(node, "Swift import: cannot wait for Xcode tool: %s", strerror(errno));
		return false;
	}
	if (!WIFEXITED(wait_status) || WEXITSTATUS(wait_status) != 0) {
		String message = swift_import_read(err_path);
		message.len = gb_min(message.len, 4096);
		syntax_error(node, "Swift import: %.*s failed\n%.*s", LIT(args[0]), LIT(message));
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

gb_internal bool swift_import_type(Slice<JsonValue *> fragments, bool result, SwiftImportScalar *type) {
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
	if (result && (text.len == 0 || text == "()" || text == "Void")) return true;
	if (count != 1) return false;
	if (usr == "s:s6UInt64V") *type = {"UInt64", "u64", "i64"};
	else if (usr == "s:s5Int64V") *type = {"Int64", "i64", "i64"};
	else if (usr == "s:Sd") *type = {"Double", "f64", "double"};
	else return false;
	for (isize i = 0; i < text.len; i++) {
		if (text[i] == ':') {
			text = substring(text, i+1, text.len);
			break;
		}
	}
	text = string_trim_whitespace(text);
	return text == make_string_c(type->swift) || text == concatenate_strings(permanent_allocator(), str_lit("Swift."), make_string_c(type->swift));
}

gb_internal bool swift_import_function(JsonValue *symbol, JsonValue *api, SwiftImportFunction *fn) {
	fn->name = swift_import_string(api, "name");
	fn->title = swift_import_string(swift_import_member(symbol, "names"), "title");
	fn->symbol = swift_import_string(api, "mangledName");
	if (!swift_import_identifier(fn->name) || !string_starts_with(fn->symbol, str_lit("$s")) ||
	    fn->symbol.len <= 2) return false;
	for (isize i = 2; i < fn->symbol.len; i++) {
		if (!(gb_char_is_alphanumeric(fn->symbol[i]) || fn->symbol[i] == '_')) return false;
	}
	if (swift_import_member(symbol, "swiftGenerics") || swift_import_member(api, "genericSig") || swift_import_member(api, "declAttributes")) return false;
	for (JsonValue *fragment : swift_import_array(symbol, "declarationFragments")) {
		String word = swift_import_string(fragment, "spelling");
		for (isize i = 0; i < word.len; i++) {
			if (word[i] == '@') return false;
		}
		if (swift_import_string(fragment, "kind") == "keyword") {
			if (word == "async") fn->is_async = true;
			else if (word != "func") return false;
		}
	}
	fn->odin_name = swift_import_name(fn->name);
	array_init(&fn->parameters, permanent_allocator());
	JsonValue *signature = swift_import_member(symbol, "functionSignature");
	JsonValue *returns = swift_import_member(signature, "returns");
	if (!returns || returns->kind != Json_Array || returns->array.count == 0 ||
	    !swift_import_type(returns->array, true, &fn->result)) {
		return false;
	}
	if (!string_starts_with(fn->title, fn->name) || fn->title.len < fn->name.len+2 ||
	    fn->title[fn->name.len] != '(' || fn->title[fn->title.len-1] != ')') {
		return false;
	}
	String labels = substring(fn->title, fn->name.len+1, fn->title.len-1);
	String_Iterator it = {labels};
	for (JsonValue *parameter : swift_import_array(signature, "parameters")) {
		SwiftImportParameter p = {};
		String name = swift_import_string(parameter, "name");
		if (!swift_import_identifier(name)) return false;
		p.name = swift_import_name(name);
		p.label = string_split_iterator(&it, ':');
		if (!swift_import_identifier(p.label) || !swift_import_type(swift_import_array(parameter, "declarationFragments"), false, &p.type)) return false;
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

gb_internal String swift_import_relative(String directory, String path) {
	gbString text = gb_string_make(permanent_allocator(), "");
	String_Iterator it = {directory};
	String part;
	while (string_split_iterator_next(&it, '/', &part)) text = gb_string_appendc(text, "../");
	text = gb_string_append_length(text, path.text+1, path.len-1);
	return make_string_c(text);
}

gb_internal JsonValue *swift_import_find_api(JsonValue *api, String usr) {
	if (swift_import_string(api, "usr") == usr) return api;
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
		if (swift_import_member(availability, "isUnconditionallyUnavailable") ||
		    swift_import_member(availability, "isUnconditionallyDeprecated")) return false;
		if (swift_import_string(availability, "domain") != make_string_c(domain)) continue;
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
	array_add(&common, str_lit("-module-cache-path"));
	array_add(&common, swift_import_path(pkg->directory, "cache"));

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
	auto functions = array_make<SwiftImportFunction>(permanent_allocator());
	array_init(&pkg->unsupported, permanent_allocator());
	for (JsonValue *symbol : swift_import_array(graph, "symbols")) {
		String kind = swift_import_string(swift_import_member(symbol, "kind"), "identifier");
		auto components = swift_import_array(symbol, "pathComponents");
		bool method = kind == "swift.method" && components.count == 2;
		if (!(kind == "swift.func" && components.count == 1) && !method) continue;
		String usr = swift_import_string(swift_import_member(symbol, "identifier"), "precise");
		JsonValue *declaration = swift_import_find_api(api, usr);
		if (!declaration) continue;
		String name = swift_import_name(swift_import_string(declaration, "name"));
		String receiver = {};
		bool receiver_ok = !method;
		if (method && components[0]->kind == Json_String) {
			receiver = components[0]->string;
			name = concatenate3_strings(permanent_allocator(), receiver, str_lit("_"), name);
			for (JsonValue *type : swift_import_array(graph, "symbols")) {
				auto path = swift_import_array(type, "pathComponents");
				if (path.count == 1 && path[0]->kind == Json_String && path[0]->string == receiver &&
				    swift_import_string(swift_import_member(type, "kind"), "identifier") == "swift.struct" &&
				    !swift_import_member(type, "swiftGenerics") && swift_import_available(type)) receiver_ok = true;
			}
		}
		SwiftImportFunction fn = {};
		bool supported = receiver_ok && swift_import_available(symbol) && swift_import_function(symbol, declaration, &fn);
		if (method) {
			supported &= fn.is_async && fn.parameters.count == 0 && !fn.result.swift &&
			             swift_import_string(declaration, "funcSelfKind") == "NonMutating";
		}
		if (!supported) {
			array_add(&pkg->unsupported, name);
			continue;
		}
		fn.odin_name = name;
		fn.receiver = receiver;
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

	gbString probe = gb_string_make(permanent_allocator(), "");
	probe = gb_string_append_fmt(probe, "import %.*s\n", LIT(pkg->module));
	for_array(i, functions) {
		auto const &fn = functions[i];
		probe = gb_string_append_fmt(probe, "public func probe_%td(", i);
		if (fn.receiver.len) probe = gb_string_append_fmt(probe, "_ receiver: %.*s.%.*s", LIT(pkg->module), LIT(fn.receiver));
		for_array(j, fn.parameters) probe = gb_string_append_fmt(probe, "%s_ arg%td: %s", j ? ", " : "", j, fn.parameters[j].type.swift);
		probe = gb_string_append_fmt(probe, ")%s", fn.is_async ? " async" : "");
		if (fn.result.swift) probe = gb_string_append_fmt(probe, " -> %s", fn.result.swift);
		String owner = fn.receiver.len ? str_lit("receiver") : pkg->module;
		probe = gb_string_append_fmt(probe, " { %s%.*s.%.*s(", fn.is_async ? "await " : "", LIT(owner), LIT(fn.name));
		for_array(j, fn.parameters) {
			auto const &p = fn.parameters[j];
			if (j) probe = gb_string_appendc(probe, ", ");
			if (p.label != "_") probe = gb_string_append_fmt(probe, "%.*s: ", LIT(p.label));
			probe = gb_string_append_fmt(probe, "arg%td", j);
		}
		probe = gb_string_appendc(probe, ") }\n");
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
	array_add(&args, str_lit("nm"));
	array_add(&args, str_lit("-gU"));
	array_add(&args, pkg->library);
	String exports = {};
	if (!pkg->framework && !swift_import_exec(node, pkg->directory, args, &exports)) return false;
	for (isize index = functions.count; index-- > 0;) {
		auto const &fn = functions[index];
		gbString declaration = gb_string_make(permanent_allocator(), "");
		declaration = gb_string_append_fmt(declaration, "declare %s %s @\"%.*s\"(", fn.is_async ? "swifttailcc" : "swiftcc",
			fn.is_async || !fn.result.llvm ? "void" : fn.result.llvm, LIT(fn.symbol));
		if (fn.is_async) declaration = gb_string_appendc(declaration, "ptr swiftasync");
		if (fn.receiver.len) declaration = gb_string_appendc(declaration, ", ptr noalias swiftself");
		for_array(i, fn.parameters) declaration = gb_string_append_fmt(declaration, "%s%s", i || fn.is_async ? ", " : "", fn.parameters[i].type.llvm);
		declaration = gb_string_appendc(declaration, ")");
		String exported = concatenate_strings(permanent_allocator(), str_lit(" _"), fn.symbol);
		if (!swift_import_has_line(ir, make_string_c(declaration), true) ||
		    (!pkg->framework && (!swift_import_has_line(exports, exported, false) ||
		    (fn.is_async && !swift_import_has_line(exports, concatenate_strings(permanent_allocator(), exported, str_lit("Tu")), false))))) {
			array_add(&pkg->unsupported, fn.odin_name);
			array_ordered_remove(&functions, index);
		}
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
	source = gb_string_append_fmt(source, "package swift_%.*s_%llx\n\nimport \"base:intrinsics\"\nimport swift \"core:sys/darwin/Swift\"\n\n",
		LIT(pkg->module), cast(unsigned long long)fnv64a(identity.text, identity.len));
	String quoted_flags = quote_to_ascii(permanent_allocator(), make_string_c(flags));
	String quoted_library = quote_to_ascii(permanent_allocator(), pkg->framework ? pkg->library : swift_import_relative(pkg->directory, pkg->library));
	source = gb_string_append_fmt(source,
		"@(require, extra_linker_flags=%.*s)\n"
		"foreign import swift_library {\n\t%.*s,\n\t\"system:swiftCore\",\n\t\"system:swift_Concurrency\",\n}\n\n",
		LIT(quoted_flags), LIT(quoted_library));
	auto receivers = array_make<String>(permanent_allocator());
	for (auto const &fn : functions) {
		if (fn.receiver.len) {
			bool exists = false;
			for (String receiver : receivers) exists |= receiver == fn.receiver;
			if (!exists) {
				array_add(&receivers, fn.receiver);
				source = gb_string_append_fmt(source, "// Borrowed address of a live Swift value; this is not its storage layout.\n%.*s :: distinct rawptr\n\n", LIT(fn.receiver));
			}
		}
		gbString params = gb_string_make(permanent_allocator(), "");
		if (fn.receiver.len) params = gb_string_append_fmt(params, "receiver: %.*s", LIT(fn.receiver));
		for_array(i, fn.parameters) params = gb_string_append_fmt(params, "%s%.*s: %s", i ? ", " : "", LIT(fn.parameters[i].name), fn.parameters[i].type.odin);
		if (!fn.is_async) {
			source = gb_string_append_fmt(source, "foreign swift_library {\n\t@(link_name=\"%.*s\")\n\t%.*s :: proc \"swift\" (%s)", LIT(fn.symbol), LIT(fn.odin_name), params);
			if (fn.result.odin) source = gb_string_append_fmt(source, " -> %s", fn.result.odin);
			source = gb_string_appendc(source, " ---\n}\n\n");
			continue;
		}
		source = gb_string_append_fmt(source, "%.*s :: proc {_swift_%.*s_data, _swift_%.*s_auto}\n\n", LIT(fn.odin_name), LIT(fn.odin_name), LIT(fn.odin_name));
		for (int automatic = 0; automatic < 2; automatic++) {
			char const *id_type = automatic ? "swift.Request_Id" : "T";
			source = gb_string_append_fmt(source, "@(private, require_results)\n_swift_%.*s_%s :: proc(%s%s", LIT(fn.odin_name), automatic ? "auto" : "data", params, gb_string_length(params) ? ", " : "");
			if (!automatic) source = gb_string_appendc(source, "user_data: $T, ");
			source = gb_string_append_fmt(source, "completion: proc(user_data: %s", id_type);
			if (fn.result.odin) source = gb_string_append_fmt(source, ", result: %s", fn.result.odin);
			source = gb_string_append_fmt(source, ")) -> (id: %s, ok: bool) #optional_ok {\n\tif completion == nil", id_type);
			if (fn.receiver.len) source = gb_string_appendc(source, " || receiver == nil");
			source = gb_string_appendc(source, " {\n\t\treturn\n\t}\n");
			if (automatic) source = gb_string_appendc(source, "\tuser_data := swift.request_id_generate()\n\tif user_data == 0 {\n\t\treturn\n\t}\n");
			source = gb_string_append_fmt(source, "\tok = intrinsics.%s(\"%.*s\", user_data, completion", fn.receiver.len ? "swift_async_method_call" : "swift_async_call", LIT(fn.symbol));
			if (fn.receiver.len) source = gb_string_appendc(source, ", receiver");
			for (auto const &param : fn.parameters) source = gb_string_append_fmt(source, ", %.*s", LIT(param.name));
			source = gb_string_appendc(source, ")\n\tif ok {\n\t\tid = user_data\n\t}\n\treturn\n}\n\n");
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
