// Native async imports use a task-owned record for arguments and completion.
// Imported calls have scalar arguments/results and an optional borrowed
// receiver. Completion borrows the native task handle from the runtime.

gb_internal Type *lb_swift_async_proc_type(Type **params, isize count, bool has_self = false) {
	Type *tuple = alloc_type_tuple_from_field_types(params, count, false, true);
	tuple->Tuple.variables[0]->flags |= EntityFlag_SwiftAsync;
	if (has_self) {
		tuple->Tuple.variables[1]->flags |= EntityFlag_SwiftSelf;
	}
	return alloc_type_proc(nullptr, tuple, count, nullptr, 0, false, ProcCC_SwiftAsync);
}

gb_internal lbProcedure *lb_swift_async_helper(lbModule *m, String prefix, char const *suffix, Type *type) {
	gbString name = gb_string_append_fmt(gb_string_make(permanent_allocator(), ""), "%.*s.%s", LIT(prefix), suffix);
	lbProcedure *p = lb_create_dummy_procedure(m, make_string_c(name), type);
	LLVMSetLinkage(p->value, LLVMPrivateLinkage);
	if (build_context.sanitizer_flags & SanitizerFlag_Address) {
		lb_add_attribute_to_proc(m, p->value, "sanitize_address");
	}
	return p;
}

gb_internal lbValue lb_swift_capture_load(lbProcedure *p, LLVMTypeRef capture_type, LLVMValueRef capture, unsigned index, Type *type) {
	LLVMValueRef ptr = LLVMBuildStructGEP2(p->builder, capture_type, capture, index, "");
	return lbValue{LLVMBuildLoad2(p->builder, lb_type(p->module, type), ptr, ""), type};
}

gb_internal lbValue lb_build_swift_async_call(lbProcedure *p, Ast *expr, bool has_self) {
	ast_node(ce, CallExpr, expr);
	lbModule *m = p->module;
	String symbol = type_and_value_of_expr(ce->args[0]).value.value_string;
	isize arg_count = ce->args.count - 2;
	lbValue callback = lb_build_expr(p, ce->args[1]);
	Type *callback_type = base_type(callback.type);
	Type *result_type = nullptr;
	if (callback_type->Proc.param_count == 2) {
		result_type = callback_type->Proc.params->Tuple.variables[1]->type;
	}

	auto values = array_make<lbValue>(temporary_allocator());
	array_add(&values, callback);
	for (isize i = 2; i < ce->args.count; i++) {
		array_add(&values, lb_build_expr(p, ce->args[i]));
	}
	auto fields = array_make<LLVMTypeRef>(temporary_allocator());
	for (lbValue value : values) {
		array_add(&fields, lb_type(m, value.type));
	}
	if (result_type) {
		array_add(&fields, lb_type(m, result_type));
	}
	LLVMTypeRef capture_type = LLVMStructTypeInContext(m->ctx, fields.data, cast(unsigned)fields.count, false);
	GB_ASSERT(lb_alignof(capture_type) <= 8);

	gbString name = gb_string_append_fmt(gb_string_make(permanent_allocator(), ""),
		"__$%s::swift_async_%lld", m->module_name, m->swift_next_async_id++);
	String prefix = make_string_c(name);
	Type *entry_params[] = {t_rawptr, t_rawptr};
	Type *resume_params[] = {t_rawptr, result_type};
	Type *invoke_params = alloc_type_tuple_from_field_types(entry_params, 1, false, true);
	Type *invoke_type = alloc_type_proc(nullptr, invoke_params, 1, nullptr, 0, false, ProcCC_Odin);
	lbProcedure *entry = lb_swift_async_helper(m, prefix, "entry", lb_swift_async_proc_type(entry_params, 2, true));
	lbProcedure *resume = lb_swift_async_helper(m, prefix, "resume", lb_swift_async_proc_type(resume_params, result_type ? 2 : 1));
	lbProcedure *invoke = lb_swift_async_helper(m, prefix, "invoke", invoke_type);

	// The native function receives the async frame, an optional Swift self,
	// and scalar inputs. The checker validates the capture alignment.
	auto native_params = array_make<Type *>(temporary_allocator());
	array_add(&native_params, t_rawptr);
	for (isize i = 0; i < arg_count; i++) {
		array_add(&native_params, values[i+1].type);
	}
	Type *native_type = lb_swift_async_proc_type(native_params.data, native_params.count, has_self);
	char *native_name = alloc_cstring(permanent_allocator(), symbol);
	LLVMValueRef native = LLVMGetNamedFunction(m->mod, native_name);
	if (native == nullptr) {
		native = LLVMAddFunction(m->mod, native_name, lb_get_procedure_raw_type(m, native_type));
		LLVMSetFunctionCallConv(native, lbCallingConvention_SwiftTail);
		lb_add_function_type_attributes(native, lb_get_function_type(m, native_type), ProcCC_SwiftAsync);
	}

	lb_begin_procedure_body(entry);
	{
		auto args = array_make<lbValue>(temporary_allocator());
		array_add(&args, lbValue{LLVMGetParam(entry->value, 0), t_rawptr});
		lbValue capture = lb_emit_runtime_call(entry, "swift_async_payload", args);
		array_add(&args, lbValue{resume->value, t_rawptr});
		lbValue child = lb_emit_runtime_call(entry, "swift_async_prepare", args);
		array_clear(&args);
		array_add(&args, child);
		for (isize i = 0; i < arg_count; i++) {
			array_add(&args, lb_swift_capture_load(entry, capture_type, capture.value, cast(unsigned)(i+1), values[i+1].type));
		}
		lb_emit_call(entry, lbValue{native, native_type}, args, ProcInlining_none, ProcTailing_must_tail);
		LLVMBuildRetVoid(entry->builder);
	}
	lb_end_procedure_body(entry);

	// Save a returned scalar before freeing the child frame. The runtime then
	// switches to the main executor and restores the saved Odin context.
	lb_begin_procedure_body(resume);
	{
		LLVMValueRef child = LLVMGetParam(resume->value, 0);
		if (result_type) {
			LLVMValueRef parent = LLVMBuildLoad2(resume->builder, lb_type(m, t_rawptr), child, "parent");
			auto args = array_make<lbValue>(temporary_allocator());
			array_add(&args, lbValue{parent, t_rawptr});
			lbValue capture = lb_emit_runtime_call(resume, "swift_async_payload", args);
			LLVMValueRef result = LLVMBuildStructGEP2(resume->builder, capture_type, capture.value, cast(unsigned)values.count, "result");
			LLVMBuildStore(resume->builder, LLVMGetParam(resume->value, 1), result);
		}
		auto args = array_make<lbValue>(temporary_allocator());
		array_add(&args, lbValue{child, t_rawptr});
		lbValue complete = lb_find_runtime_value(m, str_lit("swift_async_complete"));
		lb_emit_call(resume, complete, args, ProcInlining_none, ProcTailing_must_tail);
		LLVMBuildRetVoid(resume->builder);
	}
	lb_end_procedure_body(resume);

	lb_begin_procedure_body(invoke);
	{
		LLVMValueRef capture = LLVMGetParam(invoke->value, 0);
		lbValue completion = lb_swift_capture_load(invoke, capture_type, capture, 0, callback.type);
		auto args = array_make<lbValue>(temporary_allocator());
		lbValue task = lb_emit_runtime_call(invoke, "swift_async_current", args);
		array_add(&args, lb_emit_conv(invoke, task, callback_type->Proc.params->Tuple.variables[0]->type));
		if (result_type) {
			array_add(&args, lb_swift_capture_load(invoke, capture_type, capture, cast(unsigned)values.count, result_type));
		}
		lb_emit_call(invoke, completion, args);
		LLVMBuildRetVoid(invoke->builder);
	}
	lb_end_procedure_body(invoke);

	LLVMValueRef capture = llvm_alloca(p, capture_type, lb_alignof(capture_type), "swift.capture");
	LLVMBuildStore(p->builder, LLVMConstNull(capture_type), capture);
	for (isize i = 0; i < values.count; i++) {
		LLVMValueRef field = LLVMBuildStructGEP2(p->builder, capture_type, capture, cast(unsigned)i, "");
		LLVMBuildStore(p->builder, values[i].value, field);
	}
	gbString descriptor_name = gb_string_append_fmt(gb_string_make(temporary_allocator(), ""), "%.*sTu", LIT(symbol));
	LLVMValueRef descriptor = LLVMGetNamedGlobal(m->mod, descriptor_name);
	if (descriptor == nullptr) {
		LLVMTypeRef descriptor_fields[] = {lb_type(m, t_i32), lb_type(m, t_u32)};
		LLVMTypeRef descriptor_type = LLVMStructTypeInContext(m->ctx, descriptor_fields, 2, false);
		descriptor = LLVMAddGlobal(m->mod, descriptor_type, descriptor_name);
		LLVMSetGlobalConstant(descriptor, true);
	}
	auto args = array_make<lbValue>(temporary_allocator());
	array_add(&args, lbValue{entry->value, t_rawptr});
	array_add(&args, lbValue{descriptor, t_rawptr});
	array_add(&args, lbValue{capture, t_rawptr});
	array_add(&args, lb_const_int(m, t_int, lb_sizeof(capture_type)));
	array_add(&args, lbValue{invoke->value, invoke_type});
	array_add(&args, lbValue{callback.value, t_rawptr});
	return lb_emit_runtime_call(p, "swift_async_start", args);
}

// An exported Odin procedure keeps its normal calling convention. Swift calls
// a separate native entry point, which supplies an ordinary Odin context.
gb_internal void lb_generate_swift_exports(lbGenerator *gen) {
	if (!build_context.swift_export) return;
	lbModule *m = &gen->default_module;
	// Independently built Odin roots cannot share their generated runtime state.
	// Diagnose multiple roots at link time instead of coalescing weak startup
	// functions and silently running the wrong package's initializers.
	LLVMSetLinkage(gen->startup_runtime->value, LLVMExternalLinkage);
	LLVMSetLinkage(gen->cleanup_runtime->value, LLVMExternalLinkage);
	for (auto const &exported : swift_export_procedures) {
		Type *original = base_type(exported.entity->type);
		auto params = array_make<Type *>(temporary_allocator());
		for (isize i = 0; i < original->Proc.param_count; i++) {
			Type *type = original->Proc.params->Tuple.variables[i]->type;
			if (is_type_slice(type)) {
				// UnsafeMutableBufferPointer's optional address and count are
				// two integer components in the Darwin arm64 Swift ABI.
				array_add(&params, t_uintptr);
				array_add(&params, t_int);
			} else {
				array_add(&params, type);
			}
		}
		Type *tuple = alloc_type_tuple_from_field_types(params.data, params.count, false, true);
		if (tuple) {
			for (Entity *param : tuple->Tuple.variables) param->token = make_token_ident(str_lit("arg"));
		}
		Type *type = alloc_type_proc(nullptr, tuple, params.count, original->Proc.results, original->Proc.result_count, false, ProcCC_Swift);
		lbProcedure *p = lb_create_dummy_procedure(m, exported.symbol, type);
		p->is_export = true;
		LLVMSetLinkage(p->value, LLVMExternalLinkage);
		if (build_context.sanitizer_flags & SanitizerFlag_Address) lb_add_attribute_to_proc(m, p->value, "sanitize_address");
		lb_begin_procedure_body(p);
		auto args = array_make<lbValue>(temporary_allocator());
		isize index = 0;
		for (isize i = 0; i < original->Proc.param_count; i++) {
			Type *param_type = original->Proc.params->Tuple.variables[i]->type;
			lbValue value = lb_emit_load(p, lb_find_value_from_entity(m, tuple->Tuple.variables[index++]));
			if (is_type_slice(param_type)) {
				lbValue count = lb_emit_load(p, lb_find_value_from_entity(m, tuple->Tuple.variables[index++]));
				lbAddr slice = lb_add_local_generated(p, param_type, false);
				lbValue data = lb_emit_conv(p, value, alloc_type_multi_pointer(base_type(param_type)->Slice.elem));
				lb_fill_slice(p, slice, data, count);
				value = lb_addr_load(p, slice);
			}
			array_add(&args, value);
		}
		lbValue result = lb_emit_call(p, lb_find_procedure_value_from_entity(m, exported.entity), args);
		if (original->Proc.result_count) {
			lb_build_return_stmt_internal(p, result, exported.entity->token.pos);
		} else {
			LLVMBuildRetVoid(p->builder);
		}
		lb_end_procedure_body(p);
	}

	// A Swift host has no Odin main. Initialize globals before its first call,
	// including @(init), and pair shutdown with the normal runtime cleanup.
	lbProcedure *targets[] = {gen->startup_runtime, gen->cleanup_runtime};
	char const *names[] = {"llvm.global_ctors", "llvm.global_dtors"};
	for (isize i = 0; i < 2; i++) {
		Type *type = alloc_type_proc(nullptr, nullptr, 0, nullptr, 0, false, ProcCC_CDecl);
		String name = make_string_c(gb_string_append_fmt(gb_string_make(permanent_allocator(), ""), "__odin_swift_%.*s.%s", LIT(build_context.swift_module_name), i == 0 ? "initialize" : "finalize"));
		lbProcedure *p = lb_create_dummy_procedure(m, name, type);
		LLVMSetLinkage(p->value, LLVMInternalLinkage);
		lb_begin_procedure_body(p);
		lb_emit_call(p, lbValue{targets[i]->value, targets[i]->type}, {});
		LLVMBuildRetVoid(p->builder);
		lb_end_procedure_body(p);
		LLVMTypeRef fields[] = {LLVMInt32TypeInContext(m->ctx), LLVMPointerTypeInContext(m->ctx, 0), LLVMPointerTypeInContext(m->ctx, 0)};
		LLVMTypeRef entry_type = LLVMStructTypeInContext(m->ctx, fields, 3, false);
		LLVMValueRef values[] = {LLVMConstInt(fields[0], 65535, false), p->value, LLVMConstNull(fields[2])};
		LLVMValueRef entry = LLVMConstNamedStruct(entry_type, values, 3);
		LLVMValueRef global = LLVMAddGlobal(m->mod, LLVMArrayType(entry_type, 1), names[i]);
		LLVMSetInitializer(global, LLVMConstArray(entry_type, &entry, 1));
		LLVMSetLinkage(global, LLVMAppendingLinkage);
	}
}
