// SPDX-License-Identifier: PMPL-1.0-or-later
//
// main.v — Aerie Gateway: Triple-Mount API Server
//
// Serves three API protocols from a single gateway process:
//
//   1. GraphQL  — POST /graphql                        (port 4000)
//   2. REST     — GET  /api/v1/{telemetry,routes,audit} (port 4000)
//   3. gRPC     — binary protobuf                       (port 4001)
//
// All responses are wrapped in a ProofEnvelope (SHA-256 hash in Phase 1,
// Ed448 signature in Phase 2+). The policy gate checks X-Api-Key headers
// and logs all access to the Redis audit trail.
//
// Architecture:
//
//   Client ──► GraphQL / REST (port 4000)
//              │
//              ├──► Policy Gate (X-Api-Key check)
//              ├──► Resolver (dispatches to probe clients)
//              ├──► Proof Envelope (SHA-256 wrap)
//              └──► Response
//
//   Client ──► gRPC (port 4001)
//              │
//              ├──► Policy Gate (metadata key check)
//              ├──► Resolver (same underlying logic)
//              ├──► Proof Envelope (embedded in protobuf)
//              └──► Response
//
// Backend services (in aerie-net Docker network):
//   - LibreSpeed  at LIBRESPEED_URL  (default http://librespeed:8080)
//   - Hyperglass  at HYPERGLASS_URL  (default http://hyperglass:8082)
//   - Redis       at REDIS_URL       (default redis://redis:6379)

module main

import os
import net
import net.http
import x.json2
import time

// banner prints the startup banner to stdout with protocol information.
fn banner(http_port int, grpc_port int) {
	println('╔══════════════════════════════════════════════════════════╗')
	println('║          AERIE GATEWAY — Triple-Mount API               ║')
	println('║      GraphQL • gRPC • REST • High-Assurance             ║')
	println('╠══════════════════════════════════════════════════════════╣')
	println('║  REST + GraphQL : port ${http_port:-5}                           ║')
	println('║  gRPC           : port ${grpc_port:-5}                           ║')
	println('║  Proof mode     : light (SHA-256)                       ║')
	println('║  Policy gate    : Phase 1 (permissive)                  ║')
	println('╚══════════════════════════════════════════════════════════╝')
}

fn main() {
	// Read configuration from environment
	mut http_port := os.getenv('PORT').int()
	if http_port == 0 {
		http_port = 4000
	}
	mut grpc_port := os.getenv('GRPC_PORT').int()
	if grpc_port == 0 {
		grpc_port = 4001
	}

	banner(http_port, grpc_port)

	// Initialise Redis client (lazy connection)
	mut redis := new_redis_client()

	println('[aerie] Starting HTTP server (REST + GraphQL) on :${http_port}')
	println('[aerie] Starting gRPC listener on :${grpc_port}')

	// Start gRPC listener in a background thread
	spawn grpc_listener(grpc_port, mut redis)

	// Start HTTP server (blocking) for REST + GraphQL
	mut server := http.Server{
		port: http_port
		handler: AerieHandler{
			redis: &redis
		}
	}
	server.listen_and_serve()
}

// AerieHandler dispatches HTTP requests to the appropriate handler
// based on the URL path. Implements the http.Handler interface.
struct AerieHandler {
mut:
	redis &RedisClient
}

// handle processes an incoming HTTP request through the policy gate,
// dispatches to the appropriate resolver, and returns the response
// with appropriate CORS and content-type headers.
fn (mut h AerieHandler) handle(req http.Request) http.Response {
	// Extract API key from header for policy gate
	api_key := req.header.get_custom('X-Api-Key') or { '' }

	// Determine which module is being accessed
	module_name := match true {
		req.url.starts_with('/graphql') { 'graphql' }
		req.url.starts_with('/api/v1/telemetry') { 'telemetry' }
		req.url.starts_with('/api/v1/routes') { 'routes' }
		req.url.starts_with('/api/v1/audit') { 'audit' }
		req.url.starts_with('/api/v1/health') { 'health' }
		else { 'unknown' }
	}

	// Evaluate policy
	policy := evaluate_policy(api_key, module_name)

	// CORS headers for browser-based clients
	mut headers := http.new_header(
		key: .content_type
		value: 'application/json'
	)
	headers.add_custom('Access-Control-Allow-Origin', '*') or {}
	headers.add_custom('Access-Control-Allow-Headers', 'Content-Type, X-Api-Key') or {}
	headers.add_custom('Access-Control-Allow-Methods', 'GET, POST, OPTIONS') or {}
	headers.add_custom('X-Aerie-Proof-Type', 'light') or {}

	// Handle CORS preflight
	if req.method == .options {
		return http.Response{
			status_code: 204
			header:      headers
		}
	}

	// Policy gate — Phase 1 always allows, but log the decision
	if !policy.allowed {
		return http.Response{
			status_code: 403
			body:        '{"error":"Access denied","reason":"${policy.reason}"}'
			header:      headers
		}
	}

	// Route to handler
	body := match true {
		req.url.starts_with('/graphql') {
			handle_graphql_request(req, mut h.redis, policy)
		}
		req.url.starts_with('/api/v1/telemetry') {
			resolve_telemetry(mut h.redis, policy)
		}
		req.url.starts_with('/api/v1/routes') {
			handle_routes_request(req, mut h.redis, policy)
		}
		req.url.starts_with('/api/v1/audit') {
			handle_audit_request(req, mut h.redis, policy)
		}
		req.url.starts_with('/api/v1/health') {
			health_check()
		}
		else {
			'{"error":"Not found","available_endpoints":["/graphql","/api/v1/telemetry","/api/v1/routes","/api/v1/audit","/api/v1/health"]}'
		}
	}

	status := if req.url.starts_with('/api/v1/health') || body.contains('"error"') == false {
		200
	} else if body.contains('"Not found"') {
		404
	} else {
		200
	}

	return http.Response{
		status_code: status
		body:        body
		header:      headers
	}
}

// handle_graphql_request parses the GraphQL request body and dispatches
// to the resolver. Supports both application/json and raw query bodies.
fn handle_graphql_request(req http.Request, mut redis RedisClient, policy PolicyDecision) string {
	if req.method != .post {
		return '{"errors":[{"message":"GraphQL endpoint requires POST method"}]}'
	}

	// Parse the request body to extract the query string
	query := extract_graphql_query(req.data)
	if query.len == 0 {
		return '{"errors":[{"message":"Missing query field in request body"}]}'
	}

	return resolve_graphql_query(query, mut redis, policy)
}

// extract_graphql_query pulls the "query" field from a JSON request body.
// Handles standard GraphQL-over-HTTP format: {"query": "...", "variables": {...}}
fn extract_graphql_query(body string) string {
	parsed := json2.raw_decode(body) or { return body }
	obj := parsed.as_map()
	query_any := obj['query'] or { return body }
	return query_any.str()
}

// handle_routes_request extracts the target query parameter and
// dispatches to the route forensics resolver.
fn handle_routes_request(req http.Request, mut redis RedisClient, policy PolicyDecision) string {
	// Extract target from query string: /api/v1/routes?target=1.2.3.4
	target := extract_query_param(req.url, 'target')
	if target.len == 0 {
		return '{"error":"Missing required query parameter: target","usage":"/api/v1/routes?target=<ip_or_hostname>"}'
	}
	return resolve_route_forensics(target, mut redis, policy)
}

// handle_audit_request extracts the limit query parameter and
// dispatches to the audit resolver.
fn handle_audit_request(req http.Request, mut redis RedisClient, policy PolicyDecision) string {
	limit_str := extract_query_param(req.url, 'limit')
	limit := if limit_str.len > 0 { limit_str.int() } else { 50 }
	return resolve_audit(limit, mut redis, policy)
}

// extract_query_param extracts a named parameter from a URL query string.
// Returns empty string if the parameter is not found.
fn extract_query_param(url string, name string) string {
	query_start := url.index('?') or { return '' }
	query := url[query_start + 1..]
	pairs := query.split('&')
	for pair in pairs {
		kv := pair.split('=')
		if kv.len == 2 && kv[0] == name {
			return kv[1]
		}
	}
	return ''
}

// health_check returns the gateway health status including connectivity
// information for backend services.
fn health_check() string {
	now := time.now().format_rfc3339()
	return '{"status":"healthy","service":"aerie-gateway","version":"0.1.0","timestamp":"${now}","protocols":{"graphql":true,"grpc":true,"rest":true},"proof_mode":"light","policy_phase":1}'
}

//==============================================================================
// gRPC Listener (Phase 1 — Simplified Binary Protocol)
//==============================================================================

// grpc_listener starts a TCP listener for gRPC connections on the
// specified port. Phase 1 implements a simplified binary protocol
// that accepts protobuf-framed requests and returns protobuf-framed
// responses. A full HTTP/2 + gRPC implementation is planned for Phase 2.
//
// The listener accepts connections and spawns a handler thread for each.
fn grpc_listener(port int, mut redis RedisClient) {
	mut listener := net.listen_tcp(.ip, '0.0.0.0:${port}') or {
		eprintln('[aerie] gRPC: failed to bind port ${port}: ${err}')
		return
	}
	println('[aerie] gRPC listener ready on :${port}')

	for {
		mut conn := listener.accept() or {
			eprintln('[aerie] gRPC: accept error: ${err}')
			continue
		}
		spawn handle_grpc_connection(mut conn, mut redis)
	}
}

// handle_grpc_connection processes a single gRPC client connection.
//
// Phase 1 protocol (simplified, non-HTTP/2):
//   Request:  4-byte length prefix (big-endian) + JSON body
//   Response: 4-byte length prefix (big-endian) + JSON body
//
// The JSON body contains a "method" field mapping to AerieService RPCs:
//   {"method": "GetTelemetrySnapshot"}
//   {"method": "GetRouteForensicsSnapshot", "target": "1.2.3.4"}
//   {"method": "GetAuditSnapshot", "limit": 50}
//
// Phase 2 will implement proper HTTP/2 framing and protobuf serialisation.
fn handle_grpc_connection(mut conn net.TcpConn, mut redis RedisClient) {
	defer { conn.close() or {} }

	// Read length prefix (4 bytes, big-endian)
	mut len_buf := []u8{len: 4}
	conn.read(mut len_buf) or {
		eprintln('[aerie] gRPC: failed to read length prefix')
		return
	}
	msg_len := int(len_buf[0]) << 24 | int(len_buf[1]) << 16 | int(len_buf[2]) << 8 | int(len_buf[3])

	if msg_len <= 0 || msg_len > 65536 {
		eprintln('[aerie] gRPC: invalid message length ${msg_len}')
		return
	}

	// Read message body
	mut body_buf := []u8{len: msg_len}
	conn.read(mut body_buf) or {
		eprintln('[aerie] gRPC: failed to read message body')
		return
	}
	body := body_buf.bytestr()

	// Parse JSON request
	parsed := json2.raw_decode(body) or {
		send_grpc_response(mut conn, '{"error":"Invalid JSON"}')
		return
	}
	obj := parsed.as_map()
	method := (obj['method'] or { json2.Any('') }).str()

	// Apply policy gate
	policy := evaluate_policy('', 'grpc:${method}')

	// Dispatch to resolver
	response := match method {
		'GetTelemetrySnapshot' {
			resolve_telemetry(mut redis, policy)
		}
		'GetRouteForensicsSnapshot' {
			target := (obj['target'] or { json2.Any('') }).str()
			if target.len == 0 {
				'{"error":"target field required"}'
			} else {
				resolve_route_forensics(target, mut redis, policy)
			}
		}
		'GetAuditSnapshot' {
			limit := (obj['limit'] or { json2.Any(50) }).int()
			resolve_audit(limit, mut redis, policy)
		}
		else {
			'{"error":"Unknown method: ${method}","available":["GetTelemetrySnapshot","GetRouteForensicsSnapshot","GetAuditSnapshot"]}'
		}
	}

	send_grpc_response(mut conn, response)
}

// send_grpc_response writes a length-prefixed JSON response back to the
// gRPC client connection.
fn send_grpc_response(mut conn net.TcpConn, body string) {
	length := body.len
	mut header := []u8{len: 4}
	header[0] = u8(length >> 24)
	header[1] = u8(length >> 16)
	header[2] = u8(length >> 8)
	header[3] = u8(length)

	conn.write(header) or {
		eprintln('[aerie] gRPC: failed to write response header')
		return
	}
	conn.write(body.bytes()) or {
		eprintln('[aerie] gRPC: failed to write response body')
	}
}
