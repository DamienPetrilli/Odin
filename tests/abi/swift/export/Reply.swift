public func increment(_ value: UInt64) -> UInt64 {
	value + 1
}

public func identityInt(_ value: Int) -> Int { value }
public func identityUInt(_ value: UInt) -> UInt { value }
public func identityBool(_ value: Bool) -> Bool { value }

import Foundation
public func identityUUID(_ value: Foundation.UUID) -> Foundation.UUID { value }

public func identityInt8(_ value: Int8) -> Int8 { value }
public func identityUInt8(_ value: UInt8) -> UInt8 { value }
public func identityInt16(_ value: Int16) -> Int16 { value }
public func identityUInt16(_ value: UInt16) -> UInt16 { value }
public func identityInt32(_ value: Int32) -> Int32 { value }
public func identityUInt32(_ value: UInt32) -> UInt32 { value }
public func identityFloat(_ value: Float) -> Float { value }

@inline(never) public func measure(_ index: Int64, _ weight: Double) -> (Int64, Double) {
	(index &- 1, weight + 0.25)
}

@inline(never) public func packedReply(_ x: Int8, _ y: UInt16, _ z: Bool, _ w: Float) -> (Int8, UInt16, Bool, Float) {
	(x, y, z, w)
}

@inline(never) public func wideReply(_ x: Int16) -> (UInt16, Double, Int64, Bool, UInt64, Int16) {
	(UInt16(bitPattern: x), -0.0, Int64.min, x != 0, UInt64.max, x)
}

@frozen public enum ReadingError: Error { case missing }

public func checkedReading(_ n: UInt64) throws -> (UInt64, UInt64, UInt64, UInt64, Bool) {
	if n == 0 { throw ReadingError.missing }
	return (n, n &+ 1, n &+ 2, n &+ 3, true)
}
