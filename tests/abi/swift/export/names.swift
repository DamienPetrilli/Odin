import OdinSwiftNames

let value0 = named0(OdinSwiftNames.`AnyObject`(first: 10, second: 20))
precondition(value0.first == 11 && value0.second == 22)

let value1 = named1(OdinSwiftNames.`Self`(first: 10, second: 20))
precondition(value1.first == 11 && value1.second == 22)

let value2 = named2(OdinSwiftNames.`Type`(first: 10, second: 20))
precondition(value2.first == 11 && value2.second == 22)

let value3 = named3(OdinSwiftNames.`Protocol`(first: 10, second: 20))
precondition(value3.first == 11 && value3.second == 22)

let value4 = named4(OdinSwiftNames.`String`(first: 10, second: 20))
precondition(value4.first == 11 && value4.second == 22)

let value5 = named5(OdinSwiftNames.`Bool`(first: 10, second: 20))
precondition(value5.first == 11 && value5.second == 22)

let value6 = named6(OdinSwiftNames.`Int64`(first: 10, second: 20))
precondition(value6.first == 11 && value6.second == 22)

let value7 = named7(OdinSwiftNames.`UInt64`(first: 10, second: 20))
precondition(value7.first == 11 && value7.second == 22)

let value8 = named8(OdinSwiftNames.`Double`(first: 10, second: 20))
precondition(value8.first == 11 && value8.second == 22)

let value9 = named9(OdinSwiftNames.`Never`(first: 10, second: 20))
precondition(value9.first == 11 && value9.second == 22)

let value10 = named10(OdinSwiftNames.`Optional`(first: 10, second: 20))
precondition(value10.first == 11 && value10.second == 22)

let value11 = named11(OdinSwiftNames.`UnsafeMutableBufferPointer`(first: 10, second: 20))
precondition(value11.first == 11 && value11.second == 22)

let value12 = named12(OdinSwiftNames.`Sendable`(first: 10, second: 20))
precondition(value12.first == 11 && value12.second == 22)

let value13 = named13(OdinSwiftNames.`Copyable`(first: 10, second: 20))
precondition(value13.first == 11 && value13.second == 22)

let value = fields(Fields(self: 10, p0: 20, init: 30, class: 40))
precondition(value.`self` == 11 && value.p0 == 22 && value.`init` == 33 && value.`class` == 44)
precondition(initialize() == 11 && finalize() == 22 && leadingName() == 33)
print("Swift export name checks passed")
