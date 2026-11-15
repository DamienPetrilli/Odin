#if ASYNC_ERROR_ALIAS
public typealias Async_Error = UInt64
public func checked() async throws -> UInt64 { 17 }
#elseif ASYNC_ERROR_UNSUPPORTED
public enum Async_Error { case value(any Error) }
public func checked() async throws -> UInt64 { 17 }
#elseif ASYNC_ERROR_TYPE
public struct Async_Error { public let value: UInt64 }
public func checked() async throws -> UInt64 { 17 }
#elseif ERROR_HELPER
@frozen public enum Failure: Error {
	case rejected
	public static func fromError(_ value: UInt64) -> UInt64 { value }
}
#elseif BUILTIN
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
#elseif FROZEN_ENUM_CASE
@frozen public enum Value { case value, Value }
#elseif ENUM_CASE
public enum Value { case value, Value, unknown_Default }
#elseif ARRAY_TYPE
public struct Value { public let value: Swift.UInt64 }
public struct Array_Value { public let value: Swift.UInt64 }
public func values() -> [Value] { [] }
#elseif RECORD_FIELD
@frozen public struct Record { public let itemId: UInt64; public let item_id: UInt64 }
#elseif STRING_TYPE
public struct String { public let value: Swift.UInt64 }
public func text() -> Swift.String { "text" }
#endif
