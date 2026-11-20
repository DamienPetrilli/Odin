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
		name := sk.Product_display_name(product) or_continue
		defer delete(name)
		description := sk.Product_description(product) or_continue
		defer delete(description)
	}
}

main :: proc() {
	if sk.can_make_payments() {
		if task, started := sk.products(nil, loaded); started {
			sk.task_release(task)
		}
	}
}
