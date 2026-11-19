// A guest of a host-defined resource: example:kv/store's `bucket`. Built for
// wasm32-wasip2 by scripts/build-component-fixtures.sh.
wit_bindgen::generate!({ world: "app" });

use example::kv::store::{close, describe, open, Bucket};
use std::cell::RefCell;

thread_local! {
    static KEPT: RefCell<Option<Bucket>> = const { RefCell::new(None) };
}

struct C;

impl Guest for C {
    fn fill(name: String, items: Vec<String>) -> String {
        let b = Bucket::new(&name);
        for i in &items {
            b.put(i);
        }
        format!("{} {}", describe(&b), b.count())
    }

    fn fill_and_close(name: String) -> u32 {
        let b = open(&name);
        b.put("one");
        close(b)
    }

    fn keep(name: String) {
        let b = open(&name);
        b.put("kept");
        KEPT.with(|k| *k.borrow_mut() = Some(b));
    }

    fn kept() -> u32 {
        KEPT.with(|k| k.borrow().as_ref().map(|b| b.count()).unwrap_or(0))
    }

    fn forget() {
        KEPT.with(|k| *k.borrow_mut() = None);
    }
}

export!(C);
