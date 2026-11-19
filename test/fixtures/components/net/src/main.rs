// What a component can reach through wasi:sockets, by the command line:
//   tcp HOST:PORT   connect, send a line, print the reply
//   resolve NAME    wasi:sockets/ip-name-lookup through std
// A refusal prints `refused: <error>` and exits 1. Built for wasm32-wasip2
// by scripts/build-component-fixtures.sh.
use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};

fn tcp(addr: &str) -> Result<String, String> {
    let mut s = TcpStream::connect(addr).map_err(|e| e.to_string())?;
    s.write_all(b"ping\n").map_err(|e| e.to_string())?;
    let mut buf = [0u8; 64];
    let n = s.read(&mut buf).map_err(|e| e.to_string())?;
    Ok(String::from_utf8_lossy(&buf[..n]).trim().to_string())
}

fn resolve(name: &str) -> Result<String, String> {
    let n = (name, 80).to_socket_addrs().map_err(|e| e.to_string())?.count();
    Ok(format!("{}", n > 0))
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let arg = |i: usize| args.get(i).map(String::as_str).unwrap_or("");
    let result = match arg(1) {
        "tcp" => tcp(arg(2)),
        "resolve" => resolve(arg(2)),
        _ => Ok("idle".to_string()),
    };
    match result {
        Ok(out) => println!("{out}"),
        Err(e) => {
            println!("refused: {e}");
            std::process::exit(1);
        }
    }
}
