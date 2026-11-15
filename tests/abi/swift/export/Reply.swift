public func increment(_ value: UInt64) -> UInt64 {
	value + 1
}

public func identityInt(_ value: Int) -> Int { value }
public func identityUInt(_ value: UInt) -> UInt { value }
public func identityBool(_ value: Bool) -> Bool { value }

import Foundation
public func identityUUID(_ value: Foundation.UUID) -> Foundation.UUID { value }
