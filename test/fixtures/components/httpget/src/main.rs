// A GET through wasi:http/outgoing-handler: `httpget AUTHORITY PATH` prints
// the status. Without arguments it prints `idle`. A refusal prints
// `refused: <error>` and exits 1. Built for wasm32-wasip2 by
// scripts/build-component-fixtures.sh.
use wasi::http::outgoing_handler;
use wasi::http::types::{Fields, Method, OutgoingRequest, Scheme};

fn http(authority: &str, path: &str) -> Result<String, String> {
    let req = OutgoingRequest::new(Fields::new());
    req.set_method(&Method::Get).map_err(|_| "method")?;
    req.set_scheme(Some(&Scheme::Http)).map_err(|_| "scheme")?;
    req.set_authority(Some(authority)).map_err(|_| "authority")?;
    req.set_path_with_query(Some(path)).map_err(|_| "path")?;
    let fut = outgoing_handler::handle(req, None).map_err(|e| format!("{e:?}"))?;
    fut.subscribe().block();
    let resp = fut
        .get()
        .ok_or("no response")?
        .map_err(|_| "taken")?
        .map_err(|e| format!("{e:?}"))?;
    Ok(format!("{}", resp.status()))
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let result = match args.get(1) {
        Some(authority) => http(authority, args.get(2).map(String::as_str).unwrap_or("/")),
        None => Ok("idle".to_string()),
    };
    match result {
        Ok(out) => println!("{out}"),
        Err(e) => {
            println!("refused: {e}");
            std::process::exit(1);
        }
    }
}
