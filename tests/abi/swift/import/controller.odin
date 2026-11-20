package swift_names_test

foreign import fixture "swift:fixture/SwiftNamesFixture"
import "base:intrinsics"
import cf "core:sys/darwin/CoreFoundation"
import swift "core:sys/darwin/Swift"
import "core:time"
import "core:mem"
import NS "core:sys/darwin/Foundation"
import UI "vendor:darwin/UIKit"

controller_calls: int
controller_result: uint

controller_received :: proc(_: swift.Task, result: uint) {
	controller_result = result
	controller_calls += 1
}

test_controller :: proc(cancel: bool) {
	table := intrinsics.objc_send(^NS.HashTable, NS.HashTable, "alloc")
	table = NS.HashTable_initWithOptions(table, NS.PointerFunctionsOptions_WeakMemory, 1)
	defer NS.ObjectProtocol_release(cast(^NS.ObjectProtocol)table)
	{
		NS.scoped_autoreleasepool()
		controller := intrinsics.objc_send(^UI.ViewController, UI.ViewController, "new")
		NS.HashTable_addObject(table, cast(NS.id)controller)
		address := uintptr(controller)
		count := controller_calls
		{
			context.allocator = mem.nil_allocator()
			missing, ok := fixture.controller_record(controller, proc(_: swift.Task, _: fixture.UInt64) {
				panic("A failed start cannot complete")
			})
			assert(!ok && missing == nil)
		}
		task: swift.Task
		if cancel {
			task = fixture.controller_address_presenting_options(controller, []u64{5}, controller_received) or_else panic("Controller start")
			swift.task_cancel(task)
		} else {
			task = fixture.controller_address_presenting_options(controller, controller_received) or_else panic("Controller start")
		}
		NS.ObjectProtocol_release(cast(^NS.ObjectProtocol)controller)
		swift.task_release(task)
		started := time.tick_now()
		for controller_calls == count && time.tick_since(started) < 10*time.Second {
			cf.RunLoopRunInMode(cf.kRunLoopDefaultMode, 0.01, false)
		}
		assert(controller_calls == count+1)
		assert(controller_result == (0 if cancel else uint(address)))
	}
	assert(NS.HashTable_anyObject(table) == nil)
}
