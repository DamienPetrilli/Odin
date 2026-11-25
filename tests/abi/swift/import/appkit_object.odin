package appkit_object_test

import "base:runtime"
import swift "core:sys/darwin/Swift"
import AppKit "vendor:darwin/AppKit"
foreign import fixture "swift:../names/fixture/SwiftNamesFixture"

received: uint

@(export)
start_presenter :: proc "c" (controller: ^AppKit.ViewController) -> bool {
	context = runtime.default_context()
	task := fixture.controller_address(controller, proc(_: swift.Task, address: uint) {
		received = address
	}) or_return
	swift.task_release(task)
	return true
}

@(export)
received_presenter :: proc "c" () -> uint { return received }
