package swift_import_test

import "base:runtime"
import "base:intrinsics"
import "core:mem"
import "core:strings"
import "core:time"
import swift "core:sys/darwin/Swift"
import cf "core:sys/darwin/CoreFoundation"
foreign import fixture "swift:fixture/SwiftImportFixture"

array_ready, array_go: int

array_worker :: proc "c" (_: rawptr) -> rawptr {
	context = runtime.default_context()
	intrinsics.atomic_add(&array_ready, 1)
	for intrinsics.atomic_load(&array_go) == 0 {}
	for i in 0..<128 {
		words := []u64{u64(i), 17}
		native := swift.array_from_odin(words) or_else panic("Concurrent array")
		output := swift.array_to_odin(native, u64) or_else panic("Concurrent copy")
		swift.array_destroy(native)
		assert(output[0] == u64(i) && output[1] == 17)
		delete(output)
		texts := []string{"concurrent heap string: café 🦉", "short"}
		native_texts := swift.array_from_odin(texts) or_else panic("Concurrent strings")
		copied := swift.array_to_odin(native_texts, string) or_else panic("Concurrent text copy")
		swift.array_destroy(native_texts)
		for text, j in copied { assert(text == texts[j]); delete(text) }
		delete(copied)
	}
	return nil
}

check_array_concurrency :: proc() {
	workers: [8]rawptr
	for &worker in workers { assert(pthread_create(&worker, nil, array_worker, nil) == 0) }
	for intrinsics.atomic_load(&array_ready) != len(workers) {}
	intrinsics.atomic_store(&array_go, 1)
	for worker in workers { assert(pthread_join(worker, nil) == 0) }
}

array_calls: int

array_received :: proc(task: swift.Task, values: []u64, ok: bool) {
	expected := take_expected(task)
	assert(ok && len(values) == 4)
	for value, i in values { assert(value == u64(i)+expected) }
	delete(values)
	array_calls += 1
}

array_failed :: proc(task: swift.Task, values: []u64, ok: bool) {
	_ = take_expected(task)
	assert(!ok && len(values) == 0)
	array_calls += 1
}

array_throwing :: proc(task: swift.Task, values: []u64, error: swift.Error, ok: bool) {
	expected := take_expected(task)
	if expected == 0 {
		assert(!ok && error != nil && len(values) == 0)
		swift.error_release(error)
	} else {
		assert(ok && error == nil && len(values) == 4)
		for value, i in values { assert(value == u64(i)+expected) }
		delete(values)
	}
	array_calls += 1
}

check_arrays :: proc() {
	state := Value_Allocator{backing = context.allocator, remaining = -1}
	context.allocator = mem.Allocator{procedure = value_allocator, data = &state}
	// Inputs need no Odin allocation; a nonempty scalar output needs one.
	before := state.allocations
	native := swift.array_from_odin([]u64{7, 11}) or_else panic("Native allocation")
	assert(state.allocations == before)
	copied := swift.array_to_odin(native, u64) or_else panic("Odin allocation")
	assert(state.allocations == before+1)
	swift.array_destroy(native)
	delete(copied)
	{
		context.allocator = mem.nil_allocator()
		failed, ok := fixture.array_words([]u64{1}, 1)
		assert(!ok && len(failed) == 0)
		failed_texts, text_ok := fixture.echo_texts([]string{"text"})
		assert(!text_ok && len(failed_texts) == 0)
		empty, empty_ok := fixture.array_words(nil, 1)
		assert(empty_ok && len(empty) == 0)
	}
	// Optimized Swift may return static literal storage with distinct metadata.
	for _ in 0..<4 {
		literal := fixture.array_literal() or_else panic("Static array")
		assert(len(literal) == 4 && literal[0] == 7 && literal[3] == 23)
		changed := fixture.array_words(literal, 1) or_else panic("Dynamic array after static")
		assert(changed[0] == 8 && changed[3] == 24)
		delete(changed)
		delete(literal)
	}
	for count in ([5]int{0, 1, 4, 1024, 65536}) {
		input := make([]u64, count)
		for &value, i in input { value = u64(i) }
		output := fixture.array_words(input, 17) or_else panic("Array conversion")
		assert(len(output) == len(input))
		for value, i in output { assert(value == input[i]+17) }
		if count > 0 {
			assert(raw_data(output) != raw_data(input))
			output[0] = 99
			assert(input[0] == 0)
			round_trip := fixture.array_words(output, 1) or_else panic("Modified round trip")
			assert(round_trip[0] == 100 && output[0] == 99)
			delete(round_trip)
		}
		delete(output)
		delete(input)
	}
	// Native capacity includes usable allocation slack. Compare growth against
	// Swift construction, including allocators that give no slack (e.g. ASan).
	for count in ([8]int{1, 2, 3, 15, 16, 17, 32, 1024}) {
		input := make([]u64, count)
		for extra in ([3]u64{1, 16, 65}) {
			holder := fixture.GrowingArray_init(input) or_else panic("Growing array")
			assert(fixture.GrowingArray_capacity(holder) == fixture.array_native_capacity(u64(count)))
			moves := fixture.GrowingArray_append(holder, extra)
			assert(moves == fixture.array_native_growth(u64(count), extra))
			grown := fixture.GrowingArray_values(holder) or_else panic("Grown result")
			fixture.GrowingArray_destroy(holder)
			assert(len(grown) == count+int(extra))
			for value, i in grown { assert(value == (i < count ? 0 : u64(i-count))) }
			delete(grown)
		}
		delete(input)
	}
	bridged := fixture.array_bridged_texts() or_else panic("Bridged strings")
	assert(len(bridged) == 1 && bridged[0] == "日本語 🦉 café embedded\x00zero and a longer string")
	delete(bridged[0])
	delete(bridged)
	signed := []i64{min(i64), -1, 0, max(i64)}
	signed_copy := fixture.array_signed(signed) or_else panic("Signed array")
	for value, i in signed_copy { assert(value == signed[i]) }
	delete(signed_copy)
	doubles := []f64{-0.0, 1.25, -1e200, transmute(f64)u64(0x7ff8_0000_0000_1234)}
	double_copy := fixture.array_doubles(doubles) or_else panic("Double array")
	for value, i in double_copy { assert(transmute(u64)value == transmute(u64)doubles[i]) }
	delete(double_copy)

	texts := []string{"", "ascii", "café", "🦉", "e\u0301", "a\x00b", "a long string whose storage cannot be inline"}
	text_copy := fixture.echo_texts(texts) or_else panic("String array round trip")
	assert(len(text_copy) == len(texts))
	for text, i in text_copy { assert(text == texts[i]); delete(text) }
	delete(text_copy)
	for bad in 0..<len(texts) {
		input_texts := make([]string, len(texts))
		copy(input_texts, texts)
		input_texts[bad] = "\xff"
		failed_texts, valid := fixture.echo_texts(input_texts)
		assert(!valid && len(failed_texts) == 0)
		delete(input_texts)
	}
	// Fail each output allocation, including after an initialized prefix.
	for remaining in 0..<len(texts) {
		state.remaining = remaining
		failed_texts, valid := fixture.echo_texts(texts)
		assert(!valid && len(failed_texts) == 0)
		assert(state.allocations == state.frees)
	}
	state.remaining = -1
	// Exercise a retained Swift copy and copy-on-write after crossing both ways.
	original := strings.clone(texts[len(texts)-1])
	retained := fixture.ArrayHolder_init([]string{original}) or_else panic("Retained array")
	mem.set(raw_data(original), 0xff, len(original))
	delete(original)
	first := fixture.ArrayHolder_values(retained) or_else panic("Retained result")
	second := fixture.ArrayHolder_changed(retained) or_else panic("Modified result")
	for _ in 0..<65 { assert(fixture.ArrayHolder_append(retained, "appended")) }
	grown := fixture.ArrayHolder_values(retained) or_else panic("Array growth")
	assert(len(grown) == 66 && grown[0] == texts[len(texts)-1])
	for text in grown { delete(text) }
	delete(grown)
	fixture.ArrayHolder_destroy(retained)
	assert(first[0] == texts[len(texts)-1] && second[0] == "changed")
	for text in first { delete(text) }
	for text in second { delete(text) }
	delete(first)
	delete(second)

	input := make([]u64, 4)
	for &value, i in input { value = u64(i) }
	for i in 1..=8 {
		task := fixture.array_words_later(input, u64(i), array_received) or_else panic("Array task")
		track_task(task, u64(i))
	}
	for delta in ([2]u64{0, 9}) {
		task := fixture.array_words_throwing(input, delta, array_throwing) or_else panic("Throwing array task")
		track_task(task, delta)
	}
	for &value in input { value = max(u64) }
	delete(input)
	begin := time.tick_now()
	for array_calls != 10 {
		cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
		assert(time.tick_since(begin) < 10*time.Second)
	}
	// Failure after a successful async start is delivered through completion.
	task := fixture.array_words_later([]u64{1, 2}, 1, array_failed) or_else panic("Array failure task")
	track_task(task)
	state.remaining = 0
	failed, ok := fixture.array_words([]u64{1, 2}, 1)
	assert(!ok && len(failed) == 0)
	for array_calls != 11 {
		cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
		assert(time.tick_since(begin) < 10*time.Second)
	}
	state.remaining = -1
	task = fixture.echo_texts_later(texts, array_text_failed) or_else panic("Text failure task")
	track_task(task)
	state.remaining = 2
	for array_calls != 12 {
		cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
		assert(time.tick_since(begin) < 10*time.Second)
	}
	state.remaining = -1
	assert(state.allocations == state.frees)
}

array_text_failed :: proc(task: swift.Task, values: []string, ok: bool) {
	_ = take_expected(task)
	assert(!ok && len(values) == 0)
	array_calls += 1
}
