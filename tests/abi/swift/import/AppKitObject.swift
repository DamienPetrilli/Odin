import AppKit

@main
struct AppKitObjectTest {
	@MainActor static func main() async throws {
		weak var observed: NSViewController?
		precondition(!start_presenter(nil))
		let address = autoreleasepool {
			let controller = NSViewController()
			observed = controller
			let pointer = Unmanaged.passUnretained(controller).toOpaque()
			precondition(start_presenter(pointer))
			return UInt(bitPattern: pointer)
		}
		precondition(observed != nil)
		let deadline = ContinuousClock.now + .seconds(10)
		while received_presenter() == 0 && ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(1))
		}
		precondition(received_presenter() == address)
		precondition(observed == nil)
	}
}
