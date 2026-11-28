// A request through wasi:http/outgoing-handler: `httpget AUTHORITY PATH
// [BODY [HEADER]]` prints the status. BODY bytes of body make it a POST, and
// HEADER adds a header with a value of that many bytes. Without arguments it
// prints `idle`. A refusal prints `refused: <error>` and exits 1. Built for
// wasm32-wasip2 by
// scripts/build-component-fixtures.sh.
use wasi::http::outgoing_handler;
use wasi::http::types::{Fields, Method, OutgoingBody, OutgoingRequest, Scheme};

fn http(authority: &str, path: &str, body: usize, header: usize) -> Result<String, String> {
    let fields = Fields::new();
    if header > 0 {
        fields
            .append("x-long", &vec![b'a'; header])
            .map_err(|e| format!("{e:?}"))?;
    }
    let req = OutgoingRequest::new(fields);
    let method = if body > 0 { Method::Post } else { Method::Get };
    req.set_method(&method).map_err(|_| "method")?;
    req.set_scheme(Some(&Scheme::Http)).map_err(|_| "scheme")?;
    req.set_authority(Some(authority)).map_err(|_| "authority")?;
    req.set_path_with_query(Some(path)).map_err(|_| "path")?;
    let out = req.body().map_err(|_| "body")?;
    let fut = outgoing_handler::handle(req, None).map_err(|e| format!("{e:?}"))?;
    {
        let stream = out.write().map_err(|_| "stream")?;
        // the host takes at most 4096 bytes a write
        for chunk in vec![b'b'; body].chunks(4096) {
            // a failed write shows in the response future, which says why
            if stream.blocking_write_and_flush(chunk).is_err() {
                break;
            }
        }
    }
    let finished = OutgoingBody::finish(out, None);
    fut.subscribe().block();
    let resp = fut
        .get()
        .ok_or("no response")?
        .map_err(|_| "taken")?
        .map_err(|e| format!("{e:?}"))?;
    finished.map_err(|e| format!("{e:?}"))?;
    Ok(format!("{}", resp.status()))
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let number = |i: usize| args.get(i).and_then(|a| a.parse().ok()).unwrap_or(0);
    let result = match args.get(1) {
        Some(authority) => http(
            authority,
            args.get(2).map(String::as_str).unwrap_or("/"),
            number(3),
            number(4),
        ),
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
