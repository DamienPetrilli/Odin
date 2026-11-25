package swift_import_test

foreign import fixture "swift:fixture/SwiftImportFixture"
import swift "core:sys/darwin/Swift"
import "core:time"
import "base:runtime"
import cf "core:sys/darwin/CoreFoundation"

foreign {
	pthread_main_np :: proc "c" () -> i32 ---
	alarm :: proc "c" (seconds: u32) -> u32 ---
}

GUARD :: u64(0xfedc_ba98_7654_3210)

// Application-owned data keyed by a native handle. No generated correlation ID
// or user payload is stored in the Swift task. Starts and callbacks here share
// the main thread, so registration precedes callback delivery.
expected_values: map[swift.Task]u64

track_task :: proc(task: swift.Task, expected: u64 = 0) {
	assert(task != nil)
	_, found := expected_values[task]
	assert(!found)
	expected_values[task] = expected
}

take_expected :: proc(task: swift.Task) -> u64 {
	expected, found := expected_values[task]
	assert(found)
	delete_key(&expected_values, task)
	// Drop the start's owned reference. Execution still protects the borrowed
	// callback handle until the callback and root continuation return.
	swift.task_release(task)
	return expected
}

Request :: struct {
	before: u64,
	task: swift.Task,
	expected: u64,
	value: u64,
	calls: int,
	after: u64,
}

finished :: proc(task: swift.Task, result: u64) {
	request := cast(^Request)context.user_ptr
	assert(pthread_main_np() == 1)
	assert(task == request.task)
	assert(request.before == GUARD && request.after == GUARD)
	assert(request.calls == 0 && result == request.expected)
	request.value = result
	request.calls += 1
}

float_calls, yield_calls: int
float_finished :: proc(task: swift.Task, result: f64) {
	assert(pthread_main_np() == 1 && result == -40.75)
	assert(take_expected(task) == 0)
	float_calls += 1
}
yielded :: proc(task: swift.Task) {
	assert(pthread_main_np() == 1)
	assert(take_expected(task) == 0)
	yield_calls += 1
}

start :: proc(request: ^Request, value: u64) -> bool {
	context.user_ptr = request
	delta := u64(9)
	task := fixture.add_later(value, delta, finished) or_return
	request.task = task
	return true
}

failed_start :: proc() -> bool {
	callback: proc(swift.Task, u64)
	task := fixture.add_later(1, 2, callback) or_return
	_ = task
	panic("Rejected start did not return")
}

main :: proc() {
	#assert(#defined(fixture.future_if_available))
	#assert(!#defined(fixture.future))
	assert(fixture.future_if_available() == nil)
	increment := fixture.versioned_increment_if_available()
	assert((increment != nil) == fixture.has_versioned_increment())
	if increment != nil {
		assert(increment(41) == 42)
	}
	expected_prices := [?]swift.Decimal{
		{}, {123, 0, false}, {299, -2, false}, {5, -3, true},
		{1234, -3, false}, {123, -1, false}, {12345678901234567890123456789012345678, 0, false},
		{1, -128, true}, {1, 127, false},
	}
	for expected, i in expected_prices {
		price := fixture.fixture_price(u64(i)) or_else panic("Finite decimal")
		assert(price == expected)
		optional := fixture.optional_price(u64(i)) or_else panic("Finite optional decimal")
		assert(optional.? == expected)
	}
	nan, finite := fixture.fixture_price(9)
	assert(!finite && nan == {})
	invalid, finite_optional := fixture.optional_price(9)
	assert(!finite_optional && invalid == nil)
	absent, read := fixture.optional_price(10)
	assert(read && absent == nil)
	when (ODIN_PLATFORM_SUBTARGET == .Default && ODIN_MINIMUM_OS_VERSION >= 13_00_00) ||
	     (ODIN_PLATFORM_SUBTARGET != .Default && ODIN_MINIMUM_OS_VERSION >= 16_00_00) {
		for code in ([4]string{"USD", "", "KWD", "unusually-long-currency"}) {
			currency := fixture.optional_currency(code) or_else panic("Optional currency")
			defer fixture.Optional_Locale_Currency_destroy(currency)
			v, present := currency.?
			assert(present == (code != ""))
			if present {
				assert(string(v) == code)
				copy := fixture.Locale_Currency_copy(v) or_else panic("Independent currency")
				defer fixture.Locale_Currency_destroy(copy)
				assert(copy == v && raw_data(string(copy)) != raw_data(string(v)))
			}
			echo := fixture.currency_identifier(currency) or_else panic("Currency input")
			defer fixture.Optional_String_destroy(echo)
			text, got_text := echo.?
			assert(got_text == present && text == code)
		}
	}
	for code in ([3]string{"KWD", "", "unexpected-long-currency-identifier"}) {
		style := fixture.fixture_currency(code) or_else panic("Currency format")
		{
			context.allocator = runtime.nil_allocator()
			str, ok := fixture.Decimal_FormatStyle_Currency_currency_code(style)
			assert(str == "" && ok == (len(code) == 0))
		}
		text := fixture.Decimal_FormatStyle_Currency_currency_code(style) or_else panic("Currency code")
		fixture.Decimal_FormatStyle_Currency_destroy(style)
		assert(text == code)
		delete(text)
	}
	empty := fixture.fixture_bytes(0) or_else panic("Empty Data")
	assert(len(empty) == 0)
	delete(empty)
	small := fixture.fixture_bytes(1) or_else panic("Inline Data")
	assert(len(small) == 3 && small[0] == 0 && small[1] == 255 && small[2] == 0)
	delete(small)
	before := fixture.released_buffer_count()
	{
		context.allocator = runtime.nil_allocator()
		bytes, ok := fixture.fixture_bytes(2)
		assert(!ok && bytes == nil)
	}
	for iteration in 0..<4 {
		bytes := fixture.fixture_bytes(2) or_else panic("Sliced Data")
		assert(len(bytes) == 484 && fixture.released_buffer_count() == before+u64(iteration)+2)
		for b, i in bytes { assert(b == u8((i+17) % 256)) }
		delete(bytes)
	}
	low, ready := fixture.Namespace_bounds(min(int))
	assert(low == min(int) && !ready)
	low, ready = fixture.Namespace_empty_bounds()
	assert(low == 0 && !ready)
	a, b, c, d, valid := fixture.Namespace_wide_bounds(max(u64))
	assert(a == max(u64) && b == 0 && c == (a ~ 17) && d == a-4 && valid)
	// Bound the entire process, including worker joins and runtime callbacks.
	_ = alarm(60)
	defer alarm(0)
	expected_values = make(map[swift.Task]u64)
	defer delete(expected_values)
	check_array_concurrency()
	check_values()
	check_projected_enums()
	check_plain_enums()
	check_strings()
	check_async_strings()
	check_arrays()
	check_value_arrays()
	check_records()
	check_mixed_records()
	check_dates()
	check_uuids()
	check_sets()
	check_owned_records()
	check_owned_tuples()
	check_error_inspection()
	check_typed_errors()
	check_scalars()
	check_tasks()
	assert(fixture.prior_value(41) == 41)
	assert(fixture.add(17, 9) == 26)
	assert(fixture.back_deployed_increment(41) == 42)
	assert(fixture.add(0xffff_ffff_ffff_ffff, 9) == 8)
	assert(fixture.mixed(-41, 0.25) == -40.75)
	assert(!failed_start())

	requests: [32]Request
	for &request, i in requests {
		value := GUARD + u64(i)
		request = {before = GUARD, expected = value+9, after = GUARD}
		assert(start(&request, value))
		assert(request.calls == 0)
		for j in 0..<i { assert(request.task != requests[j].task) }
	}
	task := fixture.mixed_later(-41, 0.25, float_finished)
	track_task(task)
	task = fixture.yield_once(yielded)
	track_task(task)
	check_method()

	begin := time.tick_now()
	for {
		complete := float_calls == 1 && yield_calls == 1
		for request in requests { complete &&= request.calls == 1 }
		if complete { break }
		cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
		assert(time.tick_since(begin) < 10*time.Second, "Swift import timed out")
	}
	for request in requests {
		assert(request.value == request.expected)
		assert(request.before == GUARD && request.after == GUARD)
		swift.task_release(request.task)
	}
	assert(len(expected_values) == 0)
}

method_calls: int
method_finished :: proc(task: swift.Task) {
	assert(take_expected(task) == 73)
	method_calls += 1
}

check_method :: proc() {
	address := fixture.make_counter(73)
	defer fixture.destroy_counter(address)
	receiver := fixture.Counter(rawptr(uintptr(address)))
	task := fixture.Counter_wait(receiver, method_finished)
	track_task(task, 73)
	failed, ok := fixture.Counter_wait(nil, method_finished)
	assert(!ok && failed == nil)
	begin := time.tick_now()
	for method_calls != 1 {
		cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
		assert(time.tick_since(begin) < 10*time.Second, "Swift method timed out")
	}
}
