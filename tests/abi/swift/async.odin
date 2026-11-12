package swift_abi

import "core:time"
import cf "core:sys/darwin/CoreFoundation"
import swift "core:sys/darwin/Swift"

// The Swift fixture checks these sizes and alignments before initializing them.
Fixture_Value :: [2]u64

foreign {
	@(link_name="$s15SwiftABIFixture10asyncProbeyAA05AsyncD0VSpys6UInt64VG_AFtF")
	init_probe :: proc "swift" (#swift_result probe: ^Fixture_Value, value: ^u64, delta: u64) ---
	@(link_name="$s15SwiftABIFixture13snapshotValueys6UInt64VAA13AsyncSnapshotVF")
	snapshot_value :: proc "swift" (value: ^Fixture_Value) -> u64 ---

	@(link_name="$s15SwiftABIFixture10AsyncProbeV9incrementyyYaF")
	increment :: proc "swift/async" (#swift_async ctx: ^swift.Async_Context, #swift_self receiver: rawptr) ---
	@(link_name="$s15SwiftABIFixture10AsyncProbeV9incrementyyYaFTu")
	increment_descriptor: swift.Async_Descriptor
	@(link_name="$s15SwiftABIFixture10AsyncProbeV8snapshotAA0C8SnapshotVyYaF")
	snapshot :: proc "swift/async" (result: rawptr, #swift_async ctx: ^swift.Async_Context, #swift_self receiver: rawptr) ---
	@(link_name="$s15SwiftABIFixture10AsyncProbeV8snapshotAA0C8SnapshotVyYaFTu")
	snapshot_descriptor: swift.Async_Descriptor

	pthread_main_np :: proc "c" () -> i32 ---
}

Request :: struct {
	probe:    Fixture_Value,
	result:   Fixture_Value,
	value:    u64,
	expected: u64,
	calls:    int,
}

incremented :: proc(task: swift.Task) {
	request := cast(^Request)context.user_ptr
	assert(task != nil)
	assert(context.user_ptr == request)
	assert(pthread_main_np() == 1)
	assert(request.value == request.expected)
	request.calls += 1
}

received_snapshot :: proc(task: swift.Task) {
	request := cast(^Request)context.user_ptr
	assert(task != nil)
	assert(context.user_ptr == request)
	assert(pthread_main_np() == 1)
	assert(snapshot_value(&request.result) == request.expected)
	request.calls += 1
}

main :: proc() {
	a := Request{value = 17, expected = 26}
	b := Request{value = 41, expected = 45}
	init_probe(&a.probe, &a.value, 9)
	init_probe(&b.probe, &b.value, 4)
	{
		context.user_ptr = &a
		task, started := swift.async_call(increment, &increment_descriptor, &a.probe, incremented)
		assert(started)
		swift.task_release(task)
	}
	{
		context.user_ptr = &b
		task, started := swift.async_call(snapshot, &snapshot_descriptor, &b.probe, &b.result, received_snapshot)
		assert(started)
		swift.task_release(task)
	}
	assert(a.calls == 0 && b.calls == 0)

	start := time.tick_now()
	for a.calls == 0 || b.calls == 0 {
		cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
		assert(time.tick_since(start) < 5*time.Second, "Timed out waiting for Swift callbacks")
	}
	assert(a.calls == 1 && b.calls == 1)
	assert(a.value == 26 && b.value == 41)
}
