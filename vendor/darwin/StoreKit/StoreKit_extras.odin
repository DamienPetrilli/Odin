#+build darwin arm64
#+vet tabs style semicolon
package darwin_StoreKit

foreign import api "swift:StoreKit"

when AVAILABLE {
	Transaction_Stream :: enum { Updates, Entitlements, Unfinished }
	Listener_End :: enum { Exhausted, Stopped, Conversion_Failed, Read_Start_Failed }

	// Caller-owned, initially zero. Keep its address stable through on_closed.
	// All calls and callbacks use the main executor. Read stream in either callback.
	Transaction_Listener :: struct {
		iterator:  api.Transaction_Transactions_AsyncIterator,
		task:      Task,
		next:      ^Transaction_Listener,
		stream:    Transaction_Stream,
		on_item:   proc(^Transaction_Listener, Verification),
		on_closed: proc(^Transaction_Listener, Listener_End),
		stopping:  bool,
	}

	// The importer supplies the completing task. Link only listeners with an
	// outstanding read. No allocation or change to the caller's Odin context.
	@(private)
	pending: ^Transaction_Listener

	is_listening :: proc(l: ^Transaction_Listener) -> bool {
		return l != nil && l.iterator != nil
	}

	// False schedules no callbacks. A successful start gives one on_closed.
	// on_item borrows the verification and its payload until it returns.
	@(require_results)
	listen :: proc(
		l:         ^Transaction_Listener,
		stream:    Transaction_Stream,
		on_item:   proc(^Transaction_Listener, Verification),
		on_closed: proc(^Transaction_Listener, Listener_End),
	) -> bool {
		if l == nil || is_listening(l) || on_item == nil || on_closed == nil { return false }
		sequence: api.Transaction_Transactions
		switch stream {
		case .Updates:      sequence = api.Transaction_updates() or_return
		case .Entitlements: sequence = api.Transaction_current_entitlements() or_return
		case .Unfinished:   sequence = api.Transaction_unfinished() or_return
		}
		if !listen_sequence(l, sequence, on_item, on_closed) { return false }
		l.stream = stream
		return true
	}

	@(private)
	listen_sequence :: proc(
		l: ^Transaction_Listener, sequence: api.Transaction_Transactions,
		on_item: proc(^Transaction_Listener, Verification), on_closed: proc(^Transaction_Listener, Listener_End),
	) -> bool {
		defer api.Transaction_Transactions_destroy(sequence)
		iterator := api.Transaction_Transactions_make_async_iterator(sequence) or_return
		l^ = {iterator = iterator, stream = l.stream, on_item = on_item, on_closed = on_closed}
		if listener_read(l) { return true }
		listener_clear(l)
		return false
	}

	// Safe inside on_item. A pending Swift read drains before on_closed runs.
	stop_listening :: proc(l: ^Transaction_Listener) {
		if !is_listening(l) || l.stopping { return }
		l.stopping = true
		if l.task != nil { task_cancel(l.task) }
	}

	@(private)
	listener_read :: proc(l: ^Transaction_Listener) -> bool {
		assert(l.task == nil && !l.stopping)
		l.task = api.Transaction_Transactions_AsyncIterator_next(l.iterator, listener_received) or_return
		l.next = pending
		pending = l
		return true
	}

	@(private)
	listener_clear :: proc(l: ^Transaction_Listener) {
		assert(l.task == nil)
		api.Transaction_Transactions_AsyncIterator_destroy(l.iterator)
		l^ = {stream = l.stream}
	}

	@(private)
	take_pending_read :: proc(head: ^^$L, task: Task) -> ^L {
		link := head
		for link^ != nil && link^.task != task { link = &link^.next }
		l := link^
		assert(l != nil)
		link^ = l.next
		l.next = nil
		task_release(l.task)
		l.task = nil
		return l
	}

	@(private)
	stop_watch :: proc(watch: ^$W) {
		if watch == nil || watch.iterator == nil || watch.stopping { return }
		watch.stopping = true
		if watch.task != nil { task_cancel(watch.task) }
	}

	@(private)
	deliver_watch_update :: proc(
		watch: ^$W, result: Maybe($T), converted: bool,
		$destroy: proc(T), $read: proc(^W) -> bool, $destroy_iterator: $F,
	) {
		reason := Listener_End.Exhausted
		if !converted {
			reason = .Conversion_Failed
		} else if value, present := result.?; present {
			if !watch.stopping { watch.on_change(watch, value) }
			destroy(value)
			if !watch.stopping {
				if read(watch) { return }
				reason = .Read_Start_Failed
			}
		}
		if watch.stopping { reason = .Stopped }
		closed := watch.on_closed
		destroy_iterator(watch.iterator)
		watch^ = {}
		closed(watch, reason)
	}

	@(private)
	listener_received :: proc(task: Task, result: Maybe(Verification), converted: bool) {
		l := take_pending_read(&pending, task)
		reason := Listener_End.Exhausted
		if !converted {
			reason = .Conversion_Failed
		} else if value, present := result.?; present {
			{
				defer api.VerificationResult_Transaction_destroy(value)
				if !l.stopping { l.on_item(l, value) }
			}
			if !l.stopping {
				if listener_read(l) { return }
				reason = .Read_Start_Failed
			}
		}
		if l.stopping { reason = .Stopped }
		closed := l.on_closed
		listener_clear(l)
		closed(l, reason)
	}
}
