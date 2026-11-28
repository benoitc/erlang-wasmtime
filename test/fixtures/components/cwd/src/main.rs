// What wasi:cli/environment answers for the initial directory, or `none`.
// Built for wasm32-wasip2 by scripts/build-component-fixtures.sh.
fn main() {
    match wasi::cli::environment::initial_cwd() {
        Some(path) => println!("{path}"),
        None => println!("none"),
    }
}
