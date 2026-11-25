#+build darwin arm64
#+vet tabs style semicolon
package darwin_StoreKit

import "core:mem"
import "core:strings"
foreign import api "swift:StoreKit"

when AVAILABLE {
	Transaction_Query :: enum { History, Entitlements }

	// Caller-owned and initially zero. Keep its address stable until on_closed.
	Transaction_Scan :: struct {
		listener:   Transaction_Listener,
		product_id: string,
		allocator:  mem.Allocator,
		on_item:    proc(^Transaction_Scan, Verification),
		on_closed:  proc(^Transaction_Scan, Listener_End),
		failed:     bool,
	}

	// A nil sequence reports a failed start. Once a scoped call is submitted,
	// its conversion failure must propagate without retrying an unfiltered read.
	@(private)
	scan_sequence :: proc(query: Transaction_Query, id: string) -> (sequence: api.Transaction_Transactions, filter: bool) {
		switch query {
		case .History:
			if id != "" {
				when #defined(api.Transaction_all_for_if_available) {
					if fetch := api.Transaction_all_for_if_available(); fetch != nil {
						sequence, _ = fetch(id)
						return
					}
				} else when #defined(api.Transaction_all_for_) {
					sequence, _ = api.Transaction_all_for_(id)
					return
				}
			}
			sequence, _ = api.Transaction_all()
		case .Entitlements:
			if id != "" {
				when #defined(api.Transaction_current_entitlements_for_if_available) {
					if fetch := api.Transaction_current_entitlements_for_if_available(); fetch != nil {
						sequence, _ = fetch(id)
						return
					}
				} else when #defined(api.Transaction_current_entitlements_for_) {
					sequence, _ = api.Transaction_current_entitlements_for_(id)
					return
				}
			}
			sequence, _ = api.Transaction_current_entitlements()
		}
		return sequence, id != ""
	}

	// An empty product ID scans all products. Items are borrowed through on_item.
	// False schedules no callbacks. All calls and callbacks use the main executor.
	@(require_results)
	scan_transactions :: proc(
		scan: ^Transaction_Scan, query: Transaction_Query, product_id: string,
		on_item: proc(^Transaction_Scan, Verification), on_closed: proc(^Transaction_Scan, Listener_End),
	) -> bool {
		if scan == nil || is_listening(&scan.listener) || on_item == nil || on_closed == nil { return false }
		sequence, local_filter := scan_sequence(query, product_id)
		if sequence == nil { return false }
		filter: string
		if local_filter {
			copy, err := strings.clone(product_id)
			if err != nil {
				api.Transaction_Transactions_destroy(sequence)
				return false
			}
			filter = copy
		}
		scan^ = {product_id = filter, allocator = context.allocator, on_item = on_item, on_closed = on_closed}
		if listen_sequence(&scan.listener, sequence, scan_item, scan_closed) { return true }
		delete(filter, scan.allocator)
		scan^ = {}
		return false
	}

	stop_scan :: proc(scan: ^Transaction_Scan) {
		if scan != nil { stop_listening(&scan.listener) }
	}

	@(private)
	scan_item :: proc(listener: ^Transaction_Listener, item: Verification) {
		scan := container_of(listener, Transaction_Scan, "listener")
		if scan.product_id != "" {
			tx: Transaction
			switch value in item {
			case Verified:   tx = value.value
			case Unverified: tx, _ = unverified_details(value)
			case:            // A future case cannot be filtered by product.
			}
			if tx != nil {
				if id, ok := Transaction_product_id(tx); ok {
					defer delete(id)
					if id == scan.product_id { scan.on_item(scan, item) }
					return
				}
			}
			scan.failed = true
			stop_scan(scan)
			return
		}
		scan.on_item(scan, item)
	}

	@(private)
	scan_closed :: proc(listener: ^Transaction_Listener, reason: Listener_End) {
		scan := container_of(listener, Transaction_Scan, "listener")
		closed := scan.on_closed
		end := reason
		if scan.failed { end = .Conversion_Failed }
		delete(scan.product_id, scan.allocator)
		scan^ = {}
		closed(scan, end)
	}
}
