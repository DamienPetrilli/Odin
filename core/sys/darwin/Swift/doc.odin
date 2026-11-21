#+build darwin, arm64

/*
Runtime support for calling Swift from Odin on Darwin arm64.

Use `foreign import api "swift:Module"` to call supported Swift declarations.
For an SDK framework, give its module name. For a local module, give the path
to its name relative to the importing file. Place its Swift module and object
or static archive together. Build on macOS with Xcode and LLVM 18 or later.
Run `odin check app -show-swift-imports` with the same deployment target to see
the available declarations, their Odin types and their ownership rules.

Imported async procedures accept an ordinary Odin completion procedure. A
successful start returns one owned `Task`. Release it when you no longer need
to request cancellation. The completion runs on the main executor and borrows
the task. It receives a copy of the caller's Odin context. Keep any allocator
state and user data referenced by that context valid through completion.

A synchronous throwing call returns its error last. The generated module
exposes its own `Call_Error` union. A nil error means success. Use the module's
`Call_Error_destroy` to release an owned error. Use its copy procedure to keep
a second owner. Ordinary assignment can alias storage.

An unsafe buffer passed to Swift borrows the Odin slice storage. Keep it alive
for the lifetime required by the Swift procedure. A Bool buffer uses 0 and 1 bytes.

For the reverse direction, export a supported `proc "swift"` with `@(export)`
and build the package as a static library. Swift imports the resulting module
as `Odin` followed by the package name in UpperCamelCase.
*/
package darwin_Swift
