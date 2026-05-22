// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// redis_client.rs — Synchronous RESP protocol client for Aerie
//
// Mirrors src/api/v/redis_client.v (184 LOC).
//
// Implements a minimal subset of the Redis Serialization Protocol (RESP)
// over a raw TCP connection. This avoids a heavy Redis crate dependency
// while preserving the same wire protocol as the V implementation.
//
// Supported commands: PING, SET, GET, LPUSH, LTRIM, LRANGE, XADD, XRANGE
//
// The client is used for two purposes:
//   1. Hot cache: GET/SET for recent telemetry responses (30 s TTL)
//   2. Audit log: LPUSH + LTRIM (bounded to 10 000 entries) + XADD to
//      the "aerie:audit" stream for real-time monitoring
//
// Thread safety: RedisClient holds a single TCP connection. In the async
// axum context each request acquires a cloned `Arc<Mutex<RedisClient>>`
// before issuing commands.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::time::Duration;

/// Connection handle and configuration for the Redis RESP client.
///
/// The client connects lazily on first use and reconnects automatically
/// after a broken pipe. All errors are logged to stderr and treated as
/// non-fatal — the caller must not block or crash if Redis is unavailable.
pub struct RedisClient {
    /// Resolved TCP address, e.g. `"redis:6379"` or `"localhost:6379"`
    addr: String,
    /// Live TCP connection, or None when not yet connected / after error
    stream: Option<TcpStream>,
    /// Maximum time to wait for a Redis reply before giving up
    timeout: Duration,
}

impl RedisClient {
    /// Create a new client from the `REDIS_URL` environment variable.
    ///
    /// Accepted formats: `redis://host:port` or bare `host:port`.
    /// Falls back to `redis:6379` (container default) when unset.
    /// Does NOT attempt to connect until the first command.
    pub fn from_env() -> Self {
        let raw = std::env::var("REDIS_URL")
            .unwrap_or_else(|_| "redis:6379".to_string());
        // Strip redis:// scheme prefix if present
        let addr = raw
            .strip_prefix("redis://")
            .unwrap_or(&raw)
            .to_string();
        RedisClient {
            addr,
            stream: None,
            timeout: Duration::from_millis(500),
        }
    }

    /// Ensure a live TCP connection exists. Called before every command.
    /// On any IO error the stream is dropped; the next call retries.
    fn ensure_connected(&mut self) {
        if self.stream.is_some() {
            return;
        }
        match TcpStream::connect(&self.addr) {
            Ok(s) => {
                // Best-effort timeouts — errors are non-fatal
                let _ = s.set_read_timeout(Some(self.timeout));
                let _ = s.set_write_timeout(Some(self.timeout));
                self.stream = Some(s);
            }
            Err(e) => {
                eprintln!("[aerie] redis: connect to {} failed: {}", self.addr, e);
            }
        }
    }

    /// Send a pre-built RESP command and read one reply line.
    ///
    /// Returns `None` on any IO error (connection is dropped and will
    /// be re-established on the next call).
    fn send_command(&mut self, cmd: &[u8]) -> Option<String> {
        self.ensure_connected();
        let stream = self.stream.as_mut()?;

        if let Err(e) = stream.write_all(cmd) {
            eprintln!("[aerie] redis: write failed: {}", e);
            self.stream = None;
            return None;
        }

        // Read one complete RESP reply. We only need the first line for
        // simple string (+OK), integer (:N), bulk header ($N), or error (-ERR).
        let mut reader = BufReader::new(stream.try_clone().ok()?);
        let mut line = String::new();
        if let Err(e) = reader.read_line(&mut line) {
            eprintln!("[aerie] redis: read failed: {}", e);
            self.stream = None;
            return None;
        }

        Some(line.trim_end_matches("\r\n").to_string())
    }

    /// Build a RESP array command from a slice of string arguments.
    ///
    /// RESP encoding: `*N\r\n` followed by N bulk strings `$len\r\ndata\r\n`.
    fn build_resp(args: &[&str]) -> Vec<u8> {
        let mut buf = Vec::with_capacity(128);
        buf.extend_from_slice(format!("*{}\r\n", args.len()).as_bytes());
        for arg in args {
            buf.extend_from_slice(format!("${}\r\n{}\r\n", arg.len(), arg).as_bytes());
        }
        buf
    }

    /// Send PING and return true if the server replies `+PONG`.
    pub fn ping(&mut self) -> bool {
        let cmd = Self::build_resp(&["PING"]);
        matches!(self.send_command(&cmd).as_deref(), Some("+PONG"))
    }

    /// SET key to value with an optional TTL in seconds.
    ///
    /// Uses `SET key value EX ttl` when ttl > 0, plain `SET key value` otherwise.
    pub fn set(&mut self, key: &str, value: &str, ttl_secs: u64) {
        let cmd = if ttl_secs > 0 {
            let ttl = ttl_secs.to_string();
            Self::build_resp(&["SET", key, value, "EX", &ttl])
        } else {
            Self::build_resp(&["SET", key, value])
        };
        if let Some(r) = self.send_command(&cmd) {
            if !r.starts_with('+') {
                eprintln!("[aerie] redis: SET {} returned {}", key, r);
            }
        }
    }

    /// GET a key. Returns `None` if the key is absent or on any error.
    pub fn get(&mut self, key: &str) -> Option<String> {
        let cmd = Self::build_resp(&["GET", key]);
        let header = self.send_command(&cmd)?;

        if header == "$-1" {
            // RESP null bulk string — key not found
            return None;
        }

        if !header.starts_with('$') {
            eprintln!("[aerie] redis: GET {} unexpected reply {}", key, header);
            return None;
        }

        // Parse the byte count from the bulk string header
        let byte_count: usize = header[1..].parse().ok()?;
        let stream = self.stream.as_mut()?;

        // Read exactly byte_count bytes plus the trailing \r\n
        let mut buf = vec![0u8; byte_count + 2];
        if let Err(e) = stream.read_exact(&mut buf) {
            eprintln!("[aerie] redis: GET {} body read failed: {}", key, e);
            self.stream = None;
            return None;
        }

        String::from_utf8(buf[..byte_count].to_vec()).ok()
    }

    /// LPUSH value onto list key (prepend). Returns false on error.
    pub fn lpush(&mut self, key: &str, value: &str) -> bool {
        let cmd = Self::build_resp(&["LPUSH", key, value]);
        matches!(self.send_command(&cmd).as_deref(), Some(s) if s.starts_with(':'))
    }

    /// LTRIM list to keep only the first `max_len` entries.
    /// Used to keep the audit list bounded (≤10 000 entries).
    pub fn ltrim(&mut self, key: &str, max_len: usize) {
        let stop = (max_len - 1).to_string();
        let cmd = Self::build_resp(&["LTRIM", key, "0", &stop]);
        if let Some(r) = self.send_command(&cmd) {
            if !r.starts_with('+') {
                eprintln!("[aerie] redis: LTRIM {} returned {}", key, r);
            }
        }
    }

    /// LRANGE — retrieve `count` entries from list key starting at `offset`.
    ///
    /// Returns an empty Vec on error. Entries are returned in LIFO order
    /// because LPUSH prepends; the newest entry is at index 0.
    pub fn lrange(&mut self, key: &str, offset: usize, count: usize) -> Vec<String> {
        let start = offset.to_string();
        let stop = (offset + count - 1).to_string();
        let cmd = Self::build_resp(&["LRANGE", key, &start, &stop]);

        let header = match self.send_command(&cmd) {
            Some(h) => h,
            None => return vec![],
        };

        if !header.starts_with('*') {
            eprintln!("[aerie] redis: LRANGE {} unexpected reply {}", key, header);
            return vec![];
        }

        let n: usize = match header[1..].parse() {
            Ok(n) => n,
            Err(_) => return vec![],
        };

        let stream = match self.stream.as_mut() {
            Some(s) => s,
            None => return vec![],
        };

        let mut results = Vec::with_capacity(n);
        let mut reader = BufReader::new(stream.try_clone().unwrap());

        for _ in 0..n {
            let mut size_line = String::new();
            if reader.read_line(&mut size_line).is_err() {
                break;
            }
            let size_line = size_line.trim_end_matches("\r\n");
            if !size_line.starts_with('$') {
                continue;
            }
            let byte_count: usize = match size_line[1..].parse() {
                Ok(b) => b,
                Err(_) => continue,
            };
            let mut buf = vec![0u8; byte_count + 2];
            if reader.read_exact(&mut buf).is_err() {
                break;
            }
            if let Ok(s) = String::from_utf8(buf[..byte_count].to_vec()) {
                results.push(s);
            }
        }

        results
    }

    /// XADD to stream key — appends an entry with auto-generated ID.
    ///
    /// `fields` is a flat slice of alternating field-name / value pairs.
    /// Used to fan audit events into the `"aerie:audit"` stream for
    /// real-time monitoring by Observatory.
    pub fn xadd(&mut self, key: &str, fields: &[(&str, &str)]) {
        if fields.is_empty() {
            return;
        }
        let mut args: Vec<&str> = vec!["XADD", key, "*"];
        for (k, v) in fields {
            args.push(k);
            args.push(v);
        }
        let cmd = Self::build_resp(&args);
        if let Some(r) = self.send_command(&cmd) {
            if r.starts_with('-') {
                eprintln!("[aerie] redis: XADD {} error: {}", key, r);
            }
        }
    }

    /// Log an audit event to both the bounded list and the audit stream.
    ///
    /// List key: `"aerie:audit"` — bounded to `AUDIT_LIST_CAP` entries.
    /// Stream key: `"aerie:audit:stream"` — unbounded (ObserVatory manages TTL).
    pub fn log_audit(&mut self, event_json: &str) {
        const AUDIT_LIST_CAP: usize = 10_000;
        const LIST_KEY: &str = "aerie:audit";
        const STREAM_KEY: &str = "aerie:audit:stream";

        self.lpush(LIST_KEY, event_json);
        self.ltrim(LIST_KEY, AUDIT_LIST_CAP);
        self.xadd(STREAM_KEY, &[("event", event_json)]);
    }
}
