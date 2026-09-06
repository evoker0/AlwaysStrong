// asfetch — AlwaysStrong native HTTPS fetcher.
//
// Why this exists: the module runs on devices that ship no `curl` and only
// busybox `wget`, whose built-in TLS stalls mid-stream on some CDNs. A
// statically-linked rustls client speaks TLS 1.2/1.3 correctly there.
//
// Why it's hand-rolled instead of using an HTTP crate: connectivity on real
// phones is lopsided in both directions — an IPv4-only data link that still
// advertises AAAA, and an IPv6-only / NAT64 link where the IPv4 addresses are the
// dead ones. A client that commits to one family first hangs on the unroutable
// SYN and never reaches the working address. We resolve every address ourselves
// and race IPv4 + IPv6 concurrently (Happy-Eyeballs), taking the first socket that
// connects. main() also retries once on the opposite scheme (https <-> http), so
// a blocked :443 or an http-only path still lands the download.
//
// Usage:  asfetch URL [-o|-O FILE] [-A USER_AGENT] [-H "Key: Value"]... [-T SECONDS]
//   no -o  -> body is written to stdout
//   -H may be repeated to send extra request headers (e.g. a Referer).
//   exit 0 on HTTP 2xx, non-zero otherwise (so callers can `|| fallback`).

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::process::exit;
use std::sync::Arc;
use std::time::Duration;

mod autopif;

struct Url {
    https: bool,
    host: String,
    port: u16,
    path: String,
}

fn parse_url(u: &str) -> Option<Url> {
    let (scheme, rest) = match u.split_once("://") {
        Some((s, r)) => (s.to_ascii_lowercase(), r),
        None => ("http".to_string(), u),
    };
    let https = scheme == "https";
    let (authority, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "/"),
    };
    // strip any userinfo@ (not used by our endpoints, but be safe)
    let authority = authority.rsplit('@').next().unwrap_or(authority);
    let (host, port) = match authority.rsplit_once(':') {
        // guard against IPv6 literals like [::1] — our URLs never use them
        Some((h, p)) if !h.contains(':') && p.chars().all(|c| c.is_ascii_digit()) && !p.is_empty() => {
            (h.to_string(), p.parse().unwrap_or(if https { 443 } else { 80 }))
        }
        _ => (authority.to_string(), if https { 443 } else { 80 }),
    };
    if host.is_empty() {
        return None;
    }
    Some(Url { https, host, port, path: path.to_string() })
}

// Resolve host:port to every address, IPv4 and IPv6 interleaved so both families
// are represented up front. We used to return IPv4-only-first and connect
// sequentially; that fixed the "IPv4-only link that still advertises AAAA" hang
// but broke the mirror image of it — an IPv6-only / NAT64 mobile data connection,
// where the IPv4 addresses are the dead ones and burning their timeouts first
// could sink the whole fetch. Interleaving + the concurrent connect below make
// both directions work.
fn resolve_all(host: &str, port: u16) -> Vec<SocketAddr> {
    let mut v4 = Vec::new();
    let mut v6 = Vec::new();
    if let Ok(iter) = (host, port).to_socket_addrs() {
        for a in iter {
            if a.is_ipv4() {
                v4.push(a);
            } else {
                v6.push(a);
            }
        }
    }
    let mut out = Vec::with_capacity(v4.len() + v6.len());
    let (mut i, mut j) = (0usize, 0usize);
    while i < v4.len() || j < v6.len() {
        if i < v4.len() {
            out.push(v4[i]);
            i += 1;
        }
        if j < v6.len() {
            out.push(v6[j]);
            j += 1;
        }
    }
    out
}

// Connect to whichever address answers first, racing IPv4 and IPv6 concurrently
// (Happy-Eyeballs style). A dead address family — IPv4 on an IPv6-only data
// connection, or an AAAA that doesn't route — no longer blocks the request behind
// a full per-address timeout: every candidate dials in its own thread and the
// first successful socket wins; the losers are abandoned.
fn connect(addrs: &[SocketAddr], per_timeout: Duration) -> std::io::Result<TcpStream> {
    use std::sync::mpsc;
    if addrs.is_empty() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::Other,
            "no addresses resolved",
        ));
    }
    let (tx, rx) = mpsc::channel();
    for a in addrs.iter().cloned() {
        let tx = tx.clone();
        std::thread::spawn(move || {
            let _ = tx.send(TcpStream::connect_timeout(&a, per_timeout));
        });
    }
    drop(tx); // so rx closes once every dialer thread has reported
    let mut last = std::io::Error::new(std::io::ErrorKind::Other, "connect failed");
    while let Ok(r) = rx.recv() {
        match r {
            Ok(s) => return Ok(s),
            Err(e) => last = e,
        }
    }
    Err(last)
}

// Read to EOF, tolerating an unclean TLS close (no close_notify) and a read
// timeout — return whatever arrived rather than erroring.
fn read_all<R: Read>(mut r: R) -> Vec<u8> {
    let mut out = Vec::new();
    let mut buf = [0u8; 16384];
    loop {
        match r.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => out.extend_from_slice(&buf[..n]),
            Err(e) => match e.kind() {
                std::io::ErrorKind::UnexpectedEof
                | std::io::ErrorKind::WouldBlock
                | std::io::ErrorKind::TimedOut
                | std::io::ErrorKind::Interrupted => break,
                _ => break,
            },
        }
    }
    out
}

fn tls_config() -> Arc<rustls::ClientConfig> {
    let mut roots = rustls::RootCertStore::empty();
    roots.add_trust_anchors(webpki_roots::TLS_SERVER_ROOTS.iter().map(|ta| {
        rustls::OwnedTrustAnchor::from_subject_spki_name_constraints(
            ta.subject,
            ta.spki,
            ta.name_constraints,
        )
    }));
    Arc::new(
        rustls::ClientConfig::builder()
            .with_safe_defaults()
            .with_root_certificates(roots)
            .with_no_client_auth(),
    )
}

fn build_request(url: &Url, ua: &str, headers: &[(String, String)]) -> Vec<u8> {
    let host_hdr = if (url.https && url.port == 443) || (!url.https && url.port == 80) {
        url.host.clone()
    } else {
        format!("{}:{}", url.host, url.port)
    };
    let mut req = format!(
        "GET {} HTTP/1.1\r\nHost: {}\r\nUser-Agent: {}\r\nAccept: */*\r\nAccept-Encoding: identity\r\nConnection: close\r\n",
        url.path, host_hdr, ua
    );
    for (k, v) in headers {
        req.push_str(&format!("{k}: {v}\r\n"));
    }
    req.push_str("\r\n");
    req.into_bytes()
}

// Split raw response into (status_code, lowercased-header-block, body).
fn split_response(raw: &[u8]) -> Option<(u16, String, Vec<u8>)> {
    let sep = raw.windows(4).position(|w| w == b"\r\n\r\n")?;
    let head = String::from_utf8_lossy(&raw[..sep]);
    let body = raw[sep + 4..].to_vec();
    let mut lines = head.split("\r\n");
    let status_line = lines.next()?;
    let code: u16 = status_line.split_whitespace().nth(1)?.parse().ok()?;
    let headers = head.to_ascii_lowercase();
    Some((code, headers, body))
}

fn header_value(headers_lower: &str, name: &str) -> Option<String> {
    for line in headers_lower.split("\r\n") {
        if let Some((k, v)) = line.split_once(':') {
            if k.trim() == name {
                return Some(v.trim().to_string());
            }
        }
    }
    None
}

// De-chunk a Transfer-Encoding: chunked body.
fn dechunk(body: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < body.len() {
        let line_end = match body[i..].windows(2).position(|w| w == b"\r\n") {
            Some(p) => i + p,
            None => break,
        };
        let size_str = String::from_utf8_lossy(&body[i..line_end]);
        let size_hex = size_str.split(';').next().unwrap_or("").trim();
        let size = usize::from_str_radix(size_hex, 16).unwrap_or(0);
        i = line_end + 2;
        if size == 0 {
            break;
        }
        if i + size > body.len() {
            out.extend_from_slice(&body[i..]);
            break;
        }
        out.extend_from_slice(&body[i..i + size]);
        i += size + 2; // skip data + trailing CRLF
    }
    out
}

// Resolve a redirect Location against the current URL.
fn redirect_target(cur: &Url, loc: &str) -> Option<String> {
    if loc.starts_with("http://") || loc.starts_with("https://") {
        Some(loc.to_string())
    } else if let Some(rest) = loc.strip_prefix('/') {
        let scheme = if cur.https { "https" } else { "http" };
        Some(format!("{scheme}://{}:{}/{rest}", cur.host, cur.port))
    } else {
        None
    }
}

// Swap a URL's scheme (https <-> http) for the one-shot retry in main(): some
// networks/devices break one scheme (TLS MITM, a blocked :443, an http-only
// captive relay) while the other works. Returns None for a scheme-less URL.
fn swap_scheme(u: &str) -> Option<String> {
    if let Some(rest) = u.strip_prefix("https://") {
        Some(format!("http://{rest}"))
    } else if let Some(rest) = u.strip_prefix("http://") {
        Some(format!("https://{rest}"))
    } else {
        None
    }
}

fn fetch(
    start_url: &str,
    ua: &str,
    headers: &[(String, String)],
    timeout: Duration,
) -> Result<Vec<u8>, String> {
    let per_connect = std::cmp::min(timeout, Duration::from_secs(6));
    let mut current = start_url.to_string();
    for _ in 0..8 {
        let url = parse_url(&current).ok_or_else(|| format!("bad url: {current}"))?;
        let addrs = resolve_all(&url.host, url.port);
        if addrs.is_empty() {
            return Err(format!("{}: could not resolve", url.host));
        }
        let tcp = connect(&addrs, per_connect).map_err(|e| format!("{}: {e}", url.host))?;
        let _ = tcp.set_read_timeout(Some(timeout));
        let _ = tcp.set_write_timeout(Some(timeout));
        let req = build_request(&url, ua, headers);

        let raw = if url.https {
            let sni = rustls::ServerName::try_from(url.host.as_str())
                .map_err(|_| format!("{}: bad TLS name", url.host))?;
            let conn = rustls::ClientConnection::new(tls_config(), sni)
                .map_err(|e| format!("tls init: {e}"))?;
            let mut tls = rustls::StreamOwned::new(conn, tcp);
            tls.write_all(&req).map_err(|e| format!("write: {e}"))?;
            let _ = tls.flush();
            read_all(&mut tls)
        } else {
            let mut s = tcp;
            s.write_all(&req).map_err(|e| format!("write: {e}"))?;
            let _ = s.flush();
            read_all(&mut s)
        };

        let (code, headers_lower, body) =
            split_response(&raw).ok_or_else(|| "malformed HTTP response".to_string())?;

        if (300..400).contains(&code) {
            if let Some(loc) = header_value(&headers_lower, "location") {
                if let Some(next) = redirect_target(&url, &loc) {
                    current = next;
                    continue;
                }
            }
            return Err(format!("HTTP {code} (unfollowable redirect)"));
        }
        if !(200..300).contains(&code) {
            return Err(format!("HTTP {code}"));
        }

        let is_chunked = header_value(&headers_lower, "transfer-encoding")
            .map(|v| v.contains("chunked"))
            .unwrap_or(false);
        return Ok(if is_chunked { dechunk(&body) } else { body });
    }
    Err("too many redirects".to_string())
}

// --diag URL : isolate DNS vs raw TCP connect (std only) for debugging a device.
fn diag(url: &str) {
    use std::time::Instant;
    let u = match parse_url(url) {
        Some(u) => u,
        None => {
            eprintln!("diag: bad url");
            return;
        }
    };
    eprintln!("diag: target {}:{}", u.host, u.port);
    let t = Instant::now();
    let addrs = resolve_all(&u.host, u.port);
    eprintln!("diag: resolve in {:?} -> {:?}", t.elapsed(), addrs);
    for a in addrs {
        let t2 = Instant::now();
        match TcpStream::connect_timeout(&a, Duration::from_secs(6)) {
            Ok(_) => eprintln!("diag: connect {a} OK in {:?}", t2.elapsed()),
            Err(e) => eprintln!("diag: connect {a} ERR in {:?}: {e}", t2.elapsed()),
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.len() >= 2 && args[1] == "autopif" {
        exit(autopif::run(&args[2..]));
    }

    if args.len() >= 3 && args[1] == "--diag" {
        diag(&args[2]);
        return;
    }

    let mut url: Option<String> = None;
    let mut out: Option<String> = None;
    let mut ua = String::from("Mozilla/5.0 (Linux; Android) asfetch/1.0");
    let mut headers: Vec<(String, String)> = Vec::new();
    let mut timeout: u64 = 30;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "-o" | "-O" => {
                i += 1;
                out = args.get(i).cloned();
            }
            "-H" | "--header" => {
                i += 1;
                if let Some(v) = args.get(i) {
                    if let Some((k, val)) = v.split_once(':') {
                        headers.push((k.trim().to_string(), val.trim().to_string()));
                    }
                }
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
                eprintln!("usage: asfetch URL [-o|-O FILE] [-A USER_AGENT] [-H \"Key: Value\"]... [-T SECONDS]");
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

    let body = match fetch(&url, &ua, &headers, Duration::from_secs(timeout)) {
        Ok(b) => b,
        Err(e1) => {
            // Retry once on the other scheme before giving up, so a device that
            // can reach the mirror over http but not https (or vice-versa) still
            // gets the keybox.
            match swap_scheme(&url) {
                Some(alt) => match fetch(&alt, &ua, &headers, Duration::from_secs(timeout)) {
                    Ok(b) => b,
                    Err(e2) => {
                        eprintln!("asfetch: {url}: {e1}; retry {alt}: {e2}");
                        exit(1);
                    }
                },
                None => {
                    eprintln!("asfetch: {url}: {e1}");
                    exit(1);
                }
            }
        }
    };

    match out {
        Some(path) => {
            if let Err(e) = std::fs::write(&path, &body) {
                eprintln!("asfetch: write {path}: {e}");
                exit(1);
            }
        }
        None => {
            let _ = std::io::stdout().write_all(&body);
        }
    }
    exit(0);
}
