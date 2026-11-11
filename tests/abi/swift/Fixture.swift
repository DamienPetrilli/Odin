public func addScalar(_ whole: Int64, _ fraction: Double) -> Double {
	Double(whole) + fraction
}

@frozen public struct Reading: Equatable {
	public var page: Int64
	public var progress: Double

	public init(page: Int64, progress: Double) {
		self.page = page
		self.progress = progress
	}
}

public func advance(_ pages: Int64, _ reading: Reading, _ fraction: Double) -> Reading {
	Reading(page: reading.page + pages, progress: reading.progress + fraction)
}

public func changeInPlace(_ reading: UnsafeMutablePointer<Reading>, _ pages: Int64, _ fraction: Double) -> UnsafeMutablePointer<Reading> {
	reading.pointee = advance(pages, reading.pointee, fraction)
	return reading
}

public func fillBytes(_ output: UnsafeMutablePointer<UInt8>, _ capacity: Int64) -> Int64 {
	guard capacity >= 3 else { return 0 }
	let bytes = UnsafeMutableBufferPointer(start: output, count: 3)
	bytes[0] = 13
	bytes[1] = 29
	bytes[2] = 61
	return 3
}

public typealias ReadingCallback = @convention(thin) (UnsafeMutableRawPointer, Reading) -> Reading

public func callCallback(_ callback: ReadingCallback, _ userData: UnsafeMutableRawPointer, _ reading: Reading) -> Reading {
	callback(userData, reading)
}

private final class CallbackState {
	let deinitCount: UnsafeMutablePointer<Int64>
	var calls: Int64 = 0

	init(_ deinitCount: UnsafeMutablePointer<Int64>) {
		self.deinitCount = deinitCount
	}

	deinit {
		deinitCount.pointee += 1
	}
}

public func makeCallbackState(_ deinitCount: UnsafeMutablePointer<Int64>) -> UnsafeMutableRawPointer {
	Unmanaged.passRetained(CallbackState(deinitCount)).toOpaque()
}

public func retainCallbackState(_ state: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
	Unmanaged<CallbackState>.fromOpaque(state).retain().toOpaque()
}

public func releaseCallbackState(_ state: UnsafeMutableRawPointer) {
	Unmanaged<CallbackState>.fromOpaque(state).release()
}

public func updateCallbackState(_ userData: UnsafeMutableRawPointer, _ reading: Reading) -> Reading {
	let state = Unmanaged<CallbackState>.fromOpaque(userData).takeUnretainedValue()
	state.calls += 1
	return Reading(page: reading.page + state.calls, progress: reading.progress + 0.125)
}
