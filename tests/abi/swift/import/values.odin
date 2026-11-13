package swift_import_test

import "core:mem"
import "core:time"
import cf "core:sys/darwin/CoreFoundation"
import swift "core:sys/darwin/Swift"
foreign import fixture "swift:fixture/SwiftImportFixture"

Value_Allocator :: struct {
	backing: mem.Allocator,
	allocations, frees: int,
	remaining: int,
}

Allocation_Header :: struct {
	original: rawptr,
	size: int,
	guard: u64,
}

// Canaries surround each allocation independently of the imported value's
// runtime size. The recorded allocator must also be used when context changes.
value_allocator :: proc(
	data: rawptr, mode: mem.Allocator_Mode, size, alignment: int,
	old_memory: rawptr, old_size: int, loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	state := cast(^Value_Allocator)data
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if state.remaining == 0 { return nil, .Out_Of_Memory }
		if state.remaining > 0 { state.remaining -= 1 }
		align := max(alignment, align_of(Allocation_Header))
		prefix := mem.align_forward_int(size_of(Allocation_Header), align)
		original, err := mem.alloc(prefix + size + size_of(u64), align, state.backing)
		if err != .None { return nil, err }
		value := rawptr(uintptr(original) + uintptr(prefix))
		header := cast(^Allocation_Header)(uintptr(value) - size_of(Allocation_Header))
		header^ = {original, size, GUARD}
		guard := GUARD
		mem.copy(rawptr(uintptr(value) + uintptr(size)), &guard, size_of(guard))
		state.allocations += 1
		return (cast([^]byte)value)[:size], .None
	case .Free:
		if old_memory == nil { return nil, .None }
		header := cast(^Allocation_Header)(uintptr(old_memory) - size_of(Allocation_Header))
		guard: u64
		mem.copy(&guard, rawptr(uintptr(old_memory) + uintptr(header.size)), size_of(guard))
		assert(header.guard == GUARD && guard == GUARD)
		state.frees += 1
		mem.free(header.original, state.backing)
		return nil, .None
	case:
		return nil, .Mode_Not_Implemented
	}
}

value_calls: int
error_calls: int
iterator_calls: int

test_iterator: fixture.ValueSequence_Iterator
mutating_value: fixture.Value

iterator_received :: proc(task: swift.Task, result: Maybe(fixture.Validation_Value), ok: bool) {
	_ = take_expected(task)
	assert(ok)
	iterator := test_iterator
	defer fixture.Optional_Validation_Value_destroy(result)
	iterator_calls += 1
	if iterator_calls == 1 {
		validation, present := result.?
		assert(present)
		item := validation.(fixture.Validation_Value_Valid)
		assert(fixture.Value_value(item.value) == 73)
		next, started := fixture.ValueSequence_Iterator_next(iterator, iterator_received)
		assert(started)
		track_task(next)
	} else {
		assert(iterator_calls == 2 && result == nil)
		fixture.ValueSequence_Iterator_destroy(iterator)
	}
}

check_enums :: proc() {
	named := fixture.named_payload() or_else panic("Named generic payload")
	item := named.(fixture.NamedPayload_Value_Named)
	payload := fixture.GenericTypeParam_copy(item.value) or_else panic("Independent payload")
	fixture.NamedPayload_Value_destroy(named)
	assert(fixture.GenericTypeParam_first(payload) == 11 && fixture.GenericTypeParam_last(payload) == 55)
	fixture.GenericTypeParam_destroy(payload)
	void_value := fixture.named_void() or_else panic("Nominal Void result")
	assert(fixture.Void_value(void_value) == 73)
	fixture.Void_destroy(void_value)
	fixture.actual_void()

	for selection in 0..<3 {
		result := fixture.value_outcome(u64(selection)) or_else panic("Enum result")
		switch item in result {
		case fixture.ValueOutcome_Accepted:
			assert(selection == 1)
			value := fixture.Value_copy(item.value) or_else panic("Independent payload")
			fixture.ValueOutcome_destroy(result)
			assert(fixture.Value_value(value) == 73)
			fixture.Value_destroy(value)
		case fixture.ValueOutcome_Pending:
			assert(selection == 0)
			fixture.ValueOutcome_destroy(result)
		case fixture.ValueOutcome_Cancelled:
			assert(selection == 2)
			fixture.ValueOutcome_destroy(result)
		case fixture.ValueOutcome_Unknown:
			panic("Unexpected new case")
		}
	}
	result := fixture.value_outcome(99) or_else panic("Evolved enum result")
	when #config(EVOLVED_VALUE_ENUM, false) {
		_, unknown := result.(fixture.ValueOutcome_Unknown)
		assert(unknown && fixture.read_outcome(result) == 33)
		kept := fixture.ValueOutcome_copy(result) or_else panic("Unknown copy")
		fixture.ValueOutcome_destroy(result)
		result = fixture.echo_outcome(kept) or_else panic("Unknown round trip")
		fixture.ValueOutcome_destroy(kept)
		assert(fixture.read_outcome(result) == 33)
	} else {
		_, pending := result.(fixture.ValueOutcome_Pending)
		assert(pending)
	}
	fixture.ValueOutcome_destroy(result)
	assert(fixture.live_value_count() == 0)
}

check_error :: proc(task: swift.Task, error: swift.Error) {
	expected := take_expected(task)
	assert((error == nil) == (expected != 0))
	if error != nil {
		copy := swift.error_retain(error)
		swift.error_release(error)
		swift.error_release(copy)
	}
	error_calls += 1
}

checked_value :: proc(task: swift.Task, value: fixture.Value, error: swift.Error) {
	if error == nil {
		assert(fixture.Value_value(value) == expected_values[task])
		fixture.Value_destroy(value)
	} else {
		assert(value == nil)
	}
	check_error(task, error)
}

checked_scalar :: proc(task: swift.Task, value: u64, error: swift.Error) {
	assert(value == expected_values[task])
	check_error(task, error)
}

value_finished :: proc(task: swift.Task, value: fixture.Value) {
	_ = take_expected(task)
	assert(task != nil && pthread_main_np() == 1)
	assert(context.user_ptr == &value_calls)
	assert(fixture.Value_value(value) == 26)
	// All copied input values have been destroyed before this callback. Only
	// the owned result and the mutating receiver remain alive.
	fixture.Value_destroy(value)
	value_calls += 1
}

read_finished :: proc(task: swift.Task, result: u64) {
	assert(take_expected(task) == 73 && result == 17)
	value_calls += 1
}

mutation_finished :: proc(task: swift.Task) {
	_ = take_expected(task)
	assert(fixture.Value_value(mutating_value) == 26)
	fixture.Value_destroy(mutating_value)
	value_calls += 1
}

check_values :: proc() {
	assert(fixture.live_value_count() == 0)
	state := Value_Allocator{backing = context.allocator, remaining = -1}
	allocator := mem.Allocator{procedure = value_allocator, data = &state}
	context.allocator = allocator
	a := fixture.Value_init(17) or_else panic("Value initialization failed")
	b := fixture.Value_copy(a) or_else panic("Value copy failed")
	assert(fixture.live_value_count() == 1)
	fixture.Value_increment(a, 9)
	assert(fixture.read_value(a) == 26 && fixture.read_value(b) == 17)
	fixture.Value_destroy(a)
	// Destruction must use the allocator saved at allocation time, even when
	// the current context refuses allocations and frees.
	{
		context.allocator = mem.panic_allocator()
		fixture.Value_destroy(b)
	}
	assert(fixture.live_value_count() == 0 && state.allocations == state.frees)
	check_enums()
	// Constructors consume nontrivial arguments. The binding must copy both
	// the resilient value and the string, then relinquish only those copies.
	a = fixture.Value_init(73) or_else panic("Constructor input")
	for remaining in 0..<2 {
		state.remaining = remaining
		failed_pair, initialized := fixture.ValuePair_init(a, "A constructor-owned string longer than inline storage")
		assert(!initialized && failed_pair == nil)
		assert(fixture.Value_value(a) == 73 && state.allocations-state.frees == 1)
	}
	state.remaining = -1
	pair := fixture.ValuePair_init(a, "A constructor-owned string longer than inline storage") or_else panic("Consuming initializer")
	fixture.Value_destroy(a)
	b = fixture.ValuePair_value(pair) or_else panic("Owned field")
	title := fixture.ValuePair_title(pair) or_else panic("String field")
	fixture.ValuePair_destroy(pair)
	assert(fixture.Value_value(b) == 73 && title == "A constructor-owned string longer than inline storage")
	fixture.Value_destroy(b)
	delete(title)
	assert(fixture.live_value_count() == 0 && state.allocations == state.frees)

	nested := fixture.Value_Nested_init(73) or_else panic("Nested initialization failed")
	assert(fixture.Value_Nested_value(nested) == 73)
	fixture.Value_Nested_destroy(nested)

	a = fixture.Value_initial() or_else panic("Static getter failed")
	b = fixture.make_value(9) or_else panic("Value factory failed")
	// Fail each allocation in an async start: first input, second input,
	// then the uninitialized result. No completion or leaked copy is allowed.
	for remaining in 0..<3 {
		state.remaining = remaining
		task, ok := fixture.add_values_later(a, b, value_finished)
		assert(!ok && task == nil && value_calls == 0)
		assert(fixture.live_value_count() == 2)
		assert(state.allocations - state.frees == 2)
	}
	state.remaining = -1
	context.user_ptr = &value_calls
	task, ok := fixture.add_values_later(a, b, value_finished)
	assert(ok)
	track_task(task)
	task, ok = fixture.Value_adding_later(a, 9, value_finished)
	assert(ok)
	track_task(task)
	task, ok = fixture.Value_read_later(a, read_finished)
	assert(ok)
	track_task(task, 73)
	for amount in ([2]u64{0, 9}) {
		expected := u64(0)
		if amount != 0 { expected = 26 }
		task, ok = fixture.Value_checked_adding_later(a, amount, checked_value)
		assert(ok)
		track_task(task, expected)
		task, ok = fixture.checked_later(amount, checked_scalar)
		assert(ok)
		track_task(task, amount)
		task, ok = fixture.checked_void_later(amount, check_error)
		assert(ok)
		track_task(task, amount)
	}
	fixture.Value_destroy(a)
	fixture.Value_destroy(b)
	// A mutating receiver is borrowed, so changes must reach the original.
	a = fixture.make_value(17) or_else panic("Value factory failed")
	mutating_value = a
	task, ok = fixture.Value_increment_later(a, 9, mutation_finished)
	assert(ok)
	track_task(task)
	sequence := fixture.ValueSequence_current() or_else panic("Sequence getter")
	iterator := fixture.ValueSequence_make_iterator(sequence) or_else panic("Iterator")
	fixture.ValueSequence_destroy(sequence)
	test_iterator = iterator
	task, ok = fixture.ValueSequence_Iterator_next(iterator, iterator_received)
	assert(ok)
	track_task(task)
	begin := time.tick_now()
	for value_calls != 4 || error_calls != 6 || iterator_calls != 2 {
		cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
		assert(time.tick_since(begin) < 10*time.Second)
	}
	assert(fixture.live_value_count() == 0)
	assert(state.allocations == state.frees)
}
