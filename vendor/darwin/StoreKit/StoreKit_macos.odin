#+build darwin:default arm64
#+vet tabs style semicolon
package darwin_StoreKit

foreign import api "swift:StoreKit"

@(private)
AVAILABLE :: ODIN_MINIMUM_OS_VERSION >= 12_00_00

when AVAILABLE {
	purchase :: api.Product_purchase
	when ODIN_MINIMUM_OS_VERSION >= 15_02_00 {
		purchase_confirm_in :: api.Product_purchase_confirm_in_options
	}
} else {
	#panic("StoreKit requires -minimum-os-version:12.0 or later on macOS")
}
