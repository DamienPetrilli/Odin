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

public struct Int {
	public let value: Swift.Int
	public init(_ value: Swift.Int) { self.value = value }
}
public struct UInt {
	public let value: Swift.UInt
	public init(_ value: Swift.UInt) { self.value = value }
}
public func actualFlag(_ value: Swift.Bool) -> Swift.Bool { !value }
public func actualInt(_ value: Swift.Int) -> Swift.Int { value }
public func actualUInt(_ value: Swift.UInt) -> Swift.UInt { value }
public func uint(_ value: Swift.UInt) -> Swift.UInt { value }

private enum PrivateFailure: Error { case rejected }
public func failWithoutPublicError() async throws -> Swift.UInt64 {
	await Task.yield()
	throw PrivateFailure.rejected
}

public func selectFirst(_ value: Swift.UInt64) -> Swift.UInt64 { value + 1 }
public func selectFirst(_ value: Swift.Float16) -> Swift.Float16 { value }
public func selectLast(_ value: Swift.Float16) -> Swift.Float16 { value }
public func selectLast(_ value: Swift.UInt64) -> Swift.UInt64 { value + 2 }

@available(macOS 99, iOS 99, *)
public func targetValue(_ value: Swift.Double) -> Swift.UInt64 { 0 }
public func targetValue(_ value: Swift.UInt64) -> Swift.UInt64 { value }

#if canImport(UIKit)
import UIKit

public func controllerAddress(options: Set<Swift.UInt64> = []) async -> Swift.UInt { Swift.UInt(options.count) }

@MainActor public func controllerAddress(presenting controller: UIViewController, options: Set<Swift.UInt64> = []) async -> Swift.UInt {
	await Task.yield()
	if Task.isCancelled { return 0 }
	return Swift.UInt(bitPattern: Unmanaged.passUnretained(controller).toOpaque()) + Swift.UInt(options.count)
}

@MainActor public func controllerRecord(_ controller: UIViewController) async -> UInt64 {
	UInt64(Swift.UInt64(Swift.UInt(bitPattern: Unmanaged.passUnretained(controller).toOpaque())))
}

public func controllerAddress(presenting scene: some UIScene, options: Set<Swift.UInt64> = []) async -> Swift.UInt { 0 }
#endif
