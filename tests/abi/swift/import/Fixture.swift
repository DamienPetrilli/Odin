public func add(_ value: UInt64, _ delta: UInt64) -> UInt64 {
	value &+ delta
}

public func addLater(_ value: UInt64, _ delta: UInt64) async -> UInt64 {
	await Task.yield()
	return value &+ delta
}

public func mixed(_ whole: Int64, fraction: Double) -> Double {
	Double(whole) + fraction
}

public func mixedLater(_ whole: Int64, fraction: Double) async -> Double {
	await Task.yield()
	return Double(whole) + fraction
}

public func yieldOnce() async {
	await Task.yield()
}

// Unsupported declarations must be diagnosed at the importing source.
public func narrow(_ value: UInt32) -> UInt32 { value }
public func generic<T>(_ value: T) -> T { value }
public func throwing(_ value: UInt64) throws -> UInt64 { value }
@MainActor public func isolated() async -> UInt64 { 1 }
public func overloaded(_ value: UInt64) -> UInt64 { value }
public func overloaded(_ value: Double) -> Double { value }
public func optional(_ value: UInt64?) -> UInt64 { value ?? 0 }
public func inoutValue(_ value: inout UInt64) { value += 1 }

@available(macOS 99, iOS 99, *)
public func future() -> UInt64 { 1 }

// A resilient value exercises a borrowed async receiver. Its storage belongs
// to Swift and is destroyed only after both Odin completions have returned.
public struct Counter {
	let value: UInt64
	public func wait() async {
		await Task.yield()
		precondition(value == 73)
	}
}

public func makeCounter(_ value: UInt64) -> UInt64 {
	let storage = UnsafeMutablePointer<Counter>.allocate(capacity: 1)
	storage.initialize(to: Counter(value: value))
	return UInt64(UInt(bitPattern: storage))
}

public func destroyCounter(_ address: UInt64) {
	let storage = UnsafeMutablePointer<Counter>(bitPattern: UInt(address))!
	storage.deinitialize(count: 1)
	storage.deallocate()
}
