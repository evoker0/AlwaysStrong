// asfetch — AlwaysStrong native HTTPS fetcher.
//
// Why this exists: the module runs on devices that ship no `curl` and only
// busybox `wget`, whose built-in TLS stalls mid-stream on some CDNs (e.g. the
// keybox mirror) even though the same wget downloads from Google/GitHub fine.
// A statically-linked rustls client speaks TLS 1.2/1.3 correctly everywhere,
// so keybox_fetch.sh / status_fetch.sh can rely on it instead of the shell
// download tools.
//
// Usage:  asfetch URL [-o FILE] [-A USER_AGENT] [-T SECONDS]
//   no -o  -> body is written to stdout
//   exit 0 on HTTP 2xx, non-zero otherwise (so callers can `|| fallback`).

use std::io::Write;
use std::process::exit;

fn main() {
    let args: Vec<String> = std::env::args().collect();

    let mut url: Option<String> = None;
    let mut out: Option<String> = None;
    let mut ua = String::from("Mozilla/5.0 (Linux; Android) asfetch/1.0");
    let mut timeout: u64 = 30;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "-o" => {
                i += 1;
                out = args.get(i).cloned();
            }
            "-A" | "-U" => {
                i += 1;
                if let Some(v) = args.get(i) {
                    ua = v.clone();
                }
            }
            "-T" | "-t" => {
                i += 1;
                if let Some(v) = args.get(i) {
                    timeout = v.parse().unwrap_or(30);
                }
            }
            "-h" | "--help" => {
                eprintln!("usage: asfetch URL [-o FILE] [-A USER_AGENT] [-T SECONDS]");
                exit(2);
            }
            s if !s.starts_with('-') => url = Some(s.to_string()),
            _ => { /* ignore unknown flags */ }
        }
        i += 1;
    }

    let url = match url {
        Some(u) => u,
        None => {
            eprintln!("asfetch: no URL given");
            exit(2);
        }
    };

    // minreq follows redirects on its own; with_timeout bounds the whole call
    // so a stalled connection can never hang the Action button.
    let resp = match minreq::get(&url)
        .with_header("User-Agent", ua)
        .with_header("Accept", "*/*")
        .with_timeout(timeout)
        .send()
    {
        Ok(r) => r,
        Err(e) => {
            eprintln!("asfetch: {url}: {e}");
            exit(1);
        }
    };

    if !(200..300).contains(&resp.status_code) {
        eprintln!("asfetch: {url}: HTTP {}", resp.status_code);
        exit(1);
    }

    let body = resp.as_bytes();
    match out {
        Some(path) => {
            if let Err(e) = std::fs::write(&path, body) {
                eprintln!("asfetch: write {path}: {e}");
                exit(1);
            }
        }
        None => {
            let _ = std::io::stdout().write_all(body);
        }
    }
    exit(0);
}
