#+build darwin arm64
#+vet tabs style semicolon

/*
StoreKit purchases, entitlements and transaction updates for non-consumables on Apple platforms.

**Sell a non-consumable**

This example sells a one-time Pro unlock on arm64 iOS 15+ or macOS 12+.
Create a local StoreKit Configuration file in Xcode. Add a Non-Consumable with
the product ID `com.example.editor.pro`, a price and a display name. Select the
file under Edit Scheme → Run → Options → StoreKit Configuration. Run the app
from that scheme to try the purchase with Apple's local payment sheet.

Call `load_store` and `recover_unfinished` when the app opens. Show the
localized catalog price on the Buy button. Enable it when `pro_product != nil`,
payments are allowed, `purchasing` is false and Pro is still locked.
Wire the tap to `buy_pro`. Call these procedures on the main executor. A false
return from `load_store` or `buy_pro` means the requested catalog or purchase
operation did not start.

Example:
	import "core:fmt"
	import sk "vendor:darwin/StoreKit"

	PRO_ID :: "com.example.editor.pro"
	pro_product: sk.Product
	updates, unfinished: sk.Transaction_Listener
	pro_enabled, purchasing: bool

	load_store :: proc() -> bool {
		if !sk.is_listening(&updates) && !sk.listen(&updates, .Updates, transaction_received, listener_closed) {
			return false
		}
		task := sk.products({PRO_ID}, catalog_received) or_return
		sk.task_release(task)
		return true
	}

	catalog_received :: proc(_: sk.Task, items: []sk.Product, err: sk.Error) {
		defer sk.Error_destroy(err)
		defer sk.products_destroy(items)
		if err != nil || len(items) != 1 {
			fmt.println("Pro is unavailable")
			return
		}
		price, ok := sk.Product_display_price(items[0])
		if !ok { return }
		defer delete(price)
		fmt.println("Buy Pro for", price) // Set the button title here.
		sk.Product_destroy(pro_product)
		pro_product = items[0]
		items[0] = nil // The app now owns this product until shutdown.
	}

	buy_pro :: proc() -> bool {
		if pro_product == nil || pro_enabled || purchasing || !sk.can_make_payments() {
			return false
		}
		task := sk.purchase(pro_product, purchase_received) or_return
		purchasing = true
		sk.task_release(task)
		return true
	}

	purchase_received :: proc(_: sk.Task, result: sk.Purchase_Result, err: sk.Error) {
		defer sk.Purchase_Result_destroy(result)
		defer sk.Error_destroy(err)
		purchasing = false
		if err != nil {
			fmt.println("Purchase failed")
			return
		}
		switch outcome in result {
		case sk.Purchase_Success:
			deliver_pro(outcome.value)
		case sk.Purchase_Pending:
			fmt.println("Awaiting approval") // A later approval arrives through .Updates.
		case sk.Purchase_Cancelled:
			return // The buyer dismissed the sheet.
		case sk.Purchase_Unknown:
			fmt.println("Unrecognized purchase outcome")
		}
	}

	transaction_received :: proc(_: ^sk.Transaction_Listener, item: sk.Verification) {
		deliver_pro(item)
	}

	// Call at launch and when the app returns to the foreground.
	recover_unfinished :: proc() -> bool {
		if sk.is_listening(&unfinished) { return true }
		return sk.listen(&unfinished, .Unfinished, transaction_received, listener_closed)
	}

	listener_closed :: proc(listener: ^sk.Transaction_Listener, reason: sk.Listener_End) {
		if reason == .Stopped || reason == .Exhausted && listener.stream == .Unfinished { return }
		fmt.println("Transaction listener closed:", listener.stream, reason)
	}

	deliver_pro :: proc(item: sk.Verification) {
		verified, ok := item.(sk.Verified)
		if !ok { return }
		tx := verified.value // Borrowed from item for this call.
		id, readable := sk.Transaction_product_id(tx)
		if !readable { return }
		defer delete(id)
		if id != PRO_ID { return }
		revoked, got_date := sk.Transaction_revocation_date(tx)
		if !got_date { return }
		pro_enabled = revoked == nil // The app reads this flag to enable its Pro tools.
		task, started := sk.finish(tx, finished)
		if started {
			sk.task_release(task)
		} else {
			fmt.println("Will retry the unfinished transaction")
		}
	}

	finished :: proc(_: sk.Task) {
		fmt.println("Transaction finished")
	}

**Relaunch, pending purchases and refunds**

The example delivers a built-in feature by setting a flag. Setting it twice is safe.
The listener started by `load_store` handles later approvals and revocations.
Restart it after an unexpected close. Call `recover_unfinished` at launch and
on return to the foreground to pick up a delivery or finish interrupted earlier.
An approval can become visible after a scan ends. Keep the updates listener active.
For content
that requires a download or database write, finish only after delivery succeeds.
Key any one-time side effect by `Transaction_id` so a retry cannot deliver twice.

Rebuild the Pro flag at launch from `.Entitlements`. Collect verified, unrevoked
matches for `PRO_ID` and publish that snapshot once the stream ends with
`.Exhausted`. A successful empty scan means no current entitlement. Preserve the
previous access decision on a read or conversion failure. Reconcile any updates
received during the scan. A user-initiated Restore Purchases button can call
`restore` and rescan entitlements after it succeeds.

**Presentation and ownership**

For a multiwindow iPad app targeting iOS 18.2+, use
`purchase_confirm_in(pro_product, view_controller, purchase_received)` with the
UIKit view controller from the window where the buyer tapped.

Releasing a started task handle leaves the operation running. Use `task_cancel`
to request cancellation. Completion borrows the task. The catalog callback owns
its slice and products. The purchase callback owns its result and error. Each
successful string getter returns a caller-owned Odin string. Release these values
with the allocator used to obtain them. At shutdown call `stop_listening` on both listeners and release the catalog entry
with `Product_destroy(pro_product)`. Keep callback state alive until outstanding calls drain.

A listener starts zero-initialized and its address must stay valid through the
close callback, including after `stop_listening`. The item callback borrows the
verification. Use `Transaction_copy` to keep a transaction past that callback.
An unrecognized thrown error retains its Swift error box. Use `error_description`
on the box for diagnostics.

[[Setting up StoreKit Testing in Xcode;https://developer.apple.com/documentation/xcode/setting-up-storekit-testing-in-xcode]]
*/
package darwin_StoreKit
