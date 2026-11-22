// Link-only consumer. The test does not initiate a payment.
package storekit_import_test

import sk "vendor:darwin/StoreKit"

loaded :: proc(task: sk.Task, products: []sk.Product, err: sk.Error) {
	defer sk.Error_destroy(err)
	defer sk.products_destroy(products)
	if purchase_err, ok := err.(sk.Purchase_Error); ok {
		_, _ = purchase_err.(sk.Purchase_Error_Product_Unavailable)
	}
	for product in products {
		kind := sk.Product_type(product) or_continue
		if kind == .Auto_Renewable_Subscription {
			interval := sk.Product_subscription_period(product) or_continue
			assert(interval.count > 0)
		}
		if kind == .Consumable {
			option := sk.purchase_quantity(2) or_continue
			sk.Purchase_Option_destroy(option)
		}
		name := sk.Product_display_name(product) or_continue
		defer delete(name)
		description := sk.Product_description(product) or_continue
		defer delete(description)
	}
}

main :: proc() {
	current, renewal, ok := sk.subscription_products(nil)
	assert(!ok && current == "" && renewal == nil)
	period := sk.Non_Renewing_Period{starts_at = 10, expires_at = 20}
	assert(sk.non_renewing_active(period, 10))
	assert(!sk.non_renewing_active(period, 20))
	assert(!sk.non_renewing_active({}))
	p := sk.Subscription_Period{will_renew = false, starts_at = 10, access_until = 20}
	assert(!sk.subscription_active(p, 9))
	assert(sk.subscription_active(p, 10))
	assert(sk.subscription_active(p, 19))
	assert(!sk.subscription_active(p, 20))
	if sk.can_make_payments() {
		if task, started := sk.products(nil, loaded); started {
			sk.task_release(task)
		}
	}
}
