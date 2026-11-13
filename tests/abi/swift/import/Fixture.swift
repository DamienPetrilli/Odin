import Foundation

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

@available(tvOS, unavailable)
@available(macOS 15, iOS 15, *)
public func decorate(_ text: String) -> String { "[" + text + "]" }
public func utf8Count(_ text: String) -> UInt64 { UInt64(text.utf8.count) }
public func utf8CountLater(_ text: String) async -> UInt64 {
	await Task.yield()
	return UInt64(text.utf8.count)
}
public func receiveText(_ text: String) { precondition(text == "hello") }
public func receiveTextLater(_ text: String) async {
	await Task.yield()
	precondition(text == "hello")
}
public struct TextValue {
	public let text: String
	public init(_ text: String) { self.text = text }
}
public enum TextOutcome { case text(String), empty }
public func textOutcome(_ text: String) -> TextOutcome { .text(text) }

public func echoTexts(_ texts: [String]) -> [String] { texts }
public func echoTextsLater(_ texts: [String]) async -> [String] {
	await Task.yield()
	return texts
}
public struct TextOption: Hashable {
	public let value: UInt64
	public init(_ value: UInt64) { self.value = value }
}
extension TextValue {
	public static func lookup<Names: Collection>(for names: Names) async throws -> [TextValue]
		where Names.Element == String {
		await Task.yield()
		if names.isEmpty { throw ValueFailure() }
		return names.map { TextValue($0) }
	}
	@MainActor public func accept(options: Set<TextOption> = []) async throws -> ValueOutcome {
		MainActor.preconditionIsolated()
		await Task.yield()
		MainActor.preconditionIsolated()
		precondition(options.isEmpty)
		if text.isEmpty { throw ValueFailure() }
		return .accepted(Value(UInt64(text.utf8.count)))
	}
}

// Unsupported declarations must be diagnosed at the importing source.
public func narrow(_ value: UInt32) -> UInt32 { value }
public func generic<T>(_ value: T) -> T { value }
public func throwing(_ value: UInt64) throws -> UInt64 { value }
@MainActor public func isolated() async -> UInt64 {
	MainActor.preconditionIsolated()
	await Task.yield()
	MainActor.preconditionIsolated()
	return 1
}
@MainActor public func isolatedSync() -> UInt64 { 1 }
public func textLater() async -> String { "unsupported result conversion" }
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

private let lifetimeLock = NSLock()
nonisolated(unsafe) private var liveValues: UInt64 = 0

private final class Lifetime {
	init() {
		lifetimeLock.lock()
		liveValues += 1
		lifetimeLock.unlock()
	}
	deinit {
		lifetimeLock.lock()
		liveValues -= 1
		lifetimeLock.unlock()
	}
}

private final class ValueFailure: Error, @unchecked Sendable {
	let lifetime = Lifetime()
}

public func liveValueCount() -> UInt64 {
	lifetimeLock.lock()
	defer { lifetimeLock.unlock() }
	return liveValues
}

// Resilient, nontrivial values must use metadata and value witnesses. The
// array checks copy-on-write while Lifetime checks retain/destroy balance.
public struct Value {
	private let lifetime = Lifetime()
	private var storage: [UInt64]
	public init(_ value: UInt64) { storage = [value, 0x123456789abcdef0] }
	public var value: UInt64 { storage[0] }
	public mutating func increment(_ amount: UInt64) {
		precondition(storage[1] == 0x123456789abcdef0)
		storage[0] += amount
	}
	public mutating func incrementLater(_ amount: UInt64) async {
		await Task.yield()
		increment(amount)
	}
	public func readLater() async -> UInt64 {
		await Task.yield()
		return value
	}
	public func addingLater(_ amount: UInt64) async -> Value {
		await Task.yield()
		return Value(value + amount)
	}
	public func checkedAddingLater(_ amount: UInt64) async throws -> Value {
		await Task.yield()
		if amount == 0 { throw ValueFailure() }
		return Value(value + amount)
	}
	public static var initial: Value { Value(17) }

	public struct Nested {
		public let value: UInt64
		public init(_ value: UInt64) { self.value = value }
	}
}

public func makeValue(_ value: UInt64) -> Value { Value(value) }

public struct ValuePair {
	public let value: Value
	public let title: String
	public init(_ value: Value, _ title: String) {
		self.value = value
		self.title = title
	}
}

public func readValue(_ value: Value) -> UInt64 { value.value }
public func addValuesLater(_ left: Value, _ right: Value) async -> Value {
	await Task.yield()
	return Value(left.value + right.value)
}

public func checkedLater(_ value: UInt64) async throws -> UInt64 {
	await Task.yield()
	if value == 0 { throw ValueFailure() }
	return value
}

public func checkedVoidLater(_ value: UInt64) async throws {
	await Task.yield()
	if value == 0 { throw ValueFailure() }
}

public enum TypedFailure: Error { case rejected }
public func typedThrowing(_ value: UInt64) async throws(TypedFailure) -> UInt64 {
	if value == 0 { throw TypedFailure.rejected }
	return value
}

@frozen public struct DirectValue {
	public var value: UInt64
	public init(_ value: UInt64) { self.value = value }
}
// Direct aggregate lowering must not be mistaken for resilient indirection.
public func directValue(_ value: DirectValue) -> DirectValue { value }

public enum ValueOutcome {
	case accepted(Value)
	case pending
	case cancelled
#if EVOLVED_VALUE_ENUM
	case future(Value, Value)
#endif
}

public func valueOutcome(_ selection: UInt64) -> ValueOutcome {
	if selection == 1 { return .accepted(Value(73)) }
	if selection == 2 { return .cancelled }
#if EVOLVED_VALUE_ENUM
	if selection == 99 { return .future(Value(11), Value(22)) }
#endif
	return .pending
}

@frozen public enum Validation<T> {
	case invalid(T, TypedFailure)
	case valid(T)
}

public struct ValueSequence {
	public struct Iterator {
		private var remaining: UInt64 = 1
		public init() {}
		public mutating func next() async -> Validation<Value>? {
			await Task.yield()
			if remaining == 0 { return nil }
			remaining -= 1
			return .valid(Value(73))
		}
	}
	public static var current: ValueSequence { ValueSequence() }
	public func makeIterator() -> Iterator { Iterator() }
}

// These are ordinary Swift APIs. Odin creates and controls their tasks through
// the native runtime; the fixture contains no Odin-specific entry points.
nonisolated(unsafe) private var cancellationStarts: UInt64 = 0
nonisolated(unsafe) private var cancellationHandlers: UInt64 = 0

public func cancellationStarted() -> UInt64 {
	lifetimeLock.lock()
	defer { lifetimeLock.unlock() }
	return cancellationStarts
}
public func cancellationHandled() -> UInt64 {
	lifetimeLock.lock()
	defer { lifetimeLock.unlock() }
	return cancellationHandlers
}
public func waitForCancellation(_ value: Value) async -> UInt64 {
	let handled = cancellationHandled()
	return await withTaskCancellationHandler {
		lifetimeLock.withLock { cancellationStarts += 1 }
		// Observing the flag can race with handler delivery/removal. Keep this
		// operation suspended until its handler has actually signalled it.
		while !Task.isCancelled || cancellationHandled() == handled { await Task.yield() }
		return value.value
	} onCancel: {
		lifetimeLock.withLock { cancellationHandlers += 1 }
	}
}
public func cancellationState() async -> UInt64 {
	Task.isCancelled ? 1 : 0
}
public func cancellationError(_ value: Value) async throws -> Value {
	try Task.checkCancellation()
	return value
}

public func arrayWords(_ values: [UInt64], _ delta: UInt64) -> [UInt64] {
	var result = values
	for i in result.indices { result[i] &+= delta }
	return result
}
public func arraySigned(_ values: [Int64]) -> [Int64] { values }
public func arrayDoubles(_ values: [Double]) -> [Double] { values }
public func arrayWordsLater(_ values: [UInt64], _ delta: UInt64) async -> [UInt64] {
	await Task.yield()
	return arrayWords(values, delta)
}
public func arrayWordsThrowing(_ values: [UInt64], _ delta: UInt64) async throws -> [UInt64] {
	await Task.yield()
	if delta == 0 { throw ValueFailure() }
	return arrayWords(values, delta)
}

public struct ArrayHolder {
	private var storage: [String]
	public var values: [String] { storage }
	public mutating func append(_ value: String) { storage.append(value) }
	public init(_ values: [String]) { self.storage = values }
	public func changed() -> [String] {
		var copy = values
		if !copy.isEmpty { copy[0] = "changed" }
		return copy
	}
}
public func unsupportedNestedArray(_ values: [[String]]) -> [[String]] { values }

public func arrayLiteral() -> [UInt64] { [7, 11, 19, 23] }

public struct GrowingArray {
	private var storage: [UInt64]
	public init(_ values: [UInt64]) { storage = values }
	public var capacity: UInt64 { UInt64(storage.capacity) }
	public var values: [UInt64] { storage }
	public mutating func append(_ count: UInt64) -> UInt64 {
		var address = storage.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
		var moves: UInt64 = 0
		for i in 0..<count {
			storage.append(i)
			let next = storage.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
			if next != address { moves += 1 }
			address = next
		}
		return moves
	}
}
public func arrayNativeCapacity(_ count: UInt64) -> UInt64 {
	GrowingArray(Array(repeating: 0, count: Int(count))).capacity
}
public func arrayNativeGrowth(_ count: UInt64, _ extra: UInt64) -> UInt64 {
	var array = GrowingArray(Array(repeating: 0, count: Int(count)))
	return array.append(extra)
}
public func arrayBridgedTexts() -> [String] {
	let text = NSMutableString(capacity: 64)
	text.append("日本語 🦉 café embedded\0zero and a longer string")
	return [text as String]
}
