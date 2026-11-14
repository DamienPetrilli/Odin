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

// Frozen no-payload enums use native Odin enums. Raw values are deliberately
// unrelated to the ABI discriminants, including a String-backed enum.
@frozen public enum Mode { case idle, running }
@frozen public enum SingleCase { case only }
@frozen public enum RawCode: UInt64 { case first = 10, second = 20 }
@frozen public enum TextCode: String { case empty = "", book = "Café 📚", other = "other" }
public enum ResilientChoice { case first, second }

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
