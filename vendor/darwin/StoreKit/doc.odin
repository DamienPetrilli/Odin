#+build darwin arm64
#+vet tabs style semicolon

/*
StoreKit purchases, consumable delivery, subscriptions, entitlements and transaction updates on Apple platforms.

Use `Product_type` to select how to sell a catalog item. It returns an Odin
`Product_Type`. An unfamiliar SDK value yields `.Unknown, true`. A failed
read yields `ok == false`. The same classification is available on a verified
transaction through `Transaction_product_type`.

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
StoreKit Testing on iOS can issue transaction ID zero. Use a separate flag or
optional value when tracking whether a purchase callback has delivered an ID.

Rebuild the Pro flag at launch from `.Entitlements`. Collect verified, unrevoked
matches for `PRO_ID` and publish that snapshot once the stream ends with
`.Exhausted`. A successful empty scan means no current entitlement. Preserve the
previous access decision on a read or conversion failure. Reconcile any updates
received during the scan. A user-initiated Restore Purchases button can call
`restore` and rescan entitlements after it succeeds.

**Sell consumable credits**

Add a Consumable with ID `com.example.editor.credits` to the same Xcode
configuration and load it with `products`. This example sells packs of 100
credits. Re-enable Buy after completion so the customer can repurchase.
Use `packs_received` as the item callback for the `.Updates` and `.Unfinished`
listeners shown above. Consumables do not appear in `.Entitlements`.

```odin
buy_packs :: proc(product: sk.Product, units: int) -> bool {
	kind := sk.Product_type(product) or_return
	if kind != .Consumable { return false }
	option := sk.purchase_quantity(units) or_return
	defer sk.Purchase_Option_destroy(option)
	task := sk.purchase(product, {option}, packs_purchased) or_return
	sk.task_release(task)
	return true
}

packs_purchased :: proc(_: sk.Task, result: sk.Purchase_Result, err: sk.Error) {
	defer sk.Error_destroy(err)
	defer sk.Purchase_Result_destroy(result)
	if err != nil { return }
	if success, ok := result.(sk.Purchase_Success); ok {
		deliver_packs(success.value)
	}
}

packs_received :: proc(_: ^sk.Transaction_Listener, item: sk.Verification) {
	deliver_packs(item)
}

deliver_packs :: proc(item: sk.Verification) {
	verified, ok := item.(sk.Verified)
	if !ok { return }
	tx := verified.value
	kind, typed := sk.Transaction_product_type(tx)
	if !typed || kind != .Consumable { return }
	id, read := sk.Transaction_product_id(tx)
	if !read { return }
	defer delete(id)
	if id != "com.example.editor.credits" { return }
	revoked, checked := sk.Transaction_revocation_date(tx)
	if !checked || revoked != nil { return }
	units := sk.Transaction_purchased_quantity(tx)
	if units < 1 || units > 10 { return }
	if !credit_once(sk.Transaction_id(tx), 100 * units) { return }
	if task, started := sk.finish(tx, finished); started { sk.task_release(task) }
}
```

`credit_once` is an application procedure. For a local SQLite wallet, create
the table below once. Bind the 64-bit transaction ID as eight big-endian bytes
and the credit amount as an integer. Return true after the insert commits,
including when the same ID already exists. On a storage error return false
and leave the transaction unfinished. The `finished` callback above needs
no wallet logic.

```sql
CREATE TABLE grants (tx BLOB PRIMARY KEY NOT NULL, credits INTEGER NOT NULL CHECK (credits > 0));
INSERT INTO grants(tx, credits) VALUES (?1, ?2) ON CONFLICT(tx) DO NOTHING;
SELECT COALESCE(SUM(credits), 0) FROM grants;
```

Each row is a credit grant. Two purchases of the same product have different
transaction IDs and create two rows. A crash after commit and before `finish`
replays the existing ID and adds zero credits. Keep grant IDs after credits
are spent. If the wallet maintains a separate balance, insert the grant and
update that balance in the same database transaction, adding credits only
when the insert creates a row. A wallet shared across devices needs the same
uniqueness rule in its shared store.

**Sell a 30-day non-renewing pass**

Create a Non-Renewing Subscription named `com.example.editor.pass30` in the
Xcode configuration. This pass lasts 30 consecutive 24-hour days starting
at the verified purchase date. The app allows another purchase after expiry.
Each purchase starts its own term. Apple lets the app choose this policy.

```odin
import "core:time"
import sk "vendor:darwin/StoreKit"

PASS_ID :: "com.example.editor.pass30"
PASS_TERM :: 30 * 24 * time.Hour

Pass :: struct {
	id:      u64,
	period:  sk.Non_Renewing_Period,
	revoked: bool,
}

current_pass, snapshot: Pass
scan: sk.Transaction_Listener
scan_failed, entitlements_checked, purchasing: bool

has_pass :: proc() -> bool {
	return !current_pass.revoked && sk.non_renewing_active(current_pass.period)
}

buy_pass :: proc(product: sk.Product) -> bool {
	if !entitlements_checked || sk.is_listening(&scan) || purchasing || has_pass() { return false }
	kind := sk.Product_type(product) or_return
	if kind != .Non_Renewing_Subscription { return false }
	id := sk.Product_id(product) or_return
	defer delete(id)
	if id != PASS_ID { return false }

	task := sk.purchase(product, pass_purchased) or_return
	purchasing = true
	sk.task_release(task)
	return true
}

pass_purchased :: proc(_: sk.Task, result: sk.Purchase_Result, err: sk.Error) {
	defer sk.Error_destroy(err)
	defer sk.Purchase_Result_destroy(result)
	purchasing = false
	if err != nil { return }
	if purchase, ok := result.(sk.Purchase_Success); ok {
		observe_pass(purchase.value, false)
	}
}

// A repeated delivery keeps its original deadline. A refund wins over a
// previous observation of the same transaction.
keep_latest :: proc(dst: ^Pass, p: Pass) {
	if dst.period.starts_at == dst.period.expires_at ||
	   p.period.starts_at > dst.period.starts_at ||
	   p.period.starts_at == dst.period.starts_at && p.id > dst.id ||
	   p.id == dst.id && p.revoked {
		dst^ = p
	}
}

observe_pass :: proc(item: sk.Verification, from_scan: bool) -> bool {
	v := item.(sk.Verified) or_return
	id := sk.Transaction_product_id(v.value) or_return
	defer delete(id)
	if id != PASS_ID { return true }
	period := sk.non_renewing_period(v, PASS_TERM) or_return
	revoked := sk.Transaction_revocation_date(v.value) or_return
	p := Pass{sk.Transaction_id(v.value), period, revoked != nil}
	if from_scan || sk.is_listening(&scan) { keep_latest(&snapshot, p) }
	if !from_scan {
		keep_latest(&current_pass, p)
		if task, started := sk.finish(v.value, pass_finished); started { sk.task_release(task) }
	}
	return true
}

pass_finished :: proc(_: sk.Task) {}

// Call at launch and after restore. The listener borrows each result.
refresh_pass :: proc() -> bool {
	if sk.is_listening(&scan) { return false }
	snapshot = {}
	scan_failed = false
	return sk.listen(&scan, .Entitlements, pass_item, pass_scan_closed)
}

pass_item :: proc(l: ^sk.Transaction_Listener, item: sk.Verification) {
	from_scan := l.stream == .Entitlements
	if !observe_pass(item, from_scan) && from_scan { scan_failed = true }
}

pass_scan_closed :: proc(_: ^sk.Transaction_Listener, reason: sk.Listener_End) {
	if reason == .Exhausted && !scan_failed {
		current_pass = snapshot
		entitlements_checked = true
	}
}
```

Start the long-lived `.Updates` listener and an `.Unfinished` listener with
`pass_item` when the app launches (see the listener example above). Then call
`refresh_pass()`. A successful empty scan clears access. A failed scan leaves
access intact so the app can retry. Live deliveries during a scan update both
the current pass and the snapshot. StoreKit can include a finished, expired
pass in `.Entitlements`.

Check `has_pass()` when opening the feature and when returning to the foreground.
Schedule a UI refresh for `period.expires_at` if the screen remains open. Access
ends at that instant, even if StoreKit sends no update. Replaying the same
signed purchase yields the same deadline. A later verified purchase yields a
new deadline. `non_renewing_active(period, now)` accepts an explicit Swift
reference date for an app with a trusted clock.

**Sell monthly subscriptions with Basic and Plus tiers**

Put Basic and Plus monthly products in one subscription group. In App Store Connect,
rank Plus at level 1 and Basic at level 2. StoreKit
supplies the end of each paid period. Turning off renewal changes the next
charge. Access continues until the current deadline. A successful renewal
has a new transaction ID and a later deadline. The catalog interval describes
the offer. Use the signed status deadlines to decide access.

An upgrade delivers Plus immediately. When the customer schedules a downgrade,
Plus remains active until StoreKit renews to Basic. Call
`refresh_monthly` with the catalog product at launch, on return from Manage
Subscriptions, and when StoreKit sends a transaction update. Refresh again at
the displayed deadline. `has_monthly_access` checks the clock each time the
customer opens the paid feature.

```odin
import sk "vendor:darwin/StoreKit"

Tier :: enum { None, Basic, Plus }

Plan :: struct {
	period:    sk.Subscription_Period,
	renews_to: Tier,
}

tier_for :: proc(id: string) -> Tier {
	switch id {
	case "com.example.basic": return .Basic
	case "com.example.plus":  return .Plus
	}
	return .None
}

monthly: [Tier]Plan
refreshing, refresh_again: bool
billing_retry: bool
monthly_group: string // Owned by the app for its lifetime.

refresh_monthly :: proc(product: sk.Product) -> bool {
	if monthly_group == "" {
		interval := sk.Product_subscription_period(product) or_return
		if interval.count != 1 || interval.unit != .Month { return false }
		monthly_group = sk.subscription_group_id(product) or_return
	}
	return refresh_group()
}

refresh_group :: proc() -> bool {
	if refreshing {
		refresh_again = true
		return true
	}
	task := sk.subscription_statuses(monthly_group, received_status) or_return
	refreshing = true
	sk.task_release(task)
	return true
}

received_status :: proc(_: sk.Task, items: []sk.Subscription_Status, err: sk.Error) {
	defer sk.Error_destroy(err)
	defer sk.subscription_statuses_destroy(items)
	defer {
		refreshing = false
		if refresh_again {
			refresh_again = false
			refresh_group()
		}
	}
	if err != nil { return } // Keep the last verified deadline and retry.
	next: [Tier]Plan
	retrying := false
	for item in items {
		p, ok := sk.subscription_period(item)
		if !ok { return } // Preserve the snapshot on verification or conversion failure.
		if p.in_billing_retry { retrying = true }
		until := p.access_until.? or_continue
		current, renewal, read := sk.subscription_products(item)
		if !read { return }
		defer delete(current)
		renews_to := Tier.None
		if preference, present := renewal.?; present {
			renews_to = tier_for(preference)
			delete(preference)
		}
		tier := tier_for(current)
		if tier != .None && sk.subscription_active(p) && until > (next[tier].period.access_until.? or_else 0) {
			next[tier] = {p, renews_to}
		}
	}
	monthly, billing_retry = next, retrying
}

active_tier :: proc() -> Tier {
	if sk.subscription_active(monthly[.Plus].period)  { return .Plus }
	if sk.subscription_active(monthly[.Basic].period) { return .Basic }
	return .None
}

has_monthly_access :: proc() -> bool {
	return active_tier() != .None
}

monthly_label :: proc() -> string {
	if tier := active_tier(); tier != .None {
		plan := monthly[tier]
		if plan.period.state == .Grace_Period { return "Update payment to keep access" }
		if tier == .Plus && plan.renews_to == .Basic { return "Plus until renewal, then Basic" }
		return "Renews automatically" if plan.period.will_renew else "Access until period ends"
	}
	if billing_retry { return "Update payment to restore access" }
	return "Subscribe"
}
```

Start a purchase with `sk.purchase(product, completion)` as in the purchase
example above. Deliver a verified transaction for your product, refresh the
group, and finish the delivered transaction. Also listen for renewals through
`.Updates` and recover outstanding deliveries through `.Unfinished`. A change
to renewal preference alone can be observed by refreshing the group when the
customer returns from subscription management.

To refresh Basic and Plus while your store is open, start a subscription
watch on the main executor. Start it before the initial group read. StoreKit
can report a renewal preference change without a new purchase to deliver.

```odin
subscription_watch: sk.Subscription_Watch

open_monthly_store :: proc(product: sk.Product) -> bool {
	if !sk.watch_subscriptions(&subscription_watch, plan_changed, watch_closed) { return false }
	if refresh_monthly(product) { return true }
	sk.stop_subscription_watch(&subscription_watch)
	return false
}

plan_changed :: proc(_: ^sk.Subscription_Watch, _: sk.Subscription_Status) {
	// Re-read the group so another family member's grant is counted too.
	if !refresh_group() { fmt.println("Could not start a subscription refresh") }
}

watch_closed :: proc(_: ^sk.Subscription_Watch, end: sk.Listener_End) {
	if end != .Stopped { fmt.println("Subscription updates ended", end) }
}
```

Call `stop_subscription_watch(&subscription_watch)` when closing the store.
Keep its storage alive through `watch_closed`. Keep the transaction listener
running for purchases that still need delivery.

`paid_until` is the signed transaction expiry. During billing grace,
`access_until` uses the verified grace deadline. `in_billing_retry` reflects the signed renewal info
and can be true while the subscription still grants access. Keep the paid feature available throughout that
interval, even after the paid expiry. Schedule the next refresh at the grace
deadline. A cached status can still say `.Grace_Period` after that instant.
If the payment recovers, a fresh verified status supplies the new
paid deadline and the same access check opens the feature again.

Billing retry outside grace,
revocation, a superseded product, expiry, and an unfamiliar state grant no
access. A group may contain multiple statuses through Family Sharing. The example
keeps the latest active deadline for each known tier. To gate a Plus feature,
check `active_tier() == .Plus`. Pass the selected catalog product to
`sk.purchase` for either change. After the purchase, read the verified group
status again. Only the current product grants its tier. The renewal preference
can name a different product for the next period, or be nil when renewal is off.

**Request a refund in the app**

Use a verified transaction ID and present in the window that owns the Refund
button. On iOS the presenter is a UIKit window scene. On macOS pass the AppKit
view controller displaying the purchase. The Swift importer retains the presenter through
completion. Release the task when the app has no further use for the handle.

```odin
import sk "vendor:darwin/StoreKit"
import UI "vendor:darwin/UIKit"

request_refund :: proc(id: u64, window: ^UI.Window) -> bool {
	task := sk.request_refund(id, UI.Window_windowScene(window), refund_returned) or_return
	sk.task_release(task)
	return true
}

refund_returned :: proc(_: sk.Task, result: sk.Refund_Result, err: sk.Error) {
	defer sk.Refund_Result_destroy(result)
	defer sk.Error_destroy(err)
	if err != nil { return } // Report the request error and preserve access.
	switch _ in result {
	case sk.Refund_Submitted: // Show a submission receipt. Apple decides the refund.
	case sk.Refund_Cancelled: // The customer dismissed the sheet.
	case sk.Refund_Unknown:   // Preserve access for future status values.
	}
}
```

Keep listening to verified transaction updates. Apply the signed revocation
date to the affected transaction and reconcile current entitlements on launch.
`Transaction_revocation_reason` returns an optional integer code with no
cleanup. A revocation can also arise from Family Sharing. A submitted or cancelled
sheet by itself leaves the entitlement intact. Applications that need a decline
notification use App Store Server Notifications V2.

**Presentation and ownership**

For a multiwindow iPad app targeting iOS 18.2+, use
`purchase_confirm_in(pro_product, view_controller, purchase_received)` with the
UIKit view controller from the window where the buyer tapped.
On macOS apps targeting 15.2+, pass the AppKit window where the buyer clicked
to tell StoreKit where to present confirmation. The binding retains the window
through the async call, so the app can release its own reference after starting.

```odin
buy_in_window :: proc(product: sk.Product, window: ^AppKit.Window) -> bool {
	task := sk.purchase_confirm_in(product, window, purchase_received) or_return
	sk.task_release(task)
	return true
}
```

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

Signed transactions

Pass the verification received by the listener to `Verification_jws` to get the
original compact signed transaction as an owned Odin string. Release it with
`delete(signed)`. An unverified result can also carry signed text. Grant access
only after successful verification.

Read `price := sk.Product_price(product) or_return` for calculations. The
magnitude is `coefficient * 10^exponent`; `negative` carries the sign. For example,
2.99 has coefficient 299 and exponent -2, and 0.125 has coefficient 125 and
exponent -3. The value is allocation-free. Use `Product_display_price` for
localized price text. For calculations across products, read the storefront
currency with the amount and compare currency codes before adding prices.

	amount, currency := sk.price_and_currency(product) or_return
	defer delete(currency)

The amount is an exact decimal value. The caller owns the currency string.
On iOS 15 and macOS 12, StoreKit can return an empty code if it cannot
determine the price locale. Check for an empty string before doing currency
arithmetic. A failed conversion returns `ok = false`.

Use `Transaction_json_representation` to read the transaction JSON as an owned
`[]u8`. The header, payload, signature and signed bytes are available from the
verification. Each call creates an independent slice. Release it with
`delete(bytes)`. Forward the original JWS for signature verification.

Transaction history and shared benefits

Use a finite scan to show a purchase history or refresh entitlements for one
product. Pass an empty ID to read every product. The package uses StoreKit’s
scoped query when available and filters the sequence locally on older systems.

```odin
// scan lives in application state through closed. Each item is borrowed.
started := sk.scan_transactions(&scan, .Entitlements, "reader.unlock", received, closed)

received :: proc(_: ^sk.Transaction_Scan, item: sk.Verification) {
	if verified, ok := item.(sk.Verified); ok {
		// Record a candidate grant in the pending snapshot.
		record_candidate(sk.Transaction_id(verified.value))
	} else {
		mark_snapshot_incomplete()
	}
}

closed :: proc(_: ^sk.Transaction_Scan, end: sk.Listener_End) {
	if end == .Exhausted && snapshot_complete() { publish_snapshot() }
}
```

When two product IDs unlock one benefit, collect both entitlement snapshots
before publishing. Keep the benefit active while either product grants access.
A refund remains visible in history. A failed or stopped refresh leaves the
last complete entitlement snapshot in effect.

`Product_is_family_shareable(product)` reads the catalog setting.
`Transaction_ownership(tx)` reads the signed ownership code. The caller owns
the string and can compare it with `OWNERSHIP_PURCHASED` or
`OWNERSHIP_FAMILY_SHARED`. Release it with `delete(string(ownership))`.

Storefront changes

Start a watch on the main executor when opening the store. Fetch the initial
catalog after starting the watch. Refetch the product IDs and their prices on
each change. Use the product’s price currency for calculations.

```odin
// Keep watch in application state until closed runs.
started := sk.watch_storefront(&watch, store_changed, closed)
if started { refresh_catalog() }

latest_catalog: sk.Task

refresh_catalog :: proc() {
	sk.Product_destroy(pro_product)
	pro_product = nil
	disable_buy_button()
	task, started := sk.products({PRO_ID}, catalog_ready)
	latest_catalog = task
	if !started { show_catalog_unavailable() }
}

catalog_ready :: proc(task: sk.Task, items: []sk.Product, err: sk.Error) {
	defer sk.task_release(task)
	defer sk.products_destroy(items)
	defer sk.Error_destroy(err)
	if task != latest_catalog { return }
	latest_catalog = nil
	if err != nil || len(items) != 1 { show_catalog_unavailable(); return }
	price, ok := sk.Product_display_price(items[0])
	if !ok { show_catalog_unavailable(); return }
	defer delete(price)
	pro_product = items[0]
	items[0] = nil
	show_buy_button(price)
}

store_changed :: proc(_: ^sk.Storefront_Watch, store: sk.Storefront) {
	refresh_catalog()
	id, country, ok := sk.storefront_details(store)
	if !ok { return }
	defer delete(id)
	defer delete(country)
	show_store_region(id, country)
}

closed :: proc(_: ^sk.Storefront_Watch, reason: sk.Listener_End) {
	if reason != .Stopped { report_store_watch_end(reason) }
}
```

The change callback borrows `store`. Use `Storefront_copy` if it must outlive
the callback. `stop_storefront_watch(&watch)` also works inside the callback.
On closing the store, clear `latest_catalog` to discard outstanding catalog
responses, and stop the watch. To read the current region once, call
`current_storefront`. Its callback receives `Maybe(Storefront)` and a
conversion flag. Destroy a present storefront when finished.

[[Setting up StoreKit Testing in Xcode;https://developer.apple.com/documentation/xcode/setting-up-storekit-testing-in-xcode]]

**Purchase cookbook**

Choose the example above by what the customer keeps after paying. Each uses one
package import, `import sk "vendor:darwin/StoreKit"`.

- **Unlock Pro once.** Start with `buy_pro` and `deliver_pro`. Enable the
  feature after a verified purchase. On the next launch rebuild access from
  `.Entitlements`. If several products grant Pro, keep access while any grant
  is valid.
- **Sell 100 credits per pack.** Use `buy_packs(product, 3)` for three packs.
  In `deliver_packs`, credit the *signed* quantity. Commit one ledger row per
  transaction ID before finishing. Buying again creates a new row. Replaying
  the same transaction finds the existing row and can safely retry `finish`.
  Restore the balance from the app's ledger. StoreKit excludes consumables
  from current entitlements.
- **Sell a 30-day pass.** Use `buy_pass`, `refresh_pass` and `has_pass`.
  Derive the deadline from the signed purchase date. Compare the clock with
  that deadline when the feature opens. A finished non-renewing pass can
  still appear in current entitlements after its app-defined term ends.
- **Sell Basic and Plus monthly.** Use `refresh_monthly` and `active_tier`.
  The signed transaction identifies the current tier. The renewal preference
  identifies the next one. An upgrade can replace the current transaction
  immediately. A scheduled downgrade keeps the current tier through its paid
  term. Turning off renewal leaves access in place until the deadline.
  In billing grace, use `access_until`. Outside grace, billing retry alone
  grants no access. Use `watch_subscriptions` to refresh the group when
  StoreKit reports changes, including payment recovery.

**Buy credit packs for a signed-in account**

Pass the stable UUID your app assigned to the account. Release the two options
after starting the purchase. Use the same delivery procedure for the purchase
completion, transaction updates and unfinished transactions.

```odin
import "core:encoding/uuid"

ACCOUNT_PACK_ID :: "com.example.editor.credits"

buy_account_packs :: proc(product: sk.Product, account: uuid.Identifier, units: int) -> bool {
	if !sk.can_make_payments() { return false }
	id := sk.Product_id(product) or_return
	defer delete(id)
	if id != ACCOUNT_PACK_ID { return false }
	quantity := sk.purchase_quantity(units) or_return
	defer sk.Purchase_Option_destroy(quantity)
	token := sk.app_account_token(account) or_return
	defer sk.Purchase_Option_destroy(token)
	task := sk.purchase(product, {quantity, token}, account_packs_purchased) or_return
	sk.task_release(task)
	return true
}

account_packs_purchased :: proc(_: sk.Task, result: sk.Purchase_Result, err: sk.Error) {
	defer sk.Error_destroy(err)
	defer sk.Purchase_Result_destroy(result)
	if err != nil { return }
	if success, ok := result.(sk.Purchase_Success); ok { deliver_account_packs(success.value) }
}

deliver_account_packs :: proc(item: sk.Verification) {
	verified, ok := item.(sk.Verified)
	if !ok { return }
	tx := verified.value
	id, read := sk.Transaction_product_id(tx)
	if !read { return }
	defer delete(id)
	if id != ACCOUNT_PACK_ID { return }
	revoked, checked := sk.Transaction_revocation_date(tx)
	if !checked || revoked != nil { return }
	token, converted := sk.Transaction_app_account_token(tx)
	if !converted { return }
	account, linked := token.?
	if !linked { return }
	units := sk.Transaction_purchased_quantity(tx)
	if units < 1 || units > 10 { return }
	if !credit_account_once(account, sk.Transaction_id(tx), 100 * units) { return }
	if task, started := sk.finish(tx, finished); started { sk.task_release(task) }
}
```

`credit_account_once` is your storage operation. It succeeds when this grant
is committed or the same transaction is already credited to that account.
Use the signed token even if a different customer is now signed in. Define a
claim policy for older purchases with no token. A failed commit leaves the
transaction available for retry.

**Wire a Restore Purchases button**

The 30-day pass can call `refresh_pass` directly at launch. Give the customer
a separate Restore Purchases button for a missing purchase. StoreKit may ask
them to authenticate when the button calls `restore`.

```odin
restore_pass_from_button :: proc() -> bool {
	task := sk.restore(pass_restored) or_return
	sk.task_release(task)
	return true
}

pass_restored :: proc(_: sk.Task, err: sk.Error) {
	defer sk.Error_destroy(err)
	if err != nil {
		fmt.println("Restore failed. Try again.")
		return
	}
	if !refresh_pass() { fmt.println("Refresh access again when the current scan ends.") }
}
```

Disable the button while restoring or scanning. Keep the last verified grant
on failure. Publish the new state when the scan completes. For monthly plans,
use the same button with a completion that refreshes the subscription group:

```odin
monthly_restored :: proc(_: sk.Task, err: sk.Error) {
	defer sk.Error_destroy(err)
	if err != nil {
		fmt.println("Restore failed. Try again.")
		return
	}
	if !refresh_group() { fmt.println("Could not start a subscription refresh") }
}
```

A successful restore means StoreKit finished synchronizing. The verified group
status determines access. For example, someone who turned off renewal yesterday
can still use Plus today if the paid period ends tomorrow. Show the renewal
setting in the billing UI. Gate the feature with `subscription_active`.

**Show a free trial on a monthly plan**

Read the product's offer and check the
customer's eligibility for its group. A group can be eligible even when this
product has no offer. The example keeps one product selected. Call
`check_trial` again when the selection changes, and clear `trial_query` when
the store closes so a late answer cannot update the old button.

```odin
trial_query: sk.Task
trial_period: sk.Billing_Interval

check_trial :: proc(product: sk.Product) -> bool {
	trial_query = nil
	show_regular_price() // App UI, including while eligibility is pending.
	terms := sk.Product_introductory_offer(product) or_return
	offer, present := terms.?
	if !present { return true }
	defer delete(offer.display_price)
	if offer.mode != .Free_Trial || offer.period.unit == .Unknown { return true }
	trial_period = offer.period
	group := sk.subscription_group_id(product) or_return
	defer delete(group)
	trial_query = sk.eligible_for_intro_offer(group, trial_checked) or_return
	return true
}

trial_checked :: proc(task: sk.Task, eligible: bool) {
	defer sk.task_release(task)
	if task != trial_query { return }
	trial_query = nil
	if eligible { show_free_trial(trial_period.count, trial_period.unit) }
}
```

For a paid introduction, show `offer.display_price` and its calendar
`period`. With `.Pay_As_You_Go`, that price applies to each of
`period_count` periods. With `.Pay_Up_Front`, it covers the full offer
period in one payment. Show the regular price and renewal interval alongside
the introduction. For example, Apple's Food Truck monthly plan shows $2.49
per month for three months, then $4.99 per month in its US test store. Use
StoreKit's localized prices in the actual storefront. Keep the regular button
when the mode is unknown. Use the ordinary purchase procedure for the selected
product. [[Food Truck's StoreKit configuration;https://github.com/apple/sample-food-truck/blob/main/App/Store/Products.storekit]]
[[Apple's group eligibility rules;https://developer.apple.com/documentation/storekit/product/subscriptioninfo/iseligibleforintrooffer(for:)]]

**Other cases a store needs to handle**

- **Catalog and pricing.** Match returned `Product_id` values to requested
  SKUs. Leave missing products unavailable. Use `Product_display_name`,
  `Product_description` and `Product_display_price` for merchandising.
  Use `price_and_currency` for exact amounts. Refresh the catalog after
  `watch_storefront` reports a change. `current_storefront` reads it once.
- **Presenting payment.** A Buy button can live in Metal, UIKit or AppKit.
  Call `purchase` to present Apple's confirmation. For an explicit presenter
  use `purchase_confirm_in` with the originating UIKit controller on iOS
  18.2+ or AppKit window on macOS 15.2+.
- **Pending, cancelled, or failed.** `Purchase_Pending` leaves delivery
  waiting for a verified event on `.Updates`. For example, a parent can approve
  an Ask to Buy request after the child closes the app. Start the listener
  again at launch and recover unfinished deliveries. `Purchase_Cancelled` returns
  the UI to idle. A failed start schedules no callback. A thrown error arrives
  in the completion's `err`. Keep access unchanged on unverified results,
  conversion failures and unknown outcomes.
- **Recovery and history.** Listen to `.Updates` while running. Drain
  `.Unfinished` after interruption. Use `scan_transactions` with
  `.Entitlements` for current grants or `.History` for past purchases.
  A product ID narrows the scan. Stop a scan with `stop_scan` and drain its
  close callback before reusing its storage.
- **Refunds, revocation and Family Sharing.** Use `request_refund` from the
  customer's purchase history. The sheet can be submitted, cancelled, or
  return an error such as a duplicate request. Change access when verified
  transaction data shows revocation. `Product_is_family_shareable` describes
  the product. `Transaction_ownership` identifies a particular shared grant.
- **Sending evidence to a server.** Forward the original `Verification_jws`
  when the server verifies a purchase. `Transaction_json_representation` and
  the verification byte getters return owned slices. Preserve their lengths
  and release them after use. For diagnosis, `unverified_details` exposes the
  transaction and reason carried by an unverified result.

**Follow along with Apple's examples**

In [[Meet StoreKit 2;https://developer.apple.com/videos/play/wwdc2021/10114/]],
Apple builds a shop for fuel, cars and navigation plans. For fuel, follow
`deliver_packs` to credit a balance once per transaction. For a car, follow
`deliver_pro` to unlock a permanent feature. For the tiered navigation plans,
follow `refresh_monthly` to determine which features the customer can use today.

Apple's [[store sample;https://developer.apple.com/documentation/storekit/implementing-a-store-in-your-app-using-the-storekit-api]]
shows a catalog backed by signed purchases and a persisted consumable balance.
Apple lists iOS 27 and Xcode 27 for that sample project. The Odin package starts
at iOS 15 and macOS 12. The presentation overloads above have their own minimums.
Compare the Odin callbacks above with Apple's
[[purchase result;https://developer.apple.com/documentation/storekit/product/purchaseresult]],
[[current entitlements;https://developer.apple.com/documentation/storekit/transaction/currententitlements]]
and [[customer-initiated restore;https://developer.apple.com/documentation/storekit/appstore/sync()]].
*/
package darwin_StoreKit
