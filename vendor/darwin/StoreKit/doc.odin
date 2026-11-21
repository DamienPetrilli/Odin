#+build darwin arm64
#+vet tabs style semicolon

/*
StoreKit purchases, entitlements and transaction updates for non-consumables on Apple platforms.

Import this package as `sk "vendor:darwin/StoreKit"`. Start catalog and purchase
operations from the main executor. On a successful start the caller owns the
task. The operation continues if the caller releases its reference. Use `task_cancel` to
request cancellation. Completion borrows the task.

`products` accepts a slice of product IDs. Its callback owns the product slice,
its elements and the error. A successful display-string getter returns an Odin
string allocated with the current allocator. Use the original allocator when
releasing those values. A missing product ID can yield a successful empty catalog.

Example:
	import "core:fmt"
	import sk "vendor:darwin/StoreKit"

	start_catalog :: proc(ids: []string) -> bool {
		task := sk.products(ids, catalog_received) or_return
		sk.task_release(task)
		return true
	}

	catalog_received :: proc(task: sk.Task, items: []sk.Product, err: sk.Error) {
		defer sk.Error_destroy(err)
		defer sk.products_destroy(items)
		if err != nil { return }
		for item in items {
			price := sk.Product_display_price(item) or_continue
			defer delete(price)
			fmt.println(price)
		}
	}

Use a zero-initialized `Transaction_Listener` for updates, entitlements or
unfinished transactions. Its address must stay valid through the close callback.
Read its `stream` in either callback. The package manages its other fields.
Its item callback borrows the verification. Copy the transaction to keep it
after that callback. Grant access only after verification and successful
delivery. Finish each delivered transaction. A pending or cancelled purchase
grants no access.

An unrecognized thrown error retains its Swift error box. Use `error_description`
on that box for diagnostics. Make purchase decisions from typed cases and
transaction state.
*/
package darwin_StoreKit
