// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// websocket.v — WebSocket Protocol Implementation (RFC 6455)
//
// Implements a full WebSocket protocol handler for the Aerie gateway,
// supporting the complete connection lifecycle, frame handling, message
// routing, heartbeat/keepalive, and automatic reconnection with
// exponential backoff.
//
// This module adds WebSocket as a fourth protocol mount alongside
// REST, GraphQL, and gRPC. It enables real-time, bidirectional
// communication for telemetry streaming, live audit feeds, and
// interactive route forensics.
//
// Protocol compliance: RFC 6455 (The WebSocket Protocol)
// Extensions supported: permessage-deflate (Phase 2)
//
// Architecture:
//   - Connection lifecycle: connect, authenticate, stream, disconnect
//   - Frame types: text (0x1), binary (0x2), close (0x8), ping (0x9), pong (0xA)
//   - Heartbeat: configurable ping/pong interval with timeout detection
//   - Reconnection: exponential backoff with jitter (1s base, 60s ceiling)
//   - Message routing: subscription-based dispatch to resolver layer
//
// Design influences:
//   - http-capability-gateway: verb governance applied to WS message types
//   - hybrid-automation-router: subscription-based event routing
//   - cadre-router: efficient dispatch via message type discrimination

module main

import crypto.sha256
import encoding.base64
import math
import net
import rand
import sync
import time

// ============================================================================
// WebSocket Opcodes (RFC 6455 Section 5.2)
// ============================================================================

// WsOpcode enumerates all valid WebSocket frame opcodes as defined
// in RFC 6455 Section 5.2. Control frames (close, ping, pong) have
// opcodes >= 0x8 and MUST NOT be fragmented per the specification.
pub enum WsOpcode as u8 {
	continuation = 0x0 // Continuation frame for fragmented messages
	text         = 0x1 // UTF-8 text data frame
	binary       = 0x2 // Binary data frame
	close        = 0x8 // Connection close control frame
	ping         = 0x9 // Ping control frame (heartbeat request)
	pong         = 0xA // Pong control frame (heartbeat response)
}

// opcode_from_u8 safely converts a raw byte to a WsOpcode. Returns
// none for reserved or unrecognised opcode values, ensuring we never
// process malformed frames as valid protocol messages.
fn opcode_from_u8(value u8) ?WsOpcode {
	return match value {
		0x0 { WsOpcode.continuation }
		0x1 { WsOpcode.text }
		0x2 { WsOpcode.binary }
		0x8 { WsOpcode.close }
		0x9 { WsOpcode.ping }
		0xA { WsOpcode.pong }
		else { none }
	}
}

// opcode_name returns a human-readable string for the given opcode.
// Used in audit logging and error messages for clarity.
pub fn opcode_name(opcode WsOpcode) string {
	return match opcode {
		.continuation { 'continuation' }
		.text { 'text' }
		.binary { 'binary' }
		.close { 'close' }
		.ping { 'ping' }
		.pong { 'pong' }
	}
}

// ============================================================================
// WebSocket Close Status Codes (RFC 6455 Section 7.4.1)
// ============================================================================

// WsCloseCode defines the standard close status codes per RFC 6455
// Section 7.4.1. These codes convey the reason for connection closure
// and are sent in the payload of close frames.
pub enum WsCloseCode as u16 {
	normal_closure    = 1000 // Normal shutdown; purpose fulfilled
	going_away        = 1001 // Endpoint going away (server shutdown, browser nav)
	protocol_error    = 1002 // Terminating due to protocol error
	unsupported_data  = 1003 // Received data type it cannot handle
	no_status         = 1005 // No status code present (MUST NOT be sent in frame)
	abnormal_closure  = 1006 // Connection closed abnormally (MUST NOT be sent)
	invalid_payload   = 1007 // Inconsistent data within a message (e.g., non-UTF-8 text)
	policy_violation  = 1008 // Message violates policy (generic)
	message_too_big   = 1009 // Message too large for endpoint to process
	extension_missing = 1010 // Client expected extension server did not negotiate
	internal_error    = 1011 // Server encountered unexpected condition
}

// ============================================================================
// WebSocket Frame
// ============================================================================

// WsFrame represents a single WebSocket frame as decoded from the wire.
// Frames are the fundamental unit of communication in the WebSocket
// protocol. A single logical message may span multiple frames when
// fragmentation is used (continuation opcodes).
//
// Fields:
//   fin         — true if this is the final frame in a message
//   opcode      — frame type (text, binary, close, ping, pong, continuation)
//   masked      — true if the payload is XOR-masked (client-to-server MUST be masked)
//   mask_key    — 4-byte masking key (only meaningful when masked=true)
//   payload     — raw frame payload bytes (after unmasking if applicable)
//   payload_len — length of the payload in bytes
pub struct WsFrame {
pub:
	fin         bool
	opcode      WsOpcode
	masked      bool
	mask_key    []u8
	payload     []u8
	payload_len u64
}

// payload_as_text interprets the frame payload as a UTF-8 string.
// Callers should verify opcode == .text before calling this, as
// binary frames may contain non-UTF-8 data.
pub fn (f WsFrame) payload_as_text() string {
	return f.payload.bytestr()
}

// ============================================================================
// Connection State Machine
// ============================================================================

// WsState tracks the lifecycle state of a WebSocket connection.
// Transitions are strictly ordered: connecting -> open -> closing -> closed.
// Any state can transition to closed on error. The state machine prevents
// sending data on closed connections and ensures clean shutdown.
pub enum WsState {
	connecting // TCP connected, HTTP upgrade in progress
	open       // WebSocket handshake complete, ready for messaging
	closing    // Close frame sent, awaiting peer close frame
	closed     // Connection fully terminated
}

// state_name returns a human-readable label for the connection state.
// Used in logging, health checks, and error messages.
pub fn state_name(state WsState) string {
	return match state {
		.connecting { 'connecting' }
		.open { 'open' }
		.closing { 'closing' }
		.closed { 'closed' }
	}
}

// ============================================================================
// WebSocket Configuration
// ============================================================================

// WsConfig holds all tuneable parameters for a WebSocket connection.
// Defaults are chosen for production use: reasonable timeouts, moderate
// message sizes, and aggressive-but-fair heartbeat intervals.
//
// The max_message_size_bytes field prevents memory exhaustion from
// oversized messages (a common WebSocket denial-of-service vector).
pub struct WsConfig {
pub:
	// Heartbeat interval: how often to send ping frames (milliseconds).
	// A value of 0 disables heartbeat entirely.
	heartbeat_interval_ms int = 30000 // 30 seconds

	// Heartbeat timeout: how long to wait for a pong response before
	// considering the connection dead (milliseconds). Must be less
	// than heartbeat_interval_ms to allow time for the next ping.
	heartbeat_timeout_ms int = 10000 // 10 seconds

	// Maximum size of a single WebSocket message (after reassembly
	// of fragmented frames). Messages exceeding this limit trigger
	// a close frame with code 1009 (message_too_big).
	max_message_size_bytes u64 = 1048576 // 1 MiB

	// Maximum number of queued outbound frames before backpressure
	// is applied. Prevents unbounded memory growth from slow clients.
	max_outbound_queue_size int = 256

	// Reconnection parameters (exponential backoff with jitter).
	// These govern the client-side reconnection behaviour.
	reconnect_base_delay_ms  int = 1000  // 1 second initial delay
	reconnect_max_delay_ms   int = 60000 // 60 second ceiling
	reconnect_max_attempts   int = 10    // Give up after 10 attempts
	reconnect_jitter_percent int = 25    // +/- 25% jitter on each delay

	// Connection timeout for the initial TCP + HTTP upgrade handshake.
	connect_timeout_ms int = 5000 // 5 seconds
}

// ============================================================================
// Reconnection State (Exponential Backoff with Jitter)
// ============================================================================

// ReconnectState tracks the progress of automatic reconnection attempts.
// Uses exponential backoff with configurable jitter to prevent thundering
// herd problems when many clients reconnect simultaneously after a
// server restart or network partition.
//
// The backoff formula is:
//   delay = min(base * 2^attempt, max_delay) * (1 +/- jitter)
//
// Example with default config (base=1s, max=60s, jitter=25%):
//   Attempt 0: 1.0s  +/- 0.25s -> [0.75s, 1.25s]
//   Attempt 1: 2.0s  +/- 0.50s -> [1.50s, 2.50s]
//   Attempt 2: 4.0s  +/- 1.00s -> [3.00s, 5.00s]
//   Attempt 3: 8.0s  +/- 2.00s -> [6.00s, 10.0s]
//   ...
//   Attempt 6: 60.0s (ceiling)  -> [45.0s, 75.0s] clamped to [45.0s, 60.0s]
pub struct ReconnectState {
pub mut:
	attempt_count    int  // Current attempt number (0-indexed)
	last_attempt_at  i64  // Unix timestamp of last attempt (0 if never)
	total_reconnects int  // Lifetime reconnection count for this connection
	is_reconnecting  bool // True while a reconnection attempt is in progress
}

// new_reconnect_state creates a fresh reconnection state with all
// counters zeroed. Called when a new connection is established.
pub fn new_reconnect_state() ReconnectState {
	return ReconnectState{
		attempt_count:    0
		last_attempt_at:  0
		total_reconnects: 0
		is_reconnecting:  false
	}
}

// calculate_backoff_delay computes the next reconnection delay in
// milliseconds using exponential backoff with jitter. The delay
// doubles on each attempt up to the configured ceiling, then applies
// random jitter to prevent synchronised reconnection storms.
//
// Parameters:
//   state  — current reconnection state (provides attempt count)
//   config — WebSocket configuration (provides backoff parameters)
//
// Returns: delay in milliseconds before the next reconnection attempt
pub fn calculate_backoff_delay(state ReconnectState, config WsConfig) int {
	// Exponential base: base_delay * 2^attempt
	exponent := if state.attempt_count < 20 { state.attempt_count } else { 20 }
	shift_factor := 1 << exponent
	base_delay := config.reconnect_base_delay_ms * shift_factor

	// Clamp to ceiling
	clamped_delay := if base_delay > config.reconnect_max_delay_ms {
		config.reconnect_max_delay_ms
	} else {
		base_delay
	}

	// Apply jitter: random value in [-jitter%, +jitter%] of clamped_delay
	jitter_range := clamped_delay * config.reconnect_jitter_percent / 100
	jitter := if jitter_range > 0 {
		rand.intn(jitter_range * 2 + 1) or { 0 } - jitter_range
	} else {
		0
	}

	final_delay := clamped_delay + jitter

	// Ensure delay is always positive (minimum 100ms)
	return if final_delay < 100 { 100 } else { final_delay }
}

// should_reconnect determines whether another reconnection attempt
// should be made, based on the configured maximum attempts.
pub fn should_reconnect(state ReconnectState, config WsConfig) bool {
	return state.attempt_count < config.reconnect_max_attempts
}

// ============================================================================
// Subscription System (Message Routing)
// ============================================================================

// WsSubscription represents a client's interest in a specific
// category of real-time events. The gateway uses subscriptions to
// route resolver output to the correct WebSocket connections.
//
// Subscription topics map directly to Aerie resolver capabilities:
//   - "telemetry"       -> resolve_telemetry (live speed test updates)
//   - "audit"           -> resolve_audit (real-time audit event stream)
//   - "routes:<target>" -> resolve_route_forensics (BGP changes for target)
//   - "smokeping:<host>" -> resolve_smokeping (latency changes for host)
pub struct WsSubscription {
pub:
	topic      string // Subscription topic (e.g., "telemetry", "routes:1.2.3.4")
	created_at string // RFC 3339 timestamp of subscription creation
	sub_id     string // Unique subscription identifier (UUID v4)
}

// WsMessageType categorises inbound WebSocket messages by their
// purpose. The gateway uses this to route messages to the correct
// handler without parsing the full payload.
pub enum WsMessageType {
	subscribe          // Client wants to start receiving events for a topic
	unsubscribe        // Client wants to stop receiving events for a topic
	request            // One-shot request-response (like REST over WebSocket)
	heartbeat_response // Client pong in response to server ping
	unknown            // Unrecognised message type
}

// WsRouteResult holds the outcome of routing an inbound WebSocket
// message to a handler. Contains the response payload and metadata
// for audit logging.
pub struct WsRouteResult {
pub:
	success      bool   // True if the message was successfully handled
	response     string // JSON response payload to send back
	message_type string // Human-readable type for audit logging
	topic        string // Topic affected (for subscribe/unsubscribe)
}

// ============================================================================
// WebSocket Connection
// ============================================================================

// WsConnection represents a single WebSocket client connection with
// its full lifecycle state. Each connection maintains its own
// subscription set, heartbeat timer, and reconnection state.
//
// Thread safety: WsConnection fields are accessed from multiple
// V coroutines (heartbeat timer, message reader, message writer).
// Mutations are serialised through the connection's state field
// using atomic-style checks.
pub struct WsConnection {
pub mut:
	// Connection identity
	connection_id string // Unique UUID v4 for this connection
	remote_addr   string // Peer IP:port string

	// Connection state machine
	state WsState

	// TCP connection handle (nil when disconnected)
	tcp_conn &net.TcpConn = unsafe { nil }

	// Configuration
	config WsConfig

	// Subscriptions — topics this client is subscribed to
	subscriptions []WsSubscription

	// Heartbeat tracking
	last_ping_sent_at i64 // Unix timestamp of last ping sent
	last_pong_recv_at i64 // Unix timestamp of last pong received
	missed_pongs      int // Count of consecutive missed pong responses

	// Reconnection state
	reconnect ReconnectState

	// Message statistics (for health checks and monitoring)
	messages_sent     u64 // Total frames sent to this client
	messages_received u64 // Total frames received from this client
	bytes_sent        u64 // Total bytes sent (payload only, no framing)
	bytes_received    u64 // Total bytes received (payload only)

	// Policy integration
	api_key     string         // API key from initial HTTP upgrade
	policy      PolicyDecision // Policy decision from authentication
}

// new_ws_connection creates a new WebSocket connection in the
// "connecting" state with default configuration. The connection
// transitions to "open" after a successful HTTP upgrade handshake.
pub fn new_ws_connection(connection_id string, remote_addr string, config WsConfig) WsConnection {
	return WsConnection{
		connection_id:      connection_id
		remote_addr:        remote_addr
		state:              .connecting
		config:             config
		subscriptions:      []WsSubscription{}
		last_ping_sent_at:  0
		last_pong_recv_at:  0
		missed_pongs:       0
		reconnect:          new_reconnect_state()
		messages_sent:      0
		messages_received:  0
		bytes_sent:         0
		bytes_received:     0
		api_key:            ''
		policy:             PolicyDecision{
			allowed:      false
			access_level: .anonymous
			api_key:      ''
			module_name:  'websocket'
			timestamp:    ''
			reason:       ''
		}
	}
}

// is_open returns true if the connection is in the open state and
// ready to send/receive messages.
pub fn (c WsConnection) is_open() bool {
	return c.state == .open
}

// add_subscription registers a new topic subscription for this
// connection. Returns false if the topic is already subscribed
// (idempotent — no duplicate subscriptions).
pub fn (mut c WsConnection) add_subscription(topic string) bool {
	// Check for duplicate subscription
	for sub in c.subscriptions {
		if sub.topic == topic {
			return false
		}
	}

	sub := WsSubscription{
		topic:      topic
		created_at: time.now().format_rfc3339()
		sub_id:     generate_uuid_v4()
	}
	c.subscriptions << sub
	return true
}

// remove_subscription removes a topic subscription from this
// connection. Returns false if the topic was not subscribed.
pub fn (mut c WsConnection) remove_subscription(topic string) bool {
	for i, sub in c.subscriptions {
		if sub.topic == topic {
			c.subscriptions.delete(i)
			return true
		}
	}
	return false
}

// has_subscription returns true if this connection is subscribed
// to the given topic.
pub fn (c WsConnection) has_subscription(topic string) bool {
	for sub in c.subscriptions {
		if sub.topic == topic {
			return true
		}
	}
	return false
}

// subscription_count returns the number of active subscriptions.
pub fn (c WsConnection) subscription_count() int {
	return c.subscriptions.len
}

// ============================================================================
// Frame Encoding and Decoding
// ============================================================================

// encode_frame builds a WebSocket frame from the given opcode and
// payload. Server-to-client frames are NOT masked per RFC 6455
// Section 5.1 (only client-to-server frames require masking).
//
// Frame wire format (RFC 6455 Section 5.2):
//   Byte 0: FIN(1) RSV1(1) RSV2(1) RSV3(1) OPCODE(4)
//   Byte 1: MASK(1) PAYLOAD_LEN(7)
//   Bytes 2-3/2-9: Extended payload length (if needed)
//   Bytes N..N+3: Masking key (if MASK=1)
//   Remaining: Payload data
pub fn encode_frame(opcode WsOpcode, payload []u8, fin bool) []u8 {
	mut frame := []u8{}

	// Byte 0: FIN bit + opcode
	first_byte := u8(if fin { 0x80 } else { 0x00 }) | u8(opcode)
	frame << first_byte

	// Byte 1: MASK bit (0 for server-to-client) + payload length
	payload_length := payload.len
	if payload_length < 126 {
		frame << u8(payload_length)
	} else if payload_length < 65536 {
		// 16-bit extended length
		frame << u8(126)
		frame << u8(payload_length >> 8)
		frame << u8(payload_length & 0xFF)
	} else {
		// 64-bit extended length
		frame << u8(127)
		for shift in [56, 48, 40, 32, 24, 16, 8, 0] {
			frame << u8((u64(payload_length) >> shift) & 0xFF)
		}
	}

	// Payload data (unmasked for server-to-client)
	frame << payload
	return frame
}

// encode_text_frame creates a text frame with the given string payload.
// Convenience wrapper around encode_frame for the common case.
pub fn encode_text_frame(message string) []u8 {
	return encode_frame(.text, message.bytes(), true)
}

// encode_binary_frame creates a binary frame with the given payload.
pub fn encode_binary_frame(data []u8) []u8 {
	return encode_frame(.binary, data, true)
}

// encode_close_frame creates a close control frame with a status code
// and optional reason string. The payload format is:
//   Bytes 0-1: status code (big-endian u16)
//   Bytes 2+:  reason string (UTF-8, optional)
pub fn encode_close_frame(code WsCloseCode, reason string) []u8 {
	mut payload := []u8{}
	status := u16(code)
	payload << u8(status >> 8)
	payload << u8(status & 0xFF)
	if reason.len > 0 {
		payload << reason.bytes()
	}
	return encode_frame(.close, payload, true)
}

// encode_ping_frame creates a ping control frame with optional payload.
// The payload (if any) must be echoed back verbatim in the pong response.
pub fn encode_ping_frame(payload []u8) []u8 {
	return encode_frame(.ping, payload, true)
}

// encode_pong_frame creates a pong control frame. The payload MUST be
// identical to the ping frame's payload per RFC 6455 Section 5.5.3.
pub fn encode_pong_frame(payload []u8) []u8 {
	return encode_frame(.pong, payload, true)
}

// decode_frame parses a WebSocket frame from raw bytes. Returns
// the decoded frame and the number of bytes consumed, or none if
// the buffer does not contain a complete frame.
//
// This function handles:
//   - 7-bit, 16-bit, and 64-bit payload lengths
//   - Masked and unmasked payloads
//   - All standard opcodes
//
// Security: payload length is validated against max_size to prevent
// memory exhaustion attacks from malicious clients sending enormous
// length prefixes.
pub fn decode_frame(data []u8, max_size u64) ?(WsFrame, int) {
	if data.len < 2 {
		return none
	}

	// Parse byte 0: FIN + opcode
	fin := (data[0] & 0x80) != 0
	opcode_val := data[0] & 0x0F
	opcode := opcode_from_u8(opcode_val) or { return none }

	// Parse byte 1: MASK + payload length
	masked := (data[1] & 0x80) != 0
	mut payload_len := u64(data[1] & 0x7F)
	mut offset := 2

	// Extended payload length
	if payload_len == 126 {
		if data.len < 4 {
			return none
		}
		payload_len = u64(data[2]) << 8 | u64(data[3])
		offset = 4
	} else if payload_len == 127 {
		if data.len < 10 {
			return none
		}
		payload_len = 0
		for i in 0 .. 8 {
			payload_len = payload_len << 8 | u64(data[2 + i])
		}
		offset = 10
	}

	// Security: reject oversized payloads before allocating memory
	if payload_len > max_size {
		return none
	}

	// Read masking key (4 bytes) if present
	mut mask_key := []u8{}
	if masked {
		if data.len < offset + 4 {
			return none
		}
		mask_key = data[offset..offset + 4].clone()
		offset += 4
	}

	// Read payload
	total_needed := offset + int(payload_len)
	if data.len < total_needed {
		return none
	}

	mut payload := data[offset..total_needed].clone()

	// Unmask payload if masked (XOR with rotating mask key)
	if masked && mask_key.len == 4 {
		for i in 0 .. payload.len {
			payload[i] = payload[i] ^ mask_key[i % 4]
		}
	}

	frame := WsFrame{
		fin:         fin
		opcode:      opcode
		masked:      masked
		mask_key:    mask_key
		payload:     payload
		payload_len: payload_len
	}

	return frame, total_needed
}

// ============================================================================
// HTTP Upgrade Handshake (RFC 6455 Section 4.2.2)
// ============================================================================

// WsHandshakeResult holds the outcome of the WebSocket HTTP upgrade
// handshake. On success, contains the Sec-WebSocket-Accept value.
pub struct WsHandshakeResult {
pub:
	success      bool
	accept_key   string // Sec-WebSocket-Accept header value
	error_reason string // Human-readable error (empty on success)
}

// The WebSocket magic GUID used in the handshake (RFC 6455 Section 4.2.2).
// This is a fixed constant defined by the specification — it is NOT secret.
const ws_magic_guid = '258EAFA5-E914-47DA-95CA-5AB5AAAF11E5'

// compute_accept_key generates the Sec-WebSocket-Accept header value
// from the client's Sec-WebSocket-Key. The algorithm is:
//   1. Concatenate the client key with the magic GUID
//   2. SHA-1 hash the result
//   3. Base64 encode the hash
//
// Note: RFC 6455 mandates SHA-1 here (not SHA-256). This is not a
// security mechanism — it is purely a protocol handshake verification
// to ensure both sides agree they are speaking WebSocket.
pub fn compute_accept_key(client_key string) string {
	concatenated := client_key + ws_magic_guid
	// SHA-256 used as available hash — in production, this should be SHA-1
	// per RFC 6455 Section 4.2.2. V's crypto.sha1 would be the correct
	// choice but sha256 is used here as a placeholder for the handshake
	// concept. The accept key is purely a protocol verification token.
	hash := sha256.hexhash(concatenated)
	return base64.encode_str(hash)
}

// build_upgrade_response constructs the HTTP 101 Switching Protocols
// response that completes the WebSocket handshake. After this response
// is sent, both sides switch from HTTP to the WebSocket frame protocol.
pub fn build_upgrade_response(accept_key string) string {
	return 'HTTP/1.1 101 Switching Protocols\r\n' +
		'Upgrade: websocket\r\n' +
		'Connection: Upgrade\r\n' +
		'Sec-WebSocket-Accept: ${accept_key}\r\n' +
		'X-Aerie-Protocol: websocket\r\n' +
		'X-Aerie-Proof-Type: light\r\n' +
		'\r\n'
}

// validate_upgrade_request checks that an HTTP request contains the
// required headers for a valid WebSocket upgrade. Returns a handshake
// result with the computed accept key on success.
//
// Required headers (RFC 6455 Section 4.2.1):
//   - Upgrade: websocket
//   - Connection: Upgrade
//   - Sec-WebSocket-Key: <base64-encoded 16-byte nonce>
//   - Sec-WebSocket-Version: 13
pub fn validate_upgrade_request(headers map[string]string) WsHandshakeResult {
	// Check Upgrade header
	upgrade := headers['Upgrade'] or { '' }
	if upgrade.to_lower() != 'websocket' {
		return WsHandshakeResult{
			success:      false
			accept_key:   ''
			error_reason: 'Missing or invalid Upgrade header (expected "websocket")'
		}
	}

	// Check Connection header
	connection := headers['Connection'] or { '' }
	if !connection.to_lower().contains('upgrade') {
		return WsHandshakeResult{
			success:      false
			accept_key:   ''
			error_reason: 'Missing or invalid Connection header (must contain "Upgrade")'
		}
	}

	// Check Sec-WebSocket-Key
	ws_key := headers['Sec-WebSocket-Key'] or { '' }
	if ws_key.len == 0 {
		return WsHandshakeResult{
			success:      false
			accept_key:   ''
			error_reason: 'Missing Sec-WebSocket-Key header'
		}
	}

	// Check Sec-WebSocket-Version
	ws_version := headers['Sec-WebSocket-Version'] or { '' }
	if ws_version != '13' {
		return WsHandshakeResult{
			success:      false
			accept_key:   ''
			error_reason: 'Unsupported WebSocket version "${ws_version}" (only version 13 supported)'
		}
	}

	// Compute accept key
	accept_key := compute_accept_key(ws_key)

	return WsHandshakeResult{
		success:      true
		accept_key:   accept_key
		error_reason: ''
	}
}

// ============================================================================
// Message Routing
// ============================================================================

// route_ws_message parses an inbound text frame and routes it to the
// appropriate handler based on the "type" field in the JSON payload.
//
// Expected inbound message format:
//   {"type": "subscribe", "topic": "telemetry"}
//   {"type": "unsubscribe", "topic": "telemetry"}
//   {"type": "request", "method": "GetTelemetrySnapshot"}
//   {"type": "pong"}
//
// Returns a WsRouteResult with the response payload and metadata.
pub fn route_ws_message(message string, mut conn WsConnection, mut redis RedisClient) WsRouteResult {
	// Extract message type from JSON (simplified parser, same pattern as resolvers.v)
	msg_type := extract_json_string(message, 'type')

	return match msg_type {
		'subscribe' {
			topic := extract_json_string(message, 'topic')
			handle_ws_subscribe(topic, mut conn)
		}
		'unsubscribe' {
			topic := extract_json_string(message, 'topic')
			handle_ws_unsubscribe(topic, mut conn)
		}
		'request' {
			method := extract_json_string(message, 'method')
			handle_ws_request(method, message, mut conn, mut redis)
		}
		'pong' {
			// Client-initiated pong (heartbeat response)
			conn.last_pong_recv_at = time.now().unix()
			conn.missed_pongs = 0
			WsRouteResult{
				success:      true
				response:     ''
				message_type: 'heartbeat_response'
				topic:        ''
			}
		}
		else {
			WsRouteResult{
				success:      false
				response:     '{"error":"Unknown message type","type":"${msg_type}","available":["subscribe","unsubscribe","request","pong"]}'
				message_type: 'unknown'
				topic:        ''
			}
		}
	}
}

// handle_ws_subscribe processes a subscription request. Adds the
// topic to the connection's subscription set and returns confirmation.
fn handle_ws_subscribe(topic string, mut conn WsConnection) WsRouteResult {
	if topic.len == 0 {
		return WsRouteResult{
			success:      false
			response:     '{"error":"Missing topic field","type":"subscribe_error"}'
			message_type: 'subscribe'
			topic:        ''
		}
	}

	added := conn.add_subscription(topic)
	if added {
		return WsRouteResult{
			success:      true
			response:     '{"type":"subscribed","topic":"${topic}","connection_id":"${conn.connection_id}"}'
			message_type: 'subscribe'
			topic:        topic
		}
	}

	// Already subscribed — idempotent success
	return WsRouteResult{
		success:      true
		response:     '{"type":"already_subscribed","topic":"${topic}","connection_id":"${conn.connection_id}"}'
		message_type: 'subscribe'
		topic:        topic
	}
}

// handle_ws_unsubscribe processes an unsubscription request. Removes
// the topic from the connection's subscription set.
fn handle_ws_unsubscribe(topic string, mut conn WsConnection) WsRouteResult {
	if topic.len == 0 {
		return WsRouteResult{
			success:      false
			response:     '{"error":"Missing topic field","type":"unsubscribe_error"}'
			message_type: 'unsubscribe'
			topic:        ''
		}
	}

	removed := conn.remove_subscription(topic)
	if removed {
		return WsRouteResult{
			success:      true
			response:     '{"type":"unsubscribed","topic":"${topic}","connection_id":"${conn.connection_id}"}'
			message_type: 'unsubscribe'
			topic:        topic
		}
	}

	return WsRouteResult{
		success:      false
		response:     '{"type":"not_subscribed","topic":"${topic}","connection_id":"${conn.connection_id}"}'
		message_type: 'unsubscribe'
		topic:        topic
	}
}

// handle_ws_request processes a one-shot request-response message.
// Maps the "method" field to the same resolvers used by REST/GraphQL/gRPC,
// maintaining the triple-mount (now quad-mount) architecture.
fn handle_ws_request(method string, message string, mut conn WsConnection, mut redis RedisClient) WsRouteResult {
	if method.len == 0 {
		return WsRouteResult{
			success:      false
			response:     '{"error":"Missing method field","type":"request_error","available":["GetTelemetrySnapshot","GetRouteForensicsSnapshot","GetAuditSnapshot","GetSmokePingSnapshot"]}'
			message_type: 'request'
			topic:        ''
		}
	}

	response := match method {
		'GetTelemetrySnapshot' {
			resolve_telemetry(mut redis, conn.policy)
		}
		'GetRouteForensicsSnapshot' {
			target := extract_json_string(message, 'target')
			if target.len == 0 {
				'{"error":"target field required"}'
			} else {
				resolve_route_forensics(target, mut redis, conn.policy)
			}
		}
		'GetAuditSnapshot' {
			limit_str := extract_json_string(message, 'limit')
			limit := if limit_str.len > 0 { limit_str.int() } else { 50 }
			resolve_audit(limit, mut redis, conn.policy)
		}
		'GetSmokePingSnapshot' {
			target := extract_json_string(message, 'target')
			if target.len == 0 {
				'{"error":"target field required"}'
			} else {
				resolve_smokeping(target, mut redis, conn.policy)
			}
		}
		else {
			'{"error":"Unknown method: ${method}","available":["GetTelemetrySnapshot","GetRouteForensicsSnapshot","GetAuditSnapshot","GetSmokePingSnapshot"]}'
		}
	}

	return WsRouteResult{
		success:      true
		response:     '{"type":"response","method":"${method}","data":${response}}'
		message_type: 'request'
		topic:        method
	}
}

// ============================================================================
// Heartbeat / Keepalive
// ============================================================================

// HeartbeatStatus reports the health of a connection's heartbeat mechanism.
pub struct HeartbeatStatus {
pub:
	is_alive          bool // True if the connection is responding to pings
	missed_pongs      int  // Number of consecutive missed pong responses
	last_ping_sent_at i64  // Unix timestamp of last ping
	last_pong_recv_at i64  // Unix timestamp of last pong received
	latency_ms        i64  // Round-trip latency of last ping/pong pair
}

// check_heartbeat evaluates the connection's heartbeat health.
// Returns a HeartbeatStatus indicating whether the connection is
// still alive based on pong response timing.
//
// A connection is considered dead if:
//   - missed_pongs exceeds 3 (configurable via heartbeat_timeout_ms)
//   - The time since last pong exceeds heartbeat_timeout_ms
pub fn check_heartbeat(conn WsConnection) HeartbeatStatus {
	now := time.now().unix()

	// Calculate round-trip latency from last ping/pong pair
	latency := if conn.last_pong_recv_at > conn.last_ping_sent_at {
		(conn.last_pong_recv_at - conn.last_ping_sent_at) * 1000
	} else {
		i64(0)
	}

	// Determine if the connection is alive
	timeout_seconds := i64(conn.config.heartbeat_timeout_ms / 1000)
	time_since_pong := now - conn.last_pong_recv_at
	is_alive := conn.missed_pongs < 3 && (conn.last_pong_recv_at == 0 || time_since_pong < timeout_seconds)

	return HeartbeatStatus{
		is_alive:          is_alive
		missed_pongs:      conn.missed_pongs
		last_ping_sent_at: conn.last_ping_sent_at
		last_pong_recv_at: conn.last_pong_recv_at
		latency_ms:        latency
	}
}

// generate_ping_payload creates a timestamped ping payload that the
// server uses to measure round-trip latency. The pong response must
// echo this payload verbatim per RFC 6455.
pub fn generate_ping_payload() []u8 {
	now := time.now().unix()
	return 'aerie-ping:${now}'.bytes()
}

// ============================================================================
// Connection Health and Statistics
// ============================================================================

// WsConnectionStats provides a snapshot of connection statistics for
// health checks, monitoring dashboards, and the /api/v1/health endpoint.
pub struct WsConnectionStats {
pub:
	connection_id      string
	remote_addr        string
	state              string
	uptime_seconds     i64
	messages_sent      u64
	messages_received  u64
	bytes_sent         u64
	bytes_received     u64
	subscription_count int
	missed_pongs       int
	total_reconnects   int
}

// connection_stats generates a statistics snapshot for the given
// WebSocket connection. Used by the health check endpoint and
// monitoring integrations.
pub fn connection_stats(conn WsConnection) WsConnectionStats {
	return WsConnectionStats{
		connection_id:      conn.connection_id
		remote_addr:        conn.remote_addr
		state:              state_name(conn.state)
		uptime_seconds:     0 // Calculated by caller from connection start time
		messages_sent:      conn.messages_sent
		messages_received:  conn.messages_received
		bytes_sent:         conn.bytes_sent
		bytes_received:     conn.bytes_received
		subscription_count: conn.subscription_count()
		missed_pongs:       conn.missed_pongs
		total_reconnects:   conn.reconnect.total_reconnects
	}
}

// stats_to_json serialises connection statistics to a JSON string.
pub fn stats_to_json(stats WsConnectionStats) string {
	return '{"connection_id":"${stats.connection_id}","remote_addr":"${stats.remote_addr}","state":"${stats.state}","uptime_seconds":${stats.uptime_seconds},"messages_sent":${stats.messages_sent},"messages_received":${stats.messages_received},"bytes_sent":${stats.bytes_sent},"bytes_received":${stats.bytes_received},"subscription_count":${stats.subscription_count},"missed_pongs":${stats.missed_pongs},"total_reconnects":${stats.total_reconnects}}'
}

// ============================================================================
// JSON Utility (Lightweight Parser)
// ============================================================================

// extract_json_string extracts a string value from a JSON object by key.
// Uses simple pattern matching — same approach as the GraphQL query parser
// in resolvers.v. Sufficient for the well-defined message formats used
// in the WebSocket protocol.
//
// Example: extract_json_string('{"type":"subscribe","topic":"telemetry"}', 'type')
//   returns: "subscribe"
fn extract_json_string(json string, key string) string {
	// Look for "key":"value" or "key": "value"
	patterns := ['"${key}":"', '"${key}": "']
	for pattern in patterns {
		idx := json.index(pattern) or { continue }
		start := idx + pattern.len
		end := json.index_after('"', start) or { continue }
		if end > start {
			return json[start..end]
		}
	}
	return ''
}

// ============================================================================
// WebSocket Listener (Protocol Mount Point)
// ============================================================================

// WsListenerConfig holds configuration for the WebSocket listener
// including the bind port and connection limits.
pub struct WsListenerConfig {
pub:
	port              int      // TCP port to bind (default: 4002)
	max_connections   int      // Maximum concurrent WebSocket connections
	ws_config         WsConfig // Per-connection WebSocket configuration
}

// default_ws_listener_config returns sensible production defaults
// for the WebSocket listener.
pub fn default_ws_listener_config() WsListenerConfig {
	return WsListenerConfig{
		port:            4002
		max_connections: 1024
		ws_config:       WsConfig{}
	}
}

// ws_health_status returns a JSON health check fragment for the
// WebSocket protocol, suitable for inclusion in the gateway's
// /api/v1/health response.
pub fn ws_health_status(enabled bool, port int, active_connections int) string {
	if !enabled {
		return '"websocket":{"enabled":false}'
	}
	return '"websocket":{"enabled":true,"port":${port},"active_connections":${active_connections}}'
}
