#if BUILTIN
public struct f64 { public let value: Swift.UInt64 }
public func actualDouble() -> Swift.Double { 12.5 }
#elseif FLATTENED
public struct A { public struct B { public let value: Swift.UInt64 } }
public struct A_B { public let value: Swift.Double }
#elseif HELPER
public struct Value {
	public let value: Swift.UInt64
	public func copy() -> Swift.UInt64 { value }
}
#elseif UNSUPPORTED_HELPER
public struct Value {
	public let value: Swift.UInt64
	public func destroy<T>(_ value: T) {}
}
#elseif ENUM_CASE
public enum Value { case value, Value, unknown_Default }
#elseif STRING_TYPE
public struct String { public let value: Swift.UInt64 }
public func text() -> Swift.String { "text" }
#endif
