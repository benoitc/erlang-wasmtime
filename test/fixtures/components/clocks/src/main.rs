// Reads the clock named on the command line and prints it:
// `wall` (SystemTime, wasi:clocks/wall-clock) or `mono` (Instant, and a
// sleep, wasi:clocks/monotonic-clock). Built for wasm32-wasip2 by
// scripts/build-component-fixtures.sh.
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

fn main() {
    match std::env::args().nth(1).as_deref() {
        Some("wall") => {
            let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap();
            println!("wall {}", now.as_secs());
        }
        _ => {
            let t0 = Instant::now();
            std::thread::sleep(Duration::from_millis(5));
            println!("mono {}", t0.elapsed() >= Duration::from_millis(5));
        }
    }
}
