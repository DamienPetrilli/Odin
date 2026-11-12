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
