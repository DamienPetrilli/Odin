package swift_import_test

foreign import fixture "swift:fixture/SwiftImportFixture"
import swift "core:sys/darwin/Swift"
import cf "core:sys/darwin/CoreFoundation"
import "core:time"
import "base:runtime"

// Generated Date metadata must initialize before a dependent global, not just
// before main or an @(init) procedure.
date_at_startup := date_before_main()
date_before_main :: proc "contextless" () -> swift.Date {
	context = runtime.default_context()
	return fixture.echo_date(swift.Date(17.125)) or_else panic("Global Date")
}

Date_Request :: struct {
	expected: Maybe(swift.Date),
	calls: int,
}

date_received :: proc(task: swift.Task, value: fixture.Date) {
	request := cast(^Date_Request)context.user_ptr
	swift.task_release(task)
	assert(value == request.expected.(swift.Date))
	request.calls += 1
}
optional_date_received :: proc(task: swift.Task, value: Maybe(fixture.Date)) {
	request := cast(^Date_Request)context.user_ptr
	swift.task_release(task)
	assert(value == request.expected)
	request.calls += 1
}

check_dates :: proc() {
	assert(date_at_startup == 17.125)
	check_cached_value_layout()
	#assert(fixture.Date == swift.Date)
	#assert(size_of(fixture.Date) == size_of(f64))
	state := Value_Allocator{backing = context.allocator, remaining = -1}
	context.allocator = {procedure = value_allocator, data = &state}
	// Reference and Unix epochs, a subnanosecond, dates outside time.Time's
	// range, and ordinary fractional seconds must survive without rounding.
	for seconds in ([]f64{0, -978_307_200, 0.000_000_000_125, -0.125, 12345.125, -63_114_076_800, 63_113_904_000}) {
		value := fixture.date_from_seconds(seconds) or_else panic("Date construction")
		assert(f64(value) == seconds)
		echo := fixture.echo_date(value) or_else panic("Date round trip")
		assert(echo == value)
		read := fixture.date_seconds(value) or_else panic("Date getter")
		assert(read == seconds)
		optional := fixture.echo_optional_date(value) or_else panic("Optional Date")
		assert(optional.(swift.Date) == value)
		changed := fixture.offset_date(value, 2) or_else panic("Date mutation")
		assert(changed == fixture.Date(seconds+2))
	}
	absent := fixture.echo_optional_date(nil) or_else panic("Absent Date")
	assert(absent == nil)
	input := []fixture.Date{0, -0.125, 63_113_904_000}
	values := fixture.echo_dates(input) or_else panic("Date slice")
	for value, index in values { assert(value == input[index]) }
	delete(values)
	assert(state.allocations == state.frees)

	// Date and its Optional fit runtime-checked synchronous stack storage.
	before := state.allocations
	state.remaining = 0
	exact := fixture.echo_date(fixture.Date(42)) or_else panic("Stack Date")
	assert(exact == 42 && state.allocations == before)
	state.remaining = -1
	// A larger resilient enum exercises the fallback and both failure paths.
	large: fixture.LargeTemporary = fixture.LargeTemporary_Values{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
	for remaining in 0..<3 {
		state.remaining = remaining
		copy, copied := fixture.echo_large_temporary(large)
		assert(copied == (remaining == 2))
		if copied {
			assert(copy.(fixture.LargeTemporary_Values) == large.(fixture.LargeTemporary_Values))
			fixture.LargeTemporary_destroy(copy)
		}
		assert(state.allocations == state.frees)
	}
	// Optional Date also works independently of heap allocation availability.
	for remaining in 0..<5 {
		state.remaining = remaining
		_, _ = fixture.echo_optional_date(fixture.Date(42))
		assert(state.allocations == state.frees)
	}
	state.remaining = -1
	request := Date_Request{expected = fixture.Date(12345.125)}
	context.user_ptr = &request
	_ = fixture.echo_date_later(fixture.Date(12345.125), date_received) or_else panic("Async Date")
	_ = fixture.echo_optional_date_later(fixture.Date(12345.125), optional_date_received) or_else panic("Async Optional Date")
	deadline := time.tick_now()
	for request.calls != 2 && time.tick_since(deadline) < 10*time.Second {
		cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
	}
	assert(request.calls == 2)
	request.expected = nil
	_ = fixture.echo_optional_date_later(nil, optional_date_received) or_else panic("Async absent Date")
	for request.calls != 3 && time.tick_since(deadline) < 10*time.Second {
		cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
	}
	assert(request.calls == 3 && state.allocations == state.frees)
}


check_cached_value_layout :: proc() {
	// Non-POD metadata must retain destruction even though today's Date is POD.
	text :: "A nontrivial native String copied through cached value witnesses 📚"
	native := swift.string_from_odin(text) or_else panic("Native String")
	layout := swift.value_layout(swift.value_metadata(string))
	assert(layout.destroy != nil && layout.inline_temporary)
	temporary: swift.Value_Temporary = ---
	storage := swift.value_temporary_from_layout(&temporary, layout) or_else panic("Cached layout")
	assert(storage == rawptr(&temporary))
	swift.value_initialize_copy(storage, &native, layout.metadata)
	swift.value_deinitialize_from_layout(&native, layout)
	copy := swift.string_to_odin((cast(^swift.Native_String)storage)^) or_else panic("Copied String")
	swift.value_deinitialize_from_layout(storage, layout)
	swift.value_temporary_free(&temporary, storage)
	assert(copy == text)
	delete(copy)
}
