// Imported declarations must not shadow the standard types used in ABI probes.
public struct UInt64 {
	public let value: Swift.UInt64
	public init(_ value: Swift.UInt64) { self.value = value }
}

public struct Bool {
	public let value: Swift.UInt64
}

public enum Outcome { case value(UInt64), none }
public func actualScalar(_ value: Swift.UInt64) -> Swift.UInt64 { value + 1 }
public func namedValue(_ value: Swift.UInt64) -> UInt64 { UInt64(value) }
public func namedOutcome(_ value: Swift.UInt64) -> Outcome { .value(UInt64(value)) }
public func scalarWords(_ values: [Swift.UInt64]) -> [Swift.UInt64] { values.map { $0 + 1 } }

public func len(_ value: Swift.UInt64) -> Swift.UInt64 { value + 2 }
public func f64(_ value: Swift.Double) -> Swift.Double { value + 0.5 }

public struct Item {
	public let value: Swift.UInt64
	public init(_ value: Swift.UInt64) { self.value = value }
	public func copy(amount: Swift.UInt64) -> Swift.UInt64 { value + amount }
}
