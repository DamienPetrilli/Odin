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

@frozen public struct TransactionID: Equatable {
	public var value: UInt64

	public init(value: UInt64) {
		self.value = value
	}
}

@frozen public struct TextView: Equatable {
	public var bytes: UnsafePointer<UInt8>
	public var count: UInt64

	public init(bytes: UnsafePointer<UInt8>, count: UInt64) {
		self.bytes = bytes
		self.count = count
	}
}

@frozen public struct TransactionKey: Equatable {
	public var id: UInt64
	public var originalID: UInt64
	public var purchasedAt: Double
	public var status: UInt64

	public init(id: UInt64, originalID: UInt64, purchasedAt: Double, status: UInt64) {
		self.id = id
		self.originalID = originalID
		self.purchasedAt = purchasedAt
		self.status = status
	}
}

@frozen public struct TransactionInfo: Equatable {
	public var id: UInt64
	public var originalID: UInt64
	public var purchasedAt: Double
	public var status: UInt64
	public var productOffset: UInt64
	public var productCount: UInt64

	public init(id: UInt64, originalID: UInt64, purchasedAt: Double, status: UInt64, productOffset: UInt64, productCount: UInt64) {
		self.id = id
		self.originalID = originalID
		self.purchasedAt = purchasedAt
		self.status = status
		self.productOffset = productOffset
		self.productCount = productCount
	}
}

public func nextID(_ id: TransactionID) -> TransactionID {
	TransactionID(value: id.value + 1)
}

public func dropPrefix(_ text: TextView, _ prefix: UInt64) -> TextView {
	guard text.count > 0, UInt64(text.bytes.pointee) == prefix else { return text }
	return TextView(bytes: text.bytes.advanced(by: 1), count: text.count - 1)
}

public func updateKey(_ status: UInt64, _ key: TransactionKey, _ seconds: Double) -> TransactionKey {
	var result = key
	result.id += 1
	result.status = status
	result.purchasedAt += seconds
	return result
}

public func updateTransaction(_ status: UInt64, _ transaction: TransactionInfo, _ seconds: Double) -> TransactionInfo {
	var result = transaction
	result.id += 1
	result.status = status
	result.purchasedAt += seconds
	result.productOffset += 1
	result.productCount -= 1
	return result
}

public func updateTransactionInPlace(_ transaction: UnsafeMutablePointer<TransactionInfo>, _ status: UInt64, _ seconds: Double) -> UnsafeMutablePointer<TransactionInfo> {
	transaction.pointee = updateTransaction(status, transaction.pointee, seconds)
	return transaction
}

public struct AsyncProbe {
	public var value: UnsafeMutablePointer<UInt64>
	public var delta: UInt64

	public func increment() async {
		await Task.yield()
		value.pointee += delta
	}

	public func snapshot() async -> AsyncSnapshot {
		await Task.yield()
		return AsyncSnapshot(value.pointee, delta)
	}
}

public struct AsyncSnapshot {
	public var value: UInt64
	public var delta: UInt64

	init(_ value: UInt64, _ delta: UInt64) {
		self.value = value
		self.delta = delta
	}
}

public func asyncProbe(_ value: UnsafeMutablePointer<UInt64>, _ delta: UInt64) -> AsyncProbe {
	precondition(MemoryLayout<AsyncProbe>.size == 16 && MemoryLayout<AsyncProbe>.alignment == 8)
	precondition(MemoryLayout<AsyncSnapshot>.size == 16 && MemoryLayout<AsyncSnapshot>.alignment == 8)
	return AsyncProbe(value: value, delta: delta)
}

public func snapshotValue(_ snapshot: borrowing AsyncSnapshot) -> UInt64 {
	return snapshot.value + snapshot.delta
}

public func invertFlag(_ value: Bool) -> Bool { !value }
