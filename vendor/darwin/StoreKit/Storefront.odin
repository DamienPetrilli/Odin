#+build darwin arm64
#+vet tabs style semicolon
package darwin_StoreKit

foreign import api "swift:StoreKit"

when AVAILABLE {
	Storefront         :: api.Storefront
	Storefront_copy    :: api.Storefront_copy
	Storefront_destroy :: api.Storefront_destroy

	// Completion owns the optional storefront. An absent storefront is a valid result.
	current_storefront :: api.Storefront_current

	// Both strings belong to the caller. Country code identifies a region, including
	// storefronts whose products use a different currency from that region's own.
	@(require_results)
	storefront_details :: proc(store: Storefront) -> (id, country_code: string, ok: bool) {
		if store == nil { return }
		identifier := api.Storefront_id(store) or_return
		country, converted := api.Storefront_country_code(store)
		if !converted {
			delete(identifier)
			return
		}
		return identifier, country, true
	}

	// Initially zero. Keep the watch at a stable address through on_closed.
	Storefront_Watch :: struct {
		iterator:  api.Storefront_Storefronts_AsyncIterator,
		task:      Task,
		next:      ^Storefront_Watch,
		on_change: proc(^Storefront_Watch, Storefront),
		on_closed: proc(^Storefront_Watch, Listener_End),
		stopping:  bool,
	}

	@(private)
	pending_storefronts: ^Storefront_Watch

	// Call on the main executor. Each change borrows its storefront for the callback.
	// A successful start delivers exactly one on_closed after the last callback.
	@(require_results)
	watch_storefront :: proc(
		watch: ^Storefront_Watch, on_change: proc(^Storefront_Watch, Storefront),
		on_closed: proc(^Storefront_Watch, Listener_End),
	) -> bool {
		if watch == nil || watch.iterator != nil || on_change == nil || on_closed == nil { return false }
		updates := api.Storefront_updates() or_return
		defer api.Storefront_Storefronts_destroy(updates)
		iter := api.Storefront_Storefronts_make_async_iterator(updates) or_return
		watch^ = {iterator = iter, on_change = on_change, on_closed = on_closed}
		if read_storefront(watch) { return true }
		api.Storefront_Storefronts_AsyncIterator_destroy(iter)
		watch^ = {}
		return false
	}

	stop_storefront_watch :: proc(watch: ^Storefront_Watch) {
		if watch == nil || watch.iterator == nil || watch.stopping { return }
		watch.stopping = true
		if watch.task != nil { task_cancel(watch.task) }
	}

	@(private)
	read_storefront :: proc(watch: ^Storefront_Watch) -> bool {
		watch.task = api.Storefront_Storefronts_AsyncIterator_next(watch.iterator, storefront_received) or_return
		watch.next = pending_storefronts
		pending_storefronts = watch
		return true
	}

	@(private)
	storefront_received :: proc(task: Task, result: Maybe(Storefront), converted: bool) {
		watch := take_pending_read(&pending_storefronts, task)
		reason := Listener_End.Exhausted
		if !converted {
			reason = .Conversion_Failed
		} else if store, present := result.?; present {
			if !watch.stopping { watch.on_change(watch, store) }
			Storefront_destroy(store)
			if !watch.stopping {
				if read_storefront(watch) { return }
				reason = .Read_Start_Failed
			}
		}
		if watch.stopping { reason = .Stopped }
		closed := watch.on_closed
		api.Storefront_Storefronts_AsyncIterator_destroy(watch.iterator)
		watch^ = {}
		closed(watch, reason)
	}
}
