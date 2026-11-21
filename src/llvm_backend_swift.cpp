// Gather only fields, never padding. Swift may use a four-byte register for
// three Bool bytes, while an Odin value still occupies exactly three bytes.
gb_internal LLVMValueRef lb_swift_record_pack(lbProcedure *p, lbValue value, LLVMTypeRef abi) {
	SwiftABIRecordComponent components[4];
	isize count = swift_abi_record_components(value.type, components, gb_count_of(components));
	GB_ASSERT(count <= gb_count_of(components));
	LLVMValueRef result = LLVMGetUndef(abi);
	for (isize i = 0; i < count; i++) {
		auto const &component = components[i];
		LLVMTypeRef target = count == 1 ? abi : LLVMStructGetTypeAtIndex(abi, cast(unsigned)i);
		LLVMValueRef packed = LLVMConstNull(target);
		for (isize j = 0; j < component.count; j++) {
			isize index = component.first+j;
			lbValue field = lb_emit_struct_ev(p, value, cast(i32)index);
			LLVMValueRef part = field.value;
			if (base_type(field.type) == t_bool) part = LLVMBuildICmp(p->builder, LLVMIntNE, part, LLVMConstNull(LLVMTypeOf(part)), "");
			if (component.count == 1) {
				packed = part;
			} else {
				part = LLVMBuildIntCast2(p->builder, part, target, false, "");
				i64 shift = 8*(type_offset_of(value.type, index)-component.offset);
				if (shift) part = LLVMBuildShl(p->builder, part, LLVMConstInt(target, cast(u64)shift, false), "");
				packed = LLVMBuildOr(p->builder, packed, part, "");
			}
		}
		result = count == 1 ? packed : LLVMBuildInsertValue(p->builder, result, packed, cast(unsigned)i, "");
	}
	return result;
}

gb_internal LLVMValueRef lb_swift_record_unpack(lbProcedure *p, LLVMValueRef value, Type *type) {
	SwiftABIRecordComponent components[4];
	isize count = swift_abi_record_components(type, components, gb_count_of(components));
	GB_ASSERT(count <= gb_count_of(components));
	lbAddr slot = lb_add_local_generated(p, type, true);
	auto fields = base_type(type)->Struct.fields;
	for (isize i = 0; i < count; i++) {
		auto const &component = components[i];
		LLVMValueRef packed = count == 1 ? value : LLVMBuildExtractValue(p->builder, value, cast(unsigned)i, "");
		for (isize j = 0; j < component.count; j++) {
			isize index = component.first+j;
			Type *field_type = fields[index]->type;
			LLVMValueRef part = packed;
			if (component.count > 1) {
				i64 shift = 8*(type_offset_of(type, index)-component.offset);
				if (shift) part = LLVMBuildLShr(p->builder, part, LLVMConstInt(LLVMTypeOf(part), cast(u64)shift, false), "");
				LLVMTypeRef target = base_type(field_type) == t_bool ? LLVMInt1TypeInContext(p->module->ctx) : lb_type(p->module, field_type);
				part = LLVMBuildIntCast2(p->builder, part, target, false, "");
			}
			if (base_type(field_type) == t_bool) part = LLVMBuildZExt(p->builder, part, lb_type(p->module, field_type), "");
			lb_emit_store(p, lb_emit_struct_ep(p, slot.addr, cast(i32)index), (lbValue{part, field_type}));
		}
	}
	return lb_addr_load(p, slot).value;
}

// Swift's indirect value size can exclude tail padding present in Odin's
// size. Access fields separately on foreign storage in both directions.
gb_internal LLVMValueRef lb_swift_record_load(lbProcedure *p, LLVMValueRef pointer, Type *type) {
	lbAddr slot = lb_add_local_generated(p, type, true);
	lbValue source = {pointer, alloc_type_pointer(type)};
	auto fields = base_type(type)->Struct.fields;
	for_array(i, fields) {
		lbValue field = lb_emit_load(p, lb_emit_struct_ep(p, source, cast(i32)i));
		lb_emit_store(p, lb_emit_struct_ep(p, slot.addr, cast(i32)i), field);
	}
	return lb_addr_load(p, slot).value;
}

gb_internal void lb_swift_record_store(lbProcedure *p, LLVMValueRef pointer, lbValue value) {
	lbValue destination = {pointer, alloc_type_pointer(value.type)};
	auto fields = base_type(value.type)->Struct.fields;
	for_array(i, fields) {
		lb_emit_store(p, lb_emit_struct_ep(p, destination, cast(i32)i), lb_emit_struct_ev(p, value, cast(i32)i));
	}
}

// LLVM requires the call operand to be a swifterror alloca. Its C builder
// has no setter for that bit. Move one instruction, in the same context,
// into the entry allocation block. All throwing calls in this procedure
// reuse the slot; the caller clears it before each call.
gb_internal LLVMValueRef lb_swift_error_slot(lbProcedure *p) {
	if (p->swift_error_slot) return p->swift_error_slot;
	char const ir[] = "define void @slot() { %s = alloca swifterror ptr, align 8\n ret void }";
	LLVMMemoryBufferRef buffer = LLVMCreateMemoryBufferWithMemoryRangeCopy(ir, sizeof(ir)-1, "Swift error slot");
	LLVMModuleRef donor = nullptr;
	char *message = nullptr;
	if (LLVMParseIRInContext(p->module->ctx, buffer, &donor, &message)) {
		GB_PANIC("Invalid Swift error slot IR: %s", message);
	}
	LLVMValueRef slot = LLVMGetFirstInstruction(LLVMGetEntryBasicBlock(LLVMGetFirstFunction(donor)));
	LLVMInstructionRemoveFromParent(slot);
	LLVMDisposeModule(donor);
	LLVMBasicBlockRef block = LLVMGetInsertBlock(p->builder);
	LLVMPositionBuilderAtEnd(p->builder, p->decl_block->block);
	LLVMInsertIntoBuilderWithName(p->builder, slot, "swift.error");
	LLVMPositionBuilderAtEnd(p->builder, block);
	p->swift_error_slot = slot;
	return slot;
}

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
			LLVMValueRef value = LLVMGetParam(resume->value, 1);
			if (base_type(result_type) == t_bool) {
				value = LLVMBuildZExt(resume->builder, value, lb_type(m, result_type), "");
			}
			LLVMBuildStore(resume->builder, value, result);
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

// Convert only at the generated module entry. Ordinary Odin enum variables
// and calls retain their declared raw values. Invalid results trap even when
// assertions are disabled; never manufacture an invalid Swift enum value.
gb_internal lbValue lb_swift_export_enum(lbProcedure *p, Type *type, lbValue value, bool to_swift) {
	lbModule *m = p->module;
	auto fields = base_type(type)->Enum.fields;
	Type *tag_type = swift_export_enum_tag_type(type);
	if (!to_swift && !tag_type) return lb_const_value(m, type, fields[0]->Constant.value);
	if (!tag_type) tag_type = t_u8;
	Type *result_type = to_swift ? tag_type : type;
	lbBlock *invalid = lb_create_block(p, "swift.enum.invalid");
	lbBlock *done = lb_create_block(p, "swift.enum.done");
	LLVMValueRef branch = LLVMBuildSwitch(p->builder, value.value, invalid->block, cast(unsigned)fields.count);
	auto values = array_make<LLVMValueRef>(temporary_allocator());
	auto blocks = array_make<LLVMBasicBlockRef>(temporary_allocator());
	for_array(i, fields) {
		lbValue raw = lb_const_value(m, type, fields[i]->Constant.value);
		lbValue tag = lb_const_int(m, tag_type, i);
		lbBlock *block = lb_create_block(p, "swift.enum.case");
		LLVMAddCase(branch, to_swift ? raw.value : tag.value, block->block);
		lb_start_block(p, block);
		array_add(&values, to_swift ? tag.value : raw.value);
		array_add(&blocks, block->block);
		lb_emit_jump(p, done);
	}
	lb_start_block(p, invalid);
	lb_call_intrinsic(p, "llvm.trap", nullptr, 0, nullptr, 0);
	LLVMBuildUnreachable(p->builder);
	lb_start_block(p, done);
	LLVMValueRef result = LLVMBuildPhi(p->builder, lb_type(m, result_type), "swift.enum");
	LLVMAddIncoming(result, values.data, blocks.data, cast(unsigned)values.count);
	return lbValue{result, result_type};
}

// UUID storage remains Swift-owned. Read borrowed parameters through the public
// getter and initialize an indirect result exactly once through its constructor.
gb_internal lbValue lb_swift_export_uuid_read(lbProcedure *p, Type *type, lbValue pointer) {
	lbModule *m = p->module;
	LLVMTypeRef word = lb_type(m, t_u64);
	LLVMTypeRef words[] = {word, word};
	LLVMTypeRef result_type = LLVMStructTypeInContext(m->ctx, words, 2, false);
	LLVMTypeRef argument = lb_type(m, t_rawptr);
	LLVMTypeRef signature = LLVMFunctionType(result_type, &argument, 1, false);
	char const *name = alloc_cstring(temporary_allocator(), swift_export_uuid_getter);
	LLVMValueRef function = LLVMGetNamedFunction(m->mod, name);
	if (!function) function = LLVMAddFunction(m->mod, name, signature);
	LLVMSetFunctionCallConv(function, LLVMSwiftCallConv);
	LLVMAttributeRef self = LLVMCreateEnumAttribute(m->ctx, LLVMGetEnumAttributeKindForName("swiftself", 9), 0);
	LLVMAddAttributeAtIndex(function, 1, self);
	LLVMValueRef value = LLVMBuildCall2(p->builder, signature, function, &pointer.value, 1, "");
	LLVMSetInstructionCallConv(value, LLVMSwiftCallConv);
	LLVMAddCallSiteAttribute(value, 1, self);
	LLVMValueRef bytes = LLVMGetUndef(lb_type(m, type));
	for (unsigned i = 0; i < 16; i++) {
		LLVMValueRef part = LLVMBuildExtractValue(p->builder, value, i/8, "");
		if (i%8) part = LLVMBuildLShr(p->builder, part, LLVMConstInt(word, 8*(i%8), false), "");
		part = LLVMBuildTrunc(p->builder, part, lb_type(m, t_u8), "");
		bytes = LLVMBuildInsertValue(p->builder, bytes, part, i, "");
	}
	return {bytes, type};
}

gb_internal void lb_swift_export_uuid_initialize(lbProcedure *p, lbValue pointer, lbValue value) {
	lbModule *m = p->module;
	LLVMTypeRef types[17];
	LLVMValueRef values[17];
	types[0] = lb_type(m, t_rawptr);
	values[0] = pointer.value;
	for (unsigned i = 0; i < 16; i++) {
		types[i+1] = lb_type(m, t_u8);
		values[i+1] = LLVMBuildExtractValue(p->builder, value.value, i, "");
	}
	LLVMTypeRef signature = LLVMFunctionType(LLVMVoidTypeInContext(m->ctx), types, 17, false);
	char const *name = alloc_cstring(temporary_allocator(), swift_export_uuid_initializer);
	LLVMValueRef function = LLVMGetNamedFunction(m->mod, name);
	if (!function) function = LLVMAddFunction(m->mod, name, signature);
	LLVMSetFunctionCallConv(function, LLVMSwiftCallConv);
	LLVMAttributeRef sret = lb_create_enum_attribute_with_type(m->ctx, "sret", lb_type(m, t_u8));
	LLVMAddAttributeAtIndex(function, 1, sret);
	LLVMValueRef call = LLVMBuildCall2(p->builder, signature, function, values, 17, "");
	LLVMSetInstructionCallConv(call, LLVMSwiftCallConv);
	LLVMAddCallSiteAttribute(call, 1, sret);
}

// Scalar optionals use either an extra inhabitant, a packed tag, or a
// separate tag register. Preserve the bits of floating-point payloads.
gb_internal Type *lb_swift_optional_word(Type *element) {
	if (element == t_bool) return t_u8;
	switch (type_size_of(element)) {
	case 1: return t_u16;
	case 2: return t_u32;
	default: return t_u64;
	}
}

gb_internal lbValue lb_swift_optional_read(lbProcedure *p, Type *type, Type *element, lbValue word, lbValue tag) {
	lbModule *m = p->module;
	LLVMBuilderRef b = p->builder;
	lbAddr slot = lb_add_local_generated(p, type, true);
	LLVMValueRef bits = word.value;
	LLVMValueRef present;
	if (element == t_bool) {
		present = LLVMBuildICmp(b, LLVMIntNE, bits, lb_const_int(m, t_u8, 2).value, "");
		bits = LLVMBuildAnd(b, bits, lb_const_int(m, t_u8, 1).value, "");
	} else {
		unsigned width = cast(unsigned)type_size_of(element)*8;
		LLVMValueRef indicator = tag.value ? tag.value : LLVMBuildLShr(b, bits, LLVMConstInt(LLVMTypeOf(bits), width, false), "");
		present = LLVMBuildNot(b, LLVMBuildTrunc(b, indicator, LLVMInt1TypeInContext(m->ctx), ""), "");
		bits = LLVMBuildIntCast2(b, bits, LLVMIntTypeInContext(m->ctx, width), false, "");
		bits = LLVMBuildBitCast(b, bits, lb_type(m, element), "");
		// A missing scalar has no payload. Keep the internal lane defined
		// without forcing a particular payload until it crosses out of Odin.
		bits = LLVMBuildFreeze(b, bits, "");
	}
	lbValue some = lb_const_union_tag(m, type, element);
	lbValue result_tag = {LLVMBuildSelect(b, present, some.value, LLVMConstNull(LLVMTypeOf(some.value)), ""), some.type};
	lb_emit_store(p, lb_emit_union_tag_ptr(p, slot.addr), result_tag);
	lb_emit_store(p, lb_emit_union_variant_ptr(p, slot.addr, element), {bits, element});
	return lb_addr_load(p, slot);
}

// A Swift caller already owns the bits of its incoming value. When the
// body only copies whole input optionals into its result, the native entry
// can forward those bits. Other results must clear an inactive payload.
gb_internal bool lb_swift_optional_forwards_input(lbModule *m, Entity *entity, Type *result_type) {
	Type *proc = base_type(entity->type);
	for (Entity *param : proc->Proc.params->Tuple.variables) {
		if (param->type != result_type && !is_swift_abi_numeric_scalar(param->type)) return false;
	}
	lbModule *owner = lb_module_of_entity(m->gen, entity, m);
	LLVMValueRef body = LLVMGetNamedFunction(owner->mod, alloc_cstring(temporary_allocator(), entity->Procedure.link_name));
	if (!body || LLVMIsDeclaration(body) || LLVMCountParams(body) != 1+proc->Proc.param_count) return false;
	unsigned sret = LLVMGetEnumAttributeKindForName("sret", 4);
	if (!LLVMGetEnumAttributeAtIndex(body, 1, sret)) return false;
	LLVMValueRef dest = LLVMGetParam(body, 0);
	unsigned memcpy_id = LLVMLookupIntrinsicID("llvm.memcpy", 11);
	unsigned inline_id = LLVMLookupIntrinsicID("llvm.memcpy.inline", 18);
	auto copies_input = [&](LLVMValueRef inst) -> bool {
		if (!inst || !LLVMIsACallInst(inst) || LLVMGetNumArgOperands(inst) != 4 || LLVMGetOperand(inst, 0) != dest) return false;
		LLVMValueRef callee = LLVMGetCalledValue(inst);
		if (!LLVMIsAFunction(callee)) return false;
		unsigned id = LLVMGetIntrinsicID(callee);
		if (id != memcpy_id && id != inline_id) return false;
		LLVMValueRef size = LLVMGetOperand(inst, 2);
		if (!LLVMIsAConstantInt(size) || LLVMConstIntGetZExtValue(size) != cast(u64)type_size_of(result_type)) return false;
		LLVMValueRef source = LLVMGetOperand(inst, 1);
		for (isize i = 0; i < proc->Proc.param_count; i++) {
			if (proc->Proc.params->Tuple.variables[i]->type == result_type && LLVMGetParam(body, cast(unsigned)i+1) == source) return true;
		}
		return false;
	};
	// Exclude escaping addresses, partial writes and modified inputs.
	for (unsigned i = 0; i < LLVMCountParams(body); i++) {
		LLVMValueRef arg = LLVMGetParam(body, i);
		if (LLVMGetTypeKind(LLVMTypeOf(arg)) != LLVMPointerTypeKind) continue;
		for (LLVMUseRef use = LLVMGetFirstUse(arg); use; use = LLVMGetNextUse(use)) {
			LLVMValueRef user = LLVMGetUser(use);
			if (LLVMIsALoadInst(user) && !LLVMGetFirstUse(user)) continue;
			// Debug info spills the address to a local slot whose only
			// instruction use is this store. An actual read must fall back.
			if (LLVMIsAStoreInst(user) && LLVMGetOperand(user, 0) == arg) {
				LLVMValueRef slot = LLVMGetOperand(user, 1);
				if (LLVMIsAAllocaInst(slot) && LLVMGetNextUse(LLVMGetFirstUse(slot)) == nullptr) continue;
			}
			if (!copies_input(user)) return false;
		}
	}
	bool returns = false;
	for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(body); bb; bb = LLVMGetNextBasicBlock(bb)) {
		LLVMValueRef term = LLVMGetBasicBlockTerminator(bb);
		if (term && LLVMIsAReturnInst(term)) {
			if (!copies_input(LLVMGetPreviousInstruction(term))) return false;
			returns = true;
		}
	}
	return returns;
}

gb_internal lbValue lb_swift_optional_write(lbProcedure *p, lbValue value, Type *element, Type *native_type, bool forwarded) {
	lbModule *m = p->module;
	LLVMBuilderRef b = p->builder;
	lbValue slot = lb_address_from_load_or_generate_local(p, value);
	lbValue tag = lb_emit_load(p, lb_emit_union_tag_ptr(p, slot));
	lbValue some = lb_const_union_tag(m, value.type, element);
	LLVMValueRef present = LLVMBuildICmp(b, LLVMIntEQ, tag.value, some.value, "");
	LLVMValueRef bits = lb_emit_load(p, lb_emit_union_variant_ptr(p, slot, element)).value;
	if (element == t_bool) {
		return {LLVMBuildSelect(b, present, bits, lb_const_int(m, t_u8, 2).value, ""), t_u8};
	}
	unsigned width = cast(unsigned)type_size_of(element)*8;
	bits = LLVMBuildBitCast(b, bits, LLVMIntTypeInContext(m->ctx, width), "");
	if (width == 64) {
		if (!forwarded) bits = LLVMBuildSelect(b, present, bits, LLVMConstNull(LLVMTypeOf(bits)), "");
		LLVMValueRef absent = LLVMBuildNot(b, present, "");
		lbValue parts[] = {{bits, t_u64}, {LLVMBuildZExt(b, absent, lb_type(m, t_u8), ""), t_u8}};
		return lb_build_struct_value(p, native_type, parts, gb_count_of(parts));
	}
	LLVMTypeRef word = lb_type(m, native_type);
	LLVMValueRef none = LLVMConstInt(word, 1ull << width, false);
	return {LLVMBuildSelect(b, present, LLVMBuildZExt(b, bits, word, ""), none, ""), native_type};
}

// Module entries preserve their generated link names and call the exported
// Swift procedures with their native convention, without an Odin context.
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
		Type *result_type = reduce_tuple_to_single_type(original->Proc.results);
		bool uuid_result = is_swift_uuid_type(result_type);
		auto params = array_make<Type *>(temporary_allocator());
		if (uuid_result) array_add(&params, t_rawptr);
		for (isize i = 0; i < original->Proc.param_count; i++) {
			Type *type = original->Proc.params->Tuple.variables[i]->type;
			if (is_swift_uuid_type(type)) {
				array_add(&params, t_rawptr);
			} else if (Type *element = swift_export_optional_element(type)) {
				array_add(&params, lb_swift_optional_word(element));
				if (type_size_of(element) == 8) array_add(&params, t_u8);
			} else if (type == t_string) {
				array_add(&params, t_u64);
				array_add(&params, t_rawptr);
			} else if (is_type_enum(type)) {
				if (Type *tag = swift_export_enum_tag_type(type)) array_add(&params, tag);
			} else if (is_type_slice(type)) {
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
		if (uuid_result) tuple->Tuple.variables[0]->flags |= EntityFlag_SwiftResult;
		Type *native_result = uuid_result ? nullptr : is_type_enum(result_type) ? swift_export_enum_tag_type(result_type) : result_type;
		Type *results = original->Proc.results;
		if (original->Proc.result_count == 1) results = native_result ? alloc_type_tuple_from_field_types(&native_result, 1, false, true) : nullptr;
		Type *optional_result = swift_export_optional_element(result_type);
		if (optional_result) {
			Type *parts[] = {lb_swift_optional_word(optional_result), t_u8};
			isize count = type_size_of(optional_result) == 8 ? 2 : 1;
			results = alloc_type_tuple_from_field_types(parts, count, false, true);
			native_result = reduce_tuple_to_single_type(results);
		}
		Type *type = alloc_type_proc(nullptr, tuple, params.count, results, results ? results->Tuple.variables.count : 0, false, ProcCC_Swift);
		lbProcedure *p = lb_create_dummy_procedure(m, exported.symbol, type);
		p->is_export = true;
		LLVMSetLinkage(p->value, LLVMExternalLinkage);
		if (exported.link_alias.len) {
			LLVMAddAlias2(m->mod, LLVMGlobalGetValueType(p->value), 0, p->value, alloc_cstring(permanent_allocator(), exported.link_alias));
		}
		if (build_context.sanitizer_flags & SanitizerFlag_Address) lb_add_attribute_to_proc(m, p->value, "sanitize_address");
		lb_begin_procedure_body(p);
		auto args = array_make<lbValue>(temporary_allocator());
		auto string_cleanups = array_make<lbValue>(temporary_allocator());
		isize index = uuid_result ? 1 : 0;
		for (isize i = 0; i < original->Proc.param_count; i++) {
			Type *param_type = original->Proc.params->Tuple.variables[i]->type;
			lbValue value = {};
			if (!is_type_enum(param_type) || swift_export_enum_tag_type(param_type)) {
				value = lb_emit_load(p, lb_find_value_from_entity(m, tuple->Tuple.variables[index++]));
			}
			if (is_swift_uuid_type(param_type)) {
				value = lb_swift_export_uuid_read(p, param_type, value);
			} else if (Type *element = swift_export_optional_element(param_type)) {
				lbValue tag = {};
				if (type_size_of(element) == 8) tag = lb_emit_load(p, lb_find_value_from_entity(m, tuple->Tuple.variables[index++]));
				value = lb_swift_optional_read(p, param_type, element, value, tag);
			} else if (param_type == t_string) {
				lbValue object = lb_emit_load(p, lb_find_value_from_entity(m, tuple->Tuple.variables[index++]));
				lbValue borrow = lb_lookup_runtime_procedure(m, str_lit("swift_string_borrow"));
				Type *ptr = base_type(borrow.type)->Proc.params->Tuple.variables[0]->type;
				lbAddr native = lb_add_local_generated(p, type_deref(ptr), false);
				lb_emit_store(p, lb_emit_struct_ep(p, native.addr, 0), value);
				lb_emit_store(p, lb_emit_struct_ep(p, native.addr, 1), object);
				value = lb_emit_call(p, borrow, array_make_from_ptr(&native.addr, 1, 1));
				array_add(&string_cleanups, object);
				array_add(&string_cleanups, value);
			} else if (is_type_enum(param_type)) {
				value = lb_swift_export_enum(p, param_type, value, false);
			} else if (is_type_slice(param_type)) {
				lbValue count = lb_emit_load(p, lb_find_value_from_entity(m, tuple->Tuple.variables[index++]));
				lbAddr slice = lb_add_local_generated(p, param_type, false);
				lbValue data = lb_emit_conv(p, value, alloc_type_multi_pointer(base_type(param_type)->Slice.elem));
				lb_fill_slice(p, slice, data, count);
				value = lb_addr_load(p, slice);
			}
			array_add(&args, value);
		}
		lbValue result = lb_emit_call(p, lb_find_procedure_value_from_entity(m, exported.entity), args);
		for (isize i = 0; i < string_cleanups.count; i += 2) {
			lb_emit_runtime_call(p, "swift_string_end_borrow", array_slice(string_cleanups, i, i+2));
		}
		if (optional_result) {
			bool forwarded = type_size_of(optional_result) == 8 && original->Proc.param_count &&
			                 lb_swift_optional_forwards_input(m, exported.entity, result_type);
			result = lb_swift_optional_write(p, result, optional_result, native_result, forwarded);
		}
		if (is_type_enum(result_type)) result = lb_swift_export_enum(p, result_type, result, true);
		if (uuid_result) {
			lbValue destination = lb_emit_load(p, lb_find_value_from_entity(m, tuple->Tuple.variables[0]));
			lb_swift_export_uuid_initialize(p, destination, result);
		}
		if (native_result) {
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
