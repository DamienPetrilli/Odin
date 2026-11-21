import Foundation

@inline(never) public func add(_ value: UInt64, _ delta: UInt64) -> UInt64 {
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
public func textLater() async -> String {
	await Task.yield()
	return "native async string"
}
public func echoTextLater(_ text: String) async -> String {
	await Task.yield()
	return text
}
public func checkedTextLater(_ text: String, _ fail: Bool) async throws -> String {
	await Task.yield()
	try Task.checkCancellation()
	if fail { throw ValueFailure() }
	return text
}
extension TextValue {
	public func textLater() async -> String {
		await Task.yield()
		return text
	}
}
public func overloaded(_ value: UInt64) -> UInt64 { value }
public func overloaded(_ value: Double) -> Double { value }
public func optional(_ value: UInt64?) -> UInt64 { value ?? 0 }
public func inoutValue(_ value: inout UInt64) { value += 1 }

@available(macOS 99, iOS 99, *)
public func future() -> UInt64 { 1 }

@available(macOS 15.2.1, iOS 18.2, *)
public struct NewValue {
	public static func number() -> UInt64 { 42 }
}
@available(macOS 15.2.1, iOS 18.2, *)
public func newNumber(for value: UInt64) -> UInt64 { value }
@available(macOS, introduced: 12, deprecated: 15.2.1)
@available(iOS, introduced: 14, deprecated: 18.2)
public func priorValue(_ value: UInt64) -> UInt64 { value }
@available(macOS, introduced: 12, obsoleted: 15.2.1)
@available(iOS, introduced: 14, obsoleted: 18.2)
public func withdrawnValue(_ value: UInt64) -> UInt64 { value }
@available(*, deprecated)
public func retiredValue() -> UInt64 { 42 }

@inline(never) @_alwaysEmitIntoClient public func clientOnly() -> UInt64 { 1 }

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
	private var lifetime = Lifetime()
	public mutating func uniqueLifetime() -> Bool { isKnownUniquelyReferenced(&lifetime) }
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

// These are nominal types, not the digester's generic-parameter marker or Void.
public struct GenericTypeParam {
	private let storage: (UInt64, UInt64, UInt64, UInt64, UInt64) = (11, 22, 33, 44, 55)
	public init() {}
	public var first: UInt64 { storage.0 }
	public var last: UInt64 { storage.4 }
}

@frozen public enum NamedPayload<T> {
	case normal(T)
	case named(GenericTypeParam)
}

public func namedPayload() -> NamedPayload<Value> { .named(GenericTypeParam()) }

public struct Void {
	public let value: UInt64
	public init(_ value: UInt64) { self.value = value }
}

public func namedVoid() -> Void { Void(73) }
public func actualVoid() -> Swift.Void {}

public func echoOutcome(_ value: ValueOutcome) -> ValueOutcome { value }
public func readOutcome(_ value: ValueOutcome) -> UInt64 {
	switch value {
	case .accepted(let item): return item.value
	case .pending, .cancelled: return 0
#if EVOLVED_VALUE_ENUM
	case .future(let first, let second): return first.value + second.value
#endif
	}
}

public func nextPage(_ page: UInt64?) -> UInt64? { page.map { $0 &+ 1 } }
public func nestedOptional(_ value: UInt64??) -> UInt64?? { value }
public func deepOptional(_ value: UInt64????) -> UInt64???? { value }
public func optionalDouble(_ value: Double?) -> Double? { value.map { $0 + 0.5 } }
public func optionalText(_ value: String?) -> String? { value }
public func optionalWords(_ value: [UInt64]?) -> [UInt64]? { value }

@frozen public enum Lookup {
	case found(UInt64)
	case other(UInt64)
	case missing
	case rejected(code: UInt64, message: String)
}
public func echoLookup(_ value: Lookup) -> Lookup { value }
public func lookupLater(_ value: Lookup) async -> Lookup {
	await Task.yield()
	return value
}
public func pageLater(_ value: UInt64?) async -> UInt64? {
	await Task.yield()
	return nextPage(value)
}

public enum Payloads {
	case pair(Value, Value)
	case texts([String])
	case empty
}
public func echoPayloads(_ value: Payloads) -> Payloads { value }
public func payloadsLater(_ value: Payloads) async -> Payloads {
	await Task.yield()
	return value
}

@frozen public enum Verification<T> {
	case verified(T)
	case unverified(T, Failure)
	public enum Failure: Error {
		case invalidSignature
		case blocked(code: UInt64, message: String)
	}
}
public func verification(_ value: Value) -> Verification<Value> {
	.unverified(value, .blocked(code: 7, message: "Verification failed"))
}

// Two specializations share the same resilient nested enum-case symbols.
public func textVerification(_ value: TextValue) -> Verification<TextValue> {
	.unverified(value, .invalidSignature)
}

// An uninhabited namespace must not break unrelated imported declarations.
public enum Namespace {
	public static func answer() -> UInt64 { 42 }
}

public indirect enum IndirectPayload { case value(UInt64) }
public func indirectPayload() -> IndirectPayload { .value(7) }
public enum RecursivePayload { case end; indirect case next(RecursivePayload) }
public func recursivePayload() -> RecursivePayload { .end }
public enum ExistentialPayload { case value(any Error) }
public func existentialPayload(_ value: ExistentialPayload) -> ExistentialPayload { value }
public enum CollidingFields { case value(bookID: UInt64, bookId: UInt64) }
public func collidingFields() -> CollidingFields { .value(bookID: 1, bookId: 2) }

public func makeValues(_ count: UInt64) -> [Value] {
	(0..<count).map { Value($0 + 17) }
}
public func incrementValues(_ values: [Value], _ amount: UInt64) -> [Value] {
	var result = values
	for index in result.indices { result[index].increment(amount) }
	return result
}
public func summarizeValues(_ values: [Value], _ label: String) -> [Value] {
	precondition(label == "count")
	return [Value(UInt64(values.count))]
}
public func sumValues(_ values: [Value]) -> UInt64 {
	values.reduce(0) { $0 &+ $1.value }
}
public func incrementValuesLater(_ values: [Value], _ amount: UInt64) async throws -> [Value] {
	await Task.yield()
	if amount == 0 { throw ValueFailure() }
	return incrementValues(values, amount)
}
@frozen public struct ArrayRecord {
	public let first: UInt64
	public let fraction: Double
	public let last: UInt64
}
public func makeRecords(_ count: UInt64) -> [ArrayRecord] {
	(0..<count).map { ArrayRecord(first: $0, fraction: 0.5, last: $0 + 1) }
}
public func echoRecords(_ values: [ArrayRecord]) -> [ArrayRecord] { values }
public func sumRecords(_ values: [ArrayRecord]) -> UInt64 {
	values.reduce(0) { $0 &+ $1.first &+ $1.last &+ UInt64($1.fraction * 2) }
}
@frozen public struct ArrayEmpty {}
public func emptyRecords(_ count: UInt64) -> [ArrayEmpty] {
	Array(repeating: ArrayEmpty(), count: Int(count))
}
public func countEmptyRecords(_ values: [ArrayEmpty]) -> UInt64 { UInt64(values.count) }
public func echoLookups(_ values: [Lookup]) -> [Lookup] { values }
public func echoOptionalValues(_ values: [Value?]) -> [Value?] { values }
public func futureOutcomes() -> [ValueOutcome] { [valueOutcome(99)] }
public func echoOutcomes(_ values: [ValueOutcome]) -> [ValueOutcome] { values }
public enum ValueBatch { case values([Value]), none }
public func echoBatch(_ value: ValueBatch) -> ValueBatch { value }

public func appendRecords(_ values: [ArrayRecord], _ count: UInt64) -> [ArrayRecord] {
	var output = values
	for index in 0..<count { output.append(ArrayRecord(first: index, fraction: 0.5, last: index+1)) }
	return output
}
public func echoLookupsLater(_ values: [Lookup]) async -> [Lookup] {
	await Task.yield()
	return values
}

@frozen public struct ArrayAligned {
	public let lanes: SIMD4<Float>
	public let value: UInt64
}
public func makeAligned(_ count: UInt64) -> [ArrayAligned] {
	precondition(MemoryLayout<ArrayAligned>.alignment == 16)
	return (0..<count).map { ArrayAligned(lanes: SIMD4(repeating: Float($0)), value: $0+1) }
}
public func sumAligned(_ values: [ArrayAligned]) -> UInt64 {
	values.reduce(0) { $0 &+ UInt64($1.lanes.x) &+ $1.value }
}

// Frozen no-payload enums use native Odin enums. Raw values are deliberately
// unrelated to the ABI discriminants, including a String-backed enum.
@frozen public enum Mode { case idle, running }
@frozen public enum SingleCase { case only }
@frozen public enum RawCode: UInt64 { case first = 10, second = 20 }
@frozen public enum TextCode: String { case empty = "", book = "Café 📚", other = "other" }
public enum ResilientChoice { case first, second }
@frozen public enum RawCollision: UInt64 {
	case first = 10
	public var raw_value: UInt64 { 99 }
}
public enum LibraryCode: UInt64 { case read = 17, write = 91 }
public extension LibraryCode {
	func repeated() async -> LibraryCode { await Task.yield(); return self }
}
public extension RawCode {
	func adding(_ value: UInt64) -> UInt64 { rawValue + value }
	func addingLater(_ value: UInt64) async -> UInt64 { await Task.yield(); return adding(value) }
	mutating func replace() { self = .second }
}
public extension SingleCase {
	func scaled(_ value: Double) -> Double { value * 2 }
}

public func echoMode(_ value: Mode) -> Mode { value }
public func toggleMode(_ value: Mode) -> Mode { value == .idle ? .running : .idle }
public func modeCode(_ value: Mode) -> UInt64 { value == .idle ? 17 : 29 }
public func echoSingleCase(_ value: SingleCase) -> SingleCase { value }
public func makeSingleCase() -> SingleCase { .only }
public func echoRawCode(_ value: RawCode) -> RawCode { value }
public func rawCodeValue(_ value: RawCode) -> UInt64 { value.rawValue }
public func textCodeValue(_ value: TextCode) -> String { value.rawValue }
public func echoResilientChoice(_ value: ResilientChoice) -> ResilientChoice { value }
public func optionalMode(_ value: Mode?) -> Mode? { value }
public func optionalSingleCase(_ value: SingleCase?) -> SingleCase? { value }
public func singleCaseArguments(_ first: SingleCase, _ whole: UInt64, _ middle: SingleCase, _ fraction: Double, _ last: SingleCase) -> Double {
	Double(whole) + fraction
}
public func modeLater(_ value: Mode) async -> Mode {
	await Task.yield()
	return value
}
public func singleCaseLater(_ value: SingleCase) async -> SingleCase {
	await Task.yield()
	return value
}
public func singleCaseArgumentsLater(_ first: SingleCase, _ whole: UInt64, _ middle: SingleCase, _ fraction: Double, _ last: SingleCase) async -> Double {
	await Task.yield()
	return Double(whole) + fraction
}
public func singleCaseThrowing(_ value: UInt64) async throws -> SingleCase {
	await Task.yield()
	if value == 0 { throw ValueFailure() }
	return .only
}
public func rawCodeLater(_ value: UInt64) async -> RawCode? {
	await Task.yield()
	return RawCode(rawValue: value)
}
public func echoModes(_ values: [Mode]) -> [Mode] { values }
public func echoSingleCases(_ values: [SingleCase]) -> [SingleCase] { values }
public func modesLater(_ values: [Mode]) async -> [Mode] {
	await Task.yield()
	return values
}

@frozen public enum ModePayload {
	case named(Mode, String)
	case single(SingleCase, String)
	case empty
}
public func echoModePayload(_ value: ModePayload) -> ModePayload { value }

// Failure after initializing a reference-counted field must destroy that field.
public struct FailableValue {
	private let lifetime = Lifetime()
	public let text: String
	public init?(_ text: String) {
		guard !text.isEmpty else { return nil }
		self.text = text
	}
}

// Cross the one-byte tag boundary; do not truncate an Odin enum to u8.
@frozen public enum WideCode: UInt64 {
	case v000 = 1000, v001 = 1001, v002 = 1002, v003 = 1003, v004 = 1004, v005 = 1005, v006 = 1006, v007 = 1007
	case v008 = 1008, v009 = 1009, v010 = 1010, v011 = 1011, v012 = 1012, v013 = 1013, v014 = 1014, v015 = 1015
	case v016 = 1016, v017 = 1017, v018 = 1018, v019 = 1019, v020 = 1020, v021 = 1021, v022 = 1022, v023 = 1023
	case v024 = 1024, v025 = 1025, v026 = 1026, v027 = 1027, v028 = 1028, v029 = 1029, v030 = 1030, v031 = 1031
	case v032 = 1032, v033 = 1033, v034 = 1034, v035 = 1035, v036 = 1036, v037 = 1037, v038 = 1038, v039 = 1039
	case v040 = 1040, v041 = 1041, v042 = 1042, v043 = 1043, v044 = 1044, v045 = 1045, v046 = 1046, v047 = 1047
	case v048 = 1048, v049 = 1049, v050 = 1050, v051 = 1051, v052 = 1052, v053 = 1053, v054 = 1054, v055 = 1055
	case v056 = 1056, v057 = 1057, v058 = 1058, v059 = 1059, v060 = 1060, v061 = 1061, v062 = 1062, v063 = 1063
	case v064 = 1064, v065 = 1065, v066 = 1066, v067 = 1067, v068 = 1068, v069 = 1069, v070 = 1070, v071 = 1071
	case v072 = 1072, v073 = 1073, v074 = 1074, v075 = 1075, v076 = 1076, v077 = 1077, v078 = 1078, v079 = 1079
	case v080 = 1080, v081 = 1081, v082 = 1082, v083 = 1083, v084 = 1084, v085 = 1085, v086 = 1086, v087 = 1087
	case v088 = 1088, v089 = 1089, v090 = 1090, v091 = 1091, v092 = 1092, v093 = 1093, v094 = 1094, v095 = 1095
	case v096 = 1096, v097 = 1097, v098 = 1098, v099 = 1099, v100 = 1100, v101 = 1101, v102 = 1102, v103 = 1103
	case v104 = 1104, v105 = 1105, v106 = 1106, v107 = 1107, v108 = 1108, v109 = 1109, v110 = 1110, v111 = 1111
	case v112 = 1112, v113 = 1113, v114 = 1114, v115 = 1115, v116 = 1116, v117 = 1117, v118 = 1118, v119 = 1119
	case v120 = 1120, v121 = 1121, v122 = 1122, v123 = 1123, v124 = 1124, v125 = 1125, v126 = 1126, v127 = 1127
	case v128 = 1128, v129 = 1129, v130 = 1130, v131 = 1131, v132 = 1132, v133 = 1133, v134 = 1134, v135 = 1135
	case v136 = 1136, v137 = 1137, v138 = 1138, v139 = 1139, v140 = 1140, v141 = 1141, v142 = 1142, v143 = 1143
	case v144 = 1144, v145 = 1145, v146 = 1146, v147 = 1147, v148 = 1148, v149 = 1149, v150 = 1150, v151 = 1151
	case v152 = 1152, v153 = 1153, v154 = 1154, v155 = 1155, v156 = 1156, v157 = 1157, v158 = 1158, v159 = 1159
	case v160 = 1160, v161 = 1161, v162 = 1162, v163 = 1163, v164 = 1164, v165 = 1165, v166 = 1166, v167 = 1167
	case v168 = 1168, v169 = 1169, v170 = 1170, v171 = 1171, v172 = 1172, v173 = 1173, v174 = 1174, v175 = 1175
	case v176 = 1176, v177 = 1177, v178 = 1178, v179 = 1179, v180 = 1180, v181 = 1181, v182 = 1182, v183 = 1183
	case v184 = 1184, v185 = 1185, v186 = 1186, v187 = 1187, v188 = 1188, v189 = 1189, v190 = 1190, v191 = 1191
	case v192 = 1192, v193 = 1193, v194 = 1194, v195 = 1195, v196 = 1196, v197 = 1197, v198 = 1198, v199 = 1199
	case v200 = 1200, v201 = 1201, v202 = 1202, v203 = 1203, v204 = 1204, v205 = 1205, v206 = 1206, v207 = 1207
	case v208 = 1208, v209 = 1209, v210 = 1210, v211 = 1211, v212 = 1212, v213 = 1213, v214 = 1214, v215 = 1215
	case v216 = 1216, v217 = 1217, v218 = 1218, v219 = 1219, v220 = 1220, v221 = 1221, v222 = 1222, v223 = 1223
	case v224 = 1224, v225 = 1225, v226 = 1226, v227 = 1227, v228 = 1228, v229 = 1229, v230 = 1230, v231 = 1231
	case v232 = 1232, v233 = 1233, v234 = 1234, v235 = 1235, v236 = 1236, v237 = 1237, v238 = 1238, v239 = 1239
	case v240 = 1240, v241 = 1241, v242 = 1242, v243 = 1243, v244 = 1244, v245 = 1245, v246 = 1246, v247 = 1247
	case v248 = 1248, v249 = 1249, v250 = 1250, v251 = 1251, v252 = 1252, v253 = 1253, v254 = 1254, v255 = 1255
	case v256 = 1256
}
public func echoWideCode(_ value: WideCode) -> WideCode { value }
public func wideCodeValue(_ value: WideCode) -> UInt64 { value.rawValue }

// Plain frozen records use inline Odin fields, including indirect large values.
@frozen public struct WideRecord {
	public var first: UInt64
	public var signed: Int64
	public var fraction: Double
	public var fourth: UInt64
	public var fifth: UInt64
}
public func echoWide(_ value: WideRecord) -> WideRecord { value }
public func echoWideLater(_ value: WideRecord) async -> WideRecord {
	await Task.yield()
	return value
}
// Mixed direct register components must not shift the indirect record check.
public func mixedWide(_ prefix: ArrayRecord, _ text: String, _ value: WideRecord) -> WideRecord {
	precondition(prefix.first == value.first && text == "wide")
	return value
}
public func mixedWideLater(_ prefix: ArrayRecord, _ text: String, _ value: WideRecord) async -> WideRecord {
	await Task.yield()
	return mixedWide(prefix, text, value)
}
extension ArrayRecord {
	public mutating func recursiveResult() -> RecursivePayload { .end }
	public mutating func storageAddress() -> UInt {
		withUnsafePointer(to: &self) { UInt(bitPattern: $0) }
	}
	@inline(never) public mutating func advance(_ amount: UInt64) -> UInt64 {
		self = ArrayRecord(first: first &+ amount, fraction: fraction + 0.25, last: last &+ 1)
		return first
	}
	public mutating func advanceLater(_ amount: UInt64) async -> UInt64 {
		await Task.yield()
		return advance(amount)
	}
}
public func echoRecord(_ value: ArrayRecord) -> ArrayRecord { value }
public func incrementRecord(_ value: ArrayRecord, _ delta: UInt64) -> ArrayRecord {
	ArrayRecord(first: value.first &+ delta, fraction: value.fraction + 0.25, last: value.last &+ delta)
}
public func incrementRecords(_ values: [ArrayRecord], _ delta: UInt64) -> [ArrayRecord] {
	values.map { incrementRecord($0, delta) }
}
public func echoRecordLater(_ value: ArrayRecord) async -> ArrayRecord {
	await Task.yield()
	return value
}
public func echoRecordsLater(_ values: [ArrayRecord]) async -> [ArrayRecord] {
	await Task.yield()
	return values
}
public func echoEmpty(_ value: ArrayEmpty) -> ArrayEmpty { value }
public func optionalRecord(_ value: ArrayRecord?) -> ArrayRecord? { value }
@frozen public enum RecordResult { case record(ArrayRecord), none }
public func echoRecordResult(_ value: RecordResult) -> RecordResult { value }

// Frozen does not imply POD or public layout: these keep native owners.
@frozen public struct OwnedRecord { public let text: String }
public func makeOwnedRecord(_ text: String) -> [OwnedRecord] { [OwnedRecord(text: text)] }
public func ownedRecordText(_ value: [OwnedRecord]) -> String { value[0].text }
@frozen public struct HiddenRecord {
	public let value: UInt64
	@usableFromInline internal let hidden: UInt64
}
public func makeHiddenRecord(_ value: UInt64) -> [HiddenRecord] { [HiddenRecord(value: value, hidden: value+1)] }
public func hiddenRecordSum(_ value: [HiddenRecord]) -> UInt64 { value[0].value+value[0].hidden }

nonisolated(unsafe) private var sharedValues: [Value] = []
public func prepareSharedValues(_ count: UInt64) { sharedValues = makeValues(count) }
public func getSharedValues() -> [Value] { sharedValues }
public func sharedValuesSum() -> UInt64 { sumValues(sharedValues) }
public func clearSharedValues() { sharedValues = [] }

// Weak storage exercises initializeWithTake rather than assuming a byte move.
nonisolated(unsafe) private var weakLifetime: Lifetime?
public struct WeakValue {
	private weak var lifetime: Lifetime?
	fileprivate init(_ lifetime: Lifetime) { self.lifetime = lifetime }
	public var alive: UInt64 { lifetime == nil ? 0 : 1 }
}
public func makeWeakValues(_ count: UInt64) -> [WeakValue] {
	let lifetime = Lifetime()
	weakLifetime = lifetime
	return (0..<count).map { _ in WeakValue(lifetime) }
}
public func clearWeakLifetime() { weakLifetime = nil }

public func echoWideRecords(_ values: [WideRecord]) -> [WideRecord] { values }
public func echoDirectValues(_ values: [DirectValue]) -> [DirectValue] { values }

// Standard scalar identities remain distinct from fixed-width integer types.
public func echoBool(_ value: Bool) -> Bool { value }
public func echoInt(_ value: Int) -> Int { value }
public func echoUInt(_ value: UInt) -> UInt { value }
public func flipBool(_ value: Bool) -> Bool { !value }
public func echoBoolLater(_ value: Bool) async -> Bool { await Task.yield(); return value }
public func echoIntLater(_ value: Int) async -> Int { await Task.yield(); return value }
public func echoUIntLater(_ value: UInt) async -> UInt { await Task.yield(); return value }
public func mixedScalarsLater(_ flag: Bool, _ signed: Int, _ unsigned: UInt) async -> Bool {
	await Task.yield()
	return flag && signed == -73 && unsigned == UInt.max
}
public func optionalBool(_ value: Bool?) -> Bool? { value }
public func optionalInt(_ value: Int?) -> Int? { value }
public func optionalUInt(_ value: UInt?) -> UInt? { value }
public func optionalBoolLater(_ value: Bool?) async -> Bool? { await Task.yield(); return value }
public func nativeInts(_ values: [Int]) -> [Int] { values }
public func nativeUInts(_ values: [UInt]) -> [UInt] { values }
public func nativeIntsLater(_ values: [Int]) async -> [Int] { await Task.yield(); return values }
@frozen public struct NativeWords {
	public var signed: Int
	public var unsigned: UInt
}
public func nativeWords(_ value: NativeWords) -> NativeWords { value }
public struct ScalarState {
	public let ready: Bool
	public let signed: Int
	public let unsigned: UInt
	public init(_ ready: Bool, _ signed: Int, _ unsigned: UInt) {
		self.ready = ready; self.signed = signed; self.unsigned = unsigned
	}
	public static var canProceed: Bool { true }
}
public func unsupportedScalarArgument(_ value: Float16) -> Int { Int(value) }
public func unsupportedScalarResult(_ value: Int) -> Float16 { Float16(value) }
public func narrowArray(_ values: [Int16]) -> [Int16] { values }
public func optionalFloat(_ value: Float?) -> Float? { value }
public func unsupportedBoolArray(_ values: [Bool]) -> [Bool] { values }

// Bool fields have byte storage but may share native integer registers.
@frozen public struct BoolOnly {
	public var flag: Bool
}
public func echoBoolOnly(_ value: BoolOnly) -> BoolOnly { value }
@frozen public struct BoolTriple {
	public var a: Bool
	public var b: Bool
	public var c: Bool
}
public func echoBoolTriple(_ value: BoolTriple) -> BoolTriple { value }
@frozen public struct BoolRun {
	public var a: Bool
	public var b: Bool
	public var c: Bool
	public var d: Bool
	public var e: Bool
	public var f: Bool
	public var g: Bool
	public var h: Bool
	public var i: Bool
}
public func echoBoolRun(_ value: BoolRun) -> BoolRun { value }
@frozen public struct BoolHead {
	public var flag: Bool
	public var count: Int
}
public func echoBoolHead(_ value: BoolHead) -> BoolHead { value }
@frozen public struct BoolTail {
	public var count: Int
	public var flag: Bool
}
extension BoolTail {
	public mutating func toggle() { flag.toggle() }
}
public func echoBoolTail(_ value: BoolTail) -> BoolTail { value }
@frozen public struct BoolMixed {
	public var a: Bool
	public var b: Bool
	public var count: Int
	public var fraction: Double
	public var c: Bool
}
public func echoBoolMixed(_ value: BoolMixed) -> BoolMixed { value }
@frozen public struct BoolWide {
	public var flag: Bool
	public var a: Int
	public var b: UInt
	public var c: Double
	public var d: Int
	public var end: Bool
}
public func echoBoolWide(_ value: BoolWide) -> BoolWide { value }
public func optionalBoolTriple(_ value: BoolTriple?) -> BoolTriple? { value }
public func echoBoolTripleLater(_ value: BoolTriple) async -> BoolTriple {
	await Task.yield()
	return value
}
public func optionalBoolTail(_ value: BoolTail?) -> BoolTail? { value }
public func echoBoolTailLater(_ value: BoolTail) async -> BoolTail {
	await Task.yield()
	return value
}
public func optionalBoolMixed(_ value: BoolMixed?) -> BoolMixed? { value }
public func echoBoolMixedLater(_ value: BoolMixed) async -> BoolMixed {
	await Task.yield()
	return value
}
public func optionalBoolWide(_ value: BoolWide?) -> BoolWide? { value }
public func echoBoolWideLater(_ value: BoolWide) async -> BoolWide {
	await Task.yield()
	return value
}
public func echoBoolTriples(_ values: [BoolTriple]) -> [BoolTriple] { values }
public func echoBoolRuns(_ values: [BoolRun]) -> [BoolRun] { values }
public func echoBoolTails(_ values: [BoolTail]) -> [BoolTail] { values }
public func echoBoolMixeds(_ values: [BoolMixed]) -> [BoolMixed] { values }
public func echoBoolWides(_ values: [BoolWide]) -> [BoolWide] { values }
public func flipBoolMixed(_ value: BoolMixed) -> BoolMixed {
	BoolMixed(a: !value.a, b: !value.b, count: value.count &+ 1, fraction: value.fraction + 0.25, c: !value.c)
}
public func echoBoolTailsLater(_ values: [BoolTail]) async -> [BoolTail] {
	await Task.yield()
	return values
}
public func checkedBoolMixedLater(_ value: BoolMixed, _ fail: Bool) async throws -> BoolMixed {
	await Task.yield()
	if fail { throw ValueFailure() }
	return value
}
@frozen public enum BoolRecordResult { case value(BoolMixed), empty }
public func echoBoolRecordResult(_ value: BoolRecordResult) -> BoolRecordResult { value }

// External resilient values are projected through their original native API.
public func dateFromSeconds(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }
public func dateSeconds(_ value: Date) -> Double { value.timeIntervalSinceReferenceDate }
public func echoDate(_ value: Date) -> Date { value }
public func echoOptionalDate(_ value: Date?) -> Date? { value }
public func echoDates(_ values: [Date]) -> [Date] { values }
public func offsetDate(_ value: Date, _ seconds: Double) -> Date { value.addingTimeInterval(seconds) }
public func echoDateLater(_ value: Date) async -> Date {
	await Task.yield()
	return value
}
public func echoOptionalDateLater(_ value: Date?) async -> Date? {
	await Task.yield()
	return value
}

@frozen public struct TextRecord {
	public var title: String
	public var count: Int
	public var flag: Bool
	public init(_ title: String, _ count: Int, _ flag: Bool) {
		self.title = title; self.count = count; self.flag = flag
	}
}
extension TextRecord {
	public mutating func clear() { title = "" }
}
@frozen public struct WideTextRecord {
	public var flag: Bool
	public var title: String
	public var subtitle: String
	public var count: Int
	public init(_ flag: Bool, _ title: String, _ subtitle: String, _ count: Int) {
		self.flag = flag; self.title = title; self.subtitle = subtitle; self.count = count
	}
}
public extension TextRecord {
	func adjusted(_ amount: Int) -> TextRecord {
		var result = self
		result.count += amount
		return result
	}
	func adjustedLater(_ amount: Int) async -> TextRecord {
		await Task.yield()
		return adjusted(amount)
	}
}
public func echoTextRecord(_ value: TextRecord) -> TextRecord { value }
public func changeTextRecord(_ value: TextRecord) -> TextRecord {
	var copy = value
	copy.title += "!"; copy.count += 1; copy.flag.toggle()
	return copy
}
public func echoWideTextRecord(_ value: WideTextRecord) -> WideTextRecord { value }
public func echoTextRecords(_ values: [TextRecord]) -> [TextRecord] { values }
public func optionalTextRecord(_ value: TextRecord?) -> TextRecord? { value }
@frozen public enum TextRecordResult { case record(TextRecord), empty }
public func echoTextRecordResult(_ value: TextRecordResult) -> TextRecordResult { value }
public func echoTextRecordLater(_ value: TextRecord) async -> TextRecord { await Task.yield(); return value }
public func echoWideTextRecordLater(_ value: WideTextRecord) async -> WideTextRecord { await Task.yield(); return value }
public func checkedTextRecordLater(_ value: TextRecord, _ fail: Bool) async throws -> TextRecord {
	await Task.yield()
	if fail { throw ValueFailure() }
	return value
}

private struct DiagnosticFailure: Error, CustomStringConvertible, @unchecked Sendable {
	let message: String
	let lifetime: Lifetime
	var description: String { message }
}
public func diagnosticFailure(_ message: String) async throws -> UInt64 {
	await Task.yield()
	throw DiagnosticFailure(message: message, lifetime: Lifetime())
}
public func bridgedDiagnosticFailure() async throws -> UInt64 {
	await Task.yield()
	throw NSError(domain: "SwiftImportFixture", code: 73, userInfo: nil)
}

// A resilient value larger than the inline temporary must retain heap fallback.
public enum LargeTemporary {
	case values(UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)
	case empty
}
public func echoLargeTemporary(_ value: LargeTemporary) -> LargeTemporary { value }

@frozen public enum PlainFailure: UInt64, Error {
	case missing = 17
	case denied = 41
}
@frozen public enum SoleFailure: Error { case rejected }
@frozen public enum InspectionFailure: Error, @unchecked Sendable {
	case message(String, UInt64)
	case retained(Value)
	case empty
}
public enum EvolvingFailure: Error, @unchecked Sendable {
	case known(String)
	case wide(UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)
	@available(macOS 99, iOS 99, *)
	case deferred
#if EVOLVED_VALUE_ENUM
	case future(Value, Value)
#endif
}
public func plainFailureCode(_ value: PlainFailure) -> UInt64 { value.rawValue }
public func inspectionFailureCode(_ value: InspectionFailure) -> UInt64 {
	switch value {
	case .message(_, let code): return code
	case .retained(let value): return value.value
	case .empty: return 0
	}
}
public func evolvingFailureCode(_ value: EvolvingFailure) -> UInt64 {
	switch value {
	case .known: return 73
	case .wide(let first, _, _, _, _, _, _, _, _, let last): return first + last
	case .deferred: return 0
#if EVOLVED_VALUE_ENUM
	case .future(let first, let second): return first.value + second.value
#endif
	}
}
public func inspectionFailure(_ selection: UInt64) async throws -> UInt64 {
	await Task.yield()
	switch selection {
	case 0: throw PlainFailure.missing
	case 1: throw PlainFailure.denied
	case 2: throw InspectionFailure.message("UTF-8 failure 📚\u{0}after", 73)
	case 3: throw InspectionFailure.retained(Value(91))
	case 4: throw EvolvingFailure.known("Known resilient failure")
	case 5: throw EvolvingFailure.wide(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
	case 6:
#if EVOLVED_VALUE_ENUM
		throw EvolvingFailure.future(Value(17), Value(25))
#else
		throw EvolvingFailure.known("Future library control")
#endif
	case 7: throw SoleFailure.rejected
	case 8: throw InspectionFailure.empty
	case 9: throw GenericFailure<Value>.invalid(Value(73))
	case 10: throw UnsupportedFailure.nested(InspectionFailure.retained(Value(99)))
	default: return 42
	}
}

@frozen public enum GenericFailure<T>: Error, @unchecked Sendable { case invalid(T) }
public func genericFailureCode(_ value: GenericFailure<Value>) -> UInt64 {
	switch value { case .invalid(let value): return value.value }
}

public enum UnsupportedFailure: Error, @unchecked Sendable { case nested(any Error) }

public func echoIdentifier(_ value: Foundation.UUID) -> Foundation.UUID { value }
public func reverseIdentifier(_ value: Foundation.UUID) -> Foundation.UUID {
	let b = value.uuid
	return Foundation.UUID(uuid: (b.15, b.14, b.13, b.12, b.11, b.10, b.9, b.8, b.7, b.6, b.5, b.4, b.3, b.2, b.1, b.0))
}
public func identifierText(_ value: Foundation.UUID) -> Swift.String { value.uuidString }
public func echoOptionalIdentifier(_ value: Foundation.UUID?) -> Foundation.UUID? { value }
public func echoIdentifiers(_ values: [Foundation.UUID]) -> [Foundation.UUID] { values }
public func reverseIdentifiers(_ values: [Foundation.UUID]) -> [Foundation.UUID] { values.map(reverseIdentifier) }
public func echoIdentifierLater(_ value: Foundation.UUID) async -> Foundation.UUID {
	await Task.yield()
	return value
}
public func echoOptionalIdentifierLater(_ value: Foundation.UUID?) async -> Foundation.UUID? { value }
public func echoIdentifiersLater(_ values: [Foundation.UUID]) async -> [Foundation.UUID] {
	await Task.yield()
	return values
}
public func checkedIdentifier(_ value: Foundation.UUID, _ fail: Swift.Bool) async throws -> Foundation.UUID {
	if fail { throw PlainFailure.denied }
	return value
}
public func cancellableIdentifier(_ value: Foundation.UUID) async throws -> Foundation.UUID {
	try await Task.sleep(nanoseconds: 60_000_000_000)
	return value
}
@frozen public enum IdentifierChoice {
	case none
	case value(Foundation.UUID)
}
public func echoIdentifierChoice(_ value: IdentifierChoice) -> IdentifierChoice { value }

// Set construction must use Swift equality, including user-defined equality
// and collisions. Odin supplies candidates without changing the input slice.
@frozen public struct SetRecord: Hashable {
	public var key: UInt64
	public var ignored: UInt64
	public init(_ key: UInt64, _ ignored: UInt64) { self.key = key; self.ignored = ignored }
	public static func == (a: SetRecord, b: SetRecord) -> Bool { a.key == b.key }
	public func hash(into hasher: inout Hasher) { hasher.combine(UInt64(0)) }
}
public struct SetTracked: Hashable, @unchecked Sendable {
	private let lifetime = Lifetime()
	public let key: UInt64
	public init(_ key: UInt64) { self.key = key }
	public static func == (a: SetTracked, b: SetTracked) -> Bool { a.key == b.key }
	public func hash(into hasher: inout Hasher) { hasher.combine(UInt64(0)) }
}
public func setCount(_ values: Set<UInt64>) -> UInt64 { UInt64(values.count) }
public func setDefaults(values: Set<UInt64> = []) -> UInt64 { UInt64(values.count) }
public func setDefaultsLater(values: Set<UInt64> = []) async -> UInt64 { UInt64(values.count) }
public func setWords(_ values: Set<UInt64>) -> [UInt64] { values.sorted() }
public func setTextCount(_ values: Set<String>) -> UInt64 { UInt64(values.count) }
public func setIdentifierCount(_ values: Set<UUID>) -> UInt64 { UInt64(values.count) }
public func setRecordKeys(_ values: Set<SetRecord>) -> [UInt64] { values.map { $0.key }.sorted() }
public func setTrackedCount(_ values: Set<SetTracked>) -> UInt64 { UInt64(values.count) }
public func setTrackedLater(_ values: Set<SetTracked>) async -> UInt64 {
	await Task.yield()
	return UInt64(values.count)
}
public func setTrackedCancelled(_ values: Set<SetTracked>) async throws -> UInt64 {
	while !Task.isCancelled { await Task.yield() }
	try Task.checkCancellation()
	return UInt64(values.count)
}
@frozen public enum SetPayload { case value(String) }
public func setThenOutcome(_ values: Set<SetTracked>, _ outcome: SetPayload) -> UInt64 { UInt64(values.count) }
public func unsupportedSetResult() -> Set<UInt64> { [1, 2] }
public func unsupportedOptionalSet(_ values: Set<UInt64>?) -> UInt64 { UInt64(values?.count ?? 0) }

public func setThenOutcomeLater(_ values: Set<SetTracked>, _ outcome: SetPayload) async -> UInt64 { await Task.yield(); return UInt64(values.count) }
public func setTextLater(_ values: Set<String>) async -> UInt64 { await Task.yield(); return UInt64(values.count) }
public func unsupportedBoolSet(_ values: Set<Bool>) -> UInt64 { UInt64(values.count) }
public func setRecordFirst(_ values: Set<SetRecord>) -> UInt64 { values.first!.ignored }
public struct SetOwner {
	private let values: Set<SetTracked>
	public init(_ values: Set<SetTracked>) { self.values = values }
	public var count: UInt64 { UInt64(values.count) }
}

public func setModes(_ values: Set<Mode>) -> UInt64 { UInt64(values.count) }
@frozen public enum SetText: Hashable { case name(String), empty }
public func setTextCases(_ values: Set<SetText>) -> UInt64 { UInt64(values.count) }
public func setDoubles(_ values: Set<Double>) -> UInt64 { UInt64(values.count) }

public func setIntFirst(_ values: Set<Int>) -> Int { values.first! }
public func setUIntFirst(_ values: Set<UInt>) -> UInt { values.first! }
public func setInt64First(_ values: Set<Int64>) -> Int64 { values.first! }
public func setDoubleFirst(_ values: Set<Double>) -> Double { values.first! }

// Exercise lookup, growth and removal in Swift after native storage construction.
public func setCheckWords(_ values: Set<UInt64>, _ input: [UInt64]) -> Bool {
	var actual = values
	var expected = Set(input)
	guard actual == expected && input.allSatisfy({ actual.contains($0) }) else { return false }
	for value in UInt64(0)..<UInt64(128) { actual.insert(value); expected.insert(value) }
	for value in input { actual.remove(value); expected.remove(value) }
	return actual == expected
}
public func setInts(_ values: Set<Int>) -> [Int] { values.sorted() }
public func setUInts(_ values: Set<UInt>) -> [UInt] { values.sorted() }
public func setInt64s(_ values: Set<Int64>) -> [Int64] { values.sorted() }
public func setDoubleBits(_ values: Set<Double>) -> [UInt64] { values.map { $0.bitPattern }.sorted() }
public func setWordsLater(_ values: Set<UInt64>) async -> UInt64 {
	await Task.yield()
	return UInt64(values.count)
}

public func echoInt8(_ value: Int8) -> Int8 { value }
public func echoInt8Later(_ value: Int8) async -> Int8 {
	await Task.yield()
	return value
}
public func echoUInt8(_ value: UInt8) -> UInt8 { value }
public func echoUInt8Later(_ value: UInt8) async -> UInt8 {
	await Task.yield()
	return value
}
public func echoInt16(_ value: Int16) -> Int16 { value }
public func echoInt16Later(_ value: Int16) async -> Int16 {
	await Task.yield()
	return value
}
public func echoUInt16(_ value: UInt16) -> UInt16 { value }
public func echoUInt16Later(_ value: UInt16) async -> UInt16 {
	await Task.yield()
	return value
}
public func echoInt32(_ value: Int32) -> Int32 { value }
public func echoInt32Later(_ value: Int32) async -> Int32 {
	await Task.yield()
	return value
}
public func echoUInt32(_ value: UInt32) -> UInt32 { value }
public func echoUInt32Later(_ value: UInt32) async -> UInt32 {
	await Task.yield()
	return value
}
public func echoFloat(_ value: Float) -> Float { value }
public func echoFloatLater(_ value: Float) async -> Float {
	await Task.yield()
	return value
}

public func optionalInt8(_ value: Int8?) -> Int8? { value }
public func optionalInt8Later(_ value: Int8?) async -> Int8? {
	await Task.yield()
	return value
}
public func optionalUInt8(_ value: UInt8?) -> UInt8? { value }
public func optionalUInt8Later(_ value: UInt8?) async -> UInt8? {
	await Task.yield()
	return value
}
public func optionalInt16(_ value: Int16?) -> Int16? { value }
public func optionalInt16Later(_ value: Int16?) async -> Int16? {
	await Task.yield()
	return value
}
public func optionalUInt16(_ value: UInt16?) -> UInt16? { value }
public func optionalUInt16Later(_ value: UInt16?) async -> UInt16? {
	await Task.yield()
	return value
}
public func optionalInt32(_ value: Int32?) -> Int32? { value }
public func optionalInt32Later(_ value: Int32?) async -> Int32? {
	await Task.yield()
	return value
}
public func optionalUInt32(_ value: UInt32?) -> UInt32? { value }
public func optionalUInt32Later(_ value: UInt32?) async -> UInt32? {
	await Task.yield()
	return value
}
public func optionalFloatLater(_ value: Float?) async -> Float? {
	await Task.yield()
	return value
}
public func nestedInt8(_ value: Int8??) -> Int8?? { value }

public func inspectBuffer(_ values: UnsafeBufferPointer<Float>) -> UInt {
	UInt(bitPattern: values.baseAddress)
}
public func editBuffer(_ values: UnsafeMutableBufferPointer<Int16>) -> Int {
	for i in values.indices { values[i] &+= 1 }
	return values.count
}
public func countTrue(_ flags: UnsafeBufferPointer<Bool>) -> Int {
    flags.reduce(0) { $0 + ($1 ? 1 : 0) }
}
public func readPointer(_ value: UnsafePointer<UInt32>) -> UInt32 { value.pointee }
public func writePointer(_ value: UnsafeMutablePointer<Float>, _ newValue: Float) { value.pointee = newValue }
public func asyncBuffer(_ values: UnsafeBufferPointer<Int16>) async -> Int { values.count }
public func returnedBuffer(_ values: UnsafeBufferPointer<Int16>) -> UnsafeBufferPointer<Int16> { values }

@inline(never) public func bounds(_ value: UInt64) -> (lower: UInt64, upper: UInt64) {
	(value, value &+ 1)
}

public func measureTuple(_ a: Int64, _ b: Double, _ c: UInt, _ d: Int) -> (Int64, Double, UInt, Int) {
	(a, b, c, d)
}

public func mixedLabels(_ x: Int) -> (Int, weight: Double) { (x, 0.5) }
public func packedTuple(_ x: UInt8, _ y: UInt16) -> (UInt8, UInt16) { (x, y) }
public func mixedTuple(_ x: Int8, _ y: UInt16, _ z: Bool, _ w: Float) -> (Int8, UInt16, Bool, Float) {
	(x, y, z, w)
}
public func indirectTuple() -> (Int, Int, Int, Int, Int) { (0, 1, 2, 3, 4) }
public func ownedTuple() -> (String, UInt64) { ("text", 0) }
public func tupleCaseCollision() -> (pageID: UInt64, page_id: UInt64) { (0, 1) }
public func asyncTuple() async -> (UInt64, UInt64) { (0, 1) }
