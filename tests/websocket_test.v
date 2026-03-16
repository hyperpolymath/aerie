// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// websocket_test.v — Unit Tests for WebSocket Protocol Implementation
//
// Tests cover the complete WebSocket protocol surface:
//   - Frame encoding and decoding (text, binary, control frames)
//   - Connection lifecycle state machine
//   - HTTP upgrade handshake validation
//   - Subscription management
//   - Heartbeat/keepalive logic
//   - Reconnection backoff calculation
//   - Message routing
//   - Close frame generation with status codes
//
// RFC 6455 conformance is verified through golden tests that check
// wire format against known-good byte sequences.

module main

// ============================================================================
// Frame Encoding Tests
// ============================================================================

// test_encode_text_frame verifies that a short text message produces
// the correct WebSocket frame bytes. A text frame with payload "hello"
// should have: FIN=1, opcode=0x1, length=5, unmasked.
fn test_encode_text_frame() {
	frame_bytes := encode_text_frame('hello')

	// Byte 0: FIN(1) + opcode(0x1) = 0x81
	assert frame_bytes[0] == 0x81, 'First byte should be 0x81 (FIN=1, opcode=text)'

	// Byte 1: MASK(0) + length(5) = 0x05
	assert frame_bytes[1] == 0x05, 'Second byte should be 0x05 (unmasked, length=5)'

	// Payload bytes should match "hello"
	payload := frame_bytes[2..].bytestr()
	assert payload == 'hello', 'Payload should be "hello", got "${payload}"'

	// Total length: 2 header + 5 payload = 7
	assert frame_bytes.len == 7, 'Total frame length should be 7, got ${frame_bytes.len}'
}

// test_encode_binary_frame verifies binary frame encoding with
// arbitrary byte data.
fn test_encode_binary_frame() {
	data := [u8(0x00), 0x01, 0x02, 0xFF]
	frame_bytes := encode_binary_frame(data)

	// Byte 0: FIN(1) + opcode(0x2) = 0x82
	assert frame_bytes[0] == 0x82, 'First byte should be 0x82 (FIN=1, opcode=binary)'

	// Byte 1: MASK(0) + length(4) = 0x04
	assert frame_bytes[1] == 0x04, 'Second byte should be 0x04 (unmasked, length=4)'

	// Payload should match input data
	assert frame_bytes[2] == 0x00
	assert frame_bytes[3] == 0x01
	assert frame_bytes[4] == 0x02
	assert frame_bytes[5] == 0xFF
}

// test_encode_close_frame verifies close frame encoding with a
// status code and reason string.
fn test_encode_close_frame() {
	frame_bytes := encode_close_frame(.normal_closure, 'goodbye')

	// Byte 0: FIN(1) + opcode(0x8) = 0x88
	assert frame_bytes[0] == 0x88, 'First byte should be 0x88 (FIN=1, opcode=close)'

	// Payload: 2 bytes status code + "goodbye" (7 bytes) = 9 bytes
	payload_len := frame_bytes[1] & 0x7F
	assert payload_len == 9, 'Payload length should be 9, got ${payload_len}'

	// Status code: 1000 in big-endian = 0x03, 0xE8
	assert frame_bytes[2] == 0x03, 'Status code high byte should be 0x03'
	assert frame_bytes[3] == 0xE8, 'Status code low byte should be 0xE8'

	// Reason string
	reason := frame_bytes[4..11].bytestr()
	assert reason == 'goodbye', 'Reason should be "goodbye", got "${reason}"'
}

// test_encode_ping_frame verifies ping control frame encoding.
fn test_encode_ping_frame() {
	payload := 'ping-data'.bytes()
	frame_bytes := encode_ping_frame(payload)

	// Byte 0: FIN(1) + opcode(0x9) = 0x89
	assert frame_bytes[0] == 0x89, 'First byte should be 0x89 (FIN=1, opcode=ping)'

	// Payload should match
	frame_payload := frame_bytes[2..].bytestr()
	assert frame_payload == 'ping-data', 'Ping payload mismatch'
}

// test_encode_pong_frame verifies pong control frame encoding.
fn test_encode_pong_frame() {
	payload := 'pong-data'.bytes()
	frame_bytes := encode_pong_frame(payload)

	// Byte 0: FIN(1) + opcode(0xA) = 0x8A
	assert frame_bytes[0] == 0x8A, 'First byte should be 0x8A (FIN=1, opcode=pong)'
}

// test_encode_empty_text_frame verifies encoding of a zero-length text frame.
fn test_encode_empty_text_frame() {
	frame_bytes := encode_text_frame('')

	assert frame_bytes[0] == 0x81, 'FIN + text opcode'
	assert frame_bytes[1] == 0x00, 'Zero payload length'
	assert frame_bytes.len == 2, 'Empty frame should be exactly 2 bytes'
}

// test_encode_medium_payload verifies 16-bit extended length encoding
// for payloads between 126 and 65535 bytes.
fn test_encode_medium_payload() {
	// Create a 200-byte payload
	payload := []u8{len: 200, init: 0x41} // 200 'A' bytes
	frame_bytes := encode_frame(.text, payload, true)

	assert frame_bytes[0] == 0x81, 'FIN + text opcode'
	assert frame_bytes[1] == 126, 'Extended length marker (126)'

	// 16-bit length: 200 = 0x00C8
	assert frame_bytes[2] == 0x00, 'Length high byte'
	assert frame_bytes[3] == 0xC8, 'Length low byte'

	// Total: 4 header + 200 payload
	assert frame_bytes.len == 204, 'Total frame length should be 204'
}

// ============================================================================
// Frame Decoding Tests
// ============================================================================

// test_decode_text_frame verifies decoding of a simple text frame.
fn test_decode_text_frame() {
	// Build a frame manually: FIN + text, length 5, payload "hello"
	raw := [u8(0x81), 0x05, `h`, `e`, `l`, `l`, `o`]
	result := decode_frame(raw, 1024) or {
		assert false, 'decode_frame returned none for valid frame'
		return
	}

	frame := result.0
	consumed := result.1

	assert frame.fin == true, 'FIN should be true'
	assert frame.opcode == .text, 'Opcode should be text'
	assert frame.masked == false, 'Frame should not be masked'
	assert frame.payload_len == 5, 'Payload length should be 5'
	assert frame.payload_as_text() == 'hello', 'Payload should be "hello"'
	assert consumed == 7, 'Should consume 7 bytes'
}

// test_decode_masked_frame verifies decoding of a masked client frame.
// Client-to-server frames MUST be masked per RFC 6455.
fn test_decode_masked_frame() {
	// Masked frame: FIN + text, masked, length 5, mask key [0x37, 0xfa, 0x21, 0x3d]
	// Masked payload: each byte XOR'd with mask key
	mask_key := [u8(0x37), 0xfa, 0x21, 0x3d]
	original := 'hello'.bytes()
	mut masked_payload := []u8{len: original.len}
	for i in 0 .. original.len {
		masked_payload[i] = original[i] ^ mask_key[i % 4]
	}

	mut raw := [u8(0x81), u8(0x85)] // FIN + text, masked + length 5
	raw << mask_key
	raw << masked_payload

	result := decode_frame(raw, 1024) or {
		assert false, 'decode_frame returned none for valid masked frame'
		return
	}

	frame := result.0
	assert frame.fin == true, 'FIN should be true'
	assert frame.masked == true, 'Frame should be masked'
	assert frame.payload_as_text() == 'hello', 'Unmasked payload should be "hello"'
}

// test_decode_incomplete_frame verifies that an incomplete frame
// returns none (needs more data).
fn test_decode_incomplete_frame() {
	// Only the first byte of a frame — not enough data
	raw := [u8(0x81)]
	result := decode_frame(raw, 1024)
	assert result == none, 'Incomplete frame should return none'
}

// test_decode_oversized_frame verifies that frames exceeding
// max_size are rejected.
fn test_decode_oversized_frame() {
	// Frame claiming 1000 bytes but max_size is 100
	raw := [u8(0x81), 126, 0x03, 0xE8] // length = 1000
	result := decode_frame(raw, 100)
	assert result == none, 'Oversized frame should return none'
}

// ============================================================================
// Roundtrip Tests (Encode -> Decode)
// ============================================================================

// test_roundtrip_text_frame verifies that encoding then decoding a
// text frame produces the original message.
fn test_roundtrip_text_frame() {
	original_message := 'The quick brown fox jumps over the lazy dog'
	encoded := encode_text_frame(original_message)
	result := decode_frame(encoded, 1024) or {
		assert false, 'Roundtrip decode failed'
		return
	}
	decoded_frame := result.0
	assert decoded_frame.payload_as_text() == original_message, 'Roundtrip text mismatch'
	assert decoded_frame.opcode == .text, 'Roundtrip opcode should be text'
	assert decoded_frame.fin == true, 'Roundtrip FIN should be true'
}

// test_roundtrip_binary_frame verifies binary frame roundtrip encoding.
fn test_roundtrip_binary_frame() {
	original_data := [u8(0x00), 0x7F, 0x80, 0xFF, 0x42, 0x13, 0x37]
	encoded := encode_binary_frame(original_data)
	result := decode_frame(encoded, 1024) or {
		assert false, 'Roundtrip binary decode failed'
		return
	}
	decoded_frame := result.0
	assert decoded_frame.payload == original_data, 'Roundtrip binary data mismatch'
	assert decoded_frame.opcode == .binary, 'Roundtrip opcode should be binary'
}

// test_roundtrip_close_frame verifies close frame roundtrip with
// status code extraction.
fn test_roundtrip_close_frame() {
	encoded := encode_close_frame(.protocol_error, 'bad frame')
	result := decode_frame(encoded, 1024) or {
		assert false, 'Roundtrip close decode failed'
		return
	}
	decoded_frame := result.0
	assert decoded_frame.opcode == .close, 'Opcode should be close'

	// Extract status code from payload (first 2 bytes, big-endian)
	if decoded_frame.payload.len >= 2 {
		status := u16(decoded_frame.payload[0]) << 8 | u16(decoded_frame.payload[1])
		assert status == 1002, 'Close code should be 1002 (protocol_error), got ${status}'
	} else {
		assert false, 'Close frame payload too short'
	}
}

// ============================================================================
// Connection Lifecycle Tests
// ============================================================================

// test_new_connection_initial_state verifies that a new connection
// starts in the correct initial state.
fn test_new_connection_initial_state() {
	config := WsConfig{}
	conn := new_ws_connection('test-conn-001', '127.0.0.1:12345', config)

	assert conn.state == .connecting, 'New connection should be in connecting state'
	assert conn.connection_id == 'test-conn-001', 'Connection ID mismatch'
	assert conn.remote_addr == '127.0.0.1:12345', 'Remote addr mismatch'
	assert conn.messages_sent == 0, 'Messages sent should be 0'
	assert conn.messages_received == 0, 'Messages received should be 0'
	assert conn.subscriptions.len == 0, 'Should have no subscriptions'
	assert conn.missed_pongs == 0, 'Missed pongs should be 0'
}

// test_connection_is_open verifies the is_open predicate.
fn test_connection_is_open() {
	config := WsConfig{}
	mut conn := new_ws_connection('test-conn-002', '127.0.0.1:12346', config)

	assert conn.is_open() == false, 'Connecting state should not be open'

	conn.state = .open
	assert conn.is_open() == true, 'Open state should be open'

	conn.state = .closing
	assert conn.is_open() == false, 'Closing state should not be open'

	conn.state = .closed
	assert conn.is_open() == false, 'Closed state should not be open'
}

// ============================================================================
// Subscription Management Tests
// ============================================================================

// test_add_subscription verifies adding subscriptions to a connection.
fn test_add_subscription() {
	config := WsConfig{}
	mut conn := new_ws_connection('test-sub-001', '127.0.0.1:12347', config)

	// Add first subscription
	added := conn.add_subscription('telemetry')
	assert added == true, 'First subscription should succeed'
	assert conn.subscription_count() == 1, 'Should have 1 subscription'

	// Add second subscription (different topic)
	added2 := conn.add_subscription('audit')
	assert added2 == true, 'Second subscription should succeed'
	assert conn.subscription_count() == 2, 'Should have 2 subscriptions'
}

// test_add_duplicate_subscription verifies that duplicate subscriptions
// are rejected (idempotent).
fn test_add_duplicate_subscription() {
	config := WsConfig{}
	mut conn := new_ws_connection('test-sub-002', '127.0.0.1:12348', config)

	conn.add_subscription('telemetry')
	added := conn.add_subscription('telemetry')
	assert added == false, 'Duplicate subscription should be rejected'
	assert conn.subscription_count() == 1, 'Should still have 1 subscription'
}

// test_remove_subscription verifies subscription removal.
fn test_remove_subscription() {
	config := WsConfig{}
	mut conn := new_ws_connection('test-sub-003', '127.0.0.1:12349', config)

	conn.add_subscription('telemetry')
	conn.add_subscription('audit')

	removed := conn.remove_subscription('telemetry')
	assert removed == true, 'Should remove existing subscription'
	assert conn.subscription_count() == 1, 'Should have 1 subscription after removal'
	assert conn.has_subscription('telemetry') == false, 'telemetry should be gone'
	assert conn.has_subscription('audit') == true, 'audit should remain'
}

// test_remove_nonexistent_subscription verifies that removing a
// non-existent subscription returns false.
fn test_remove_nonexistent_subscription() {
	config := WsConfig{}
	mut conn := new_ws_connection('test-sub-004', '127.0.0.1:12350', config)

	removed := conn.remove_subscription('nonexistent')
	assert removed == false, 'Should not remove non-existent subscription'
}

// test_has_subscription verifies the has_subscription predicate.
fn test_has_subscription() {
	config := WsConfig{}
	mut conn := new_ws_connection('test-sub-005', '127.0.0.1:12351', config)

	assert conn.has_subscription('telemetry') == false, 'Should not have telemetry initially'

	conn.add_subscription('telemetry')
	assert conn.has_subscription('telemetry') == true, 'Should have telemetry after adding'
}

// ============================================================================
// Reconnection Backoff Tests
// ============================================================================

// test_backoff_initial_delay verifies the first reconnection delay
// equals the base delay (plus/minus jitter).
fn test_backoff_initial_delay() {
	state := new_reconnect_state()
	config := WsConfig{
		reconnect_base_delay_ms:  1000
		reconnect_max_delay_ms:   60000
		reconnect_jitter_percent: 0 // No jitter for deterministic testing
	}

	delay := calculate_backoff_delay(state, config)
	assert delay == 1000, 'Initial delay should be 1000ms, got ${delay}'
}

// test_backoff_exponential_growth verifies that delay doubles on each attempt.
fn test_backoff_exponential_growth() {
	config := WsConfig{
		reconnect_base_delay_ms:  1000
		reconnect_max_delay_ms:   60000
		reconnect_jitter_percent: 0
	}

	mut state := new_reconnect_state()

	// Attempt 0: 1000ms
	delay0 := calculate_backoff_delay(state, config)
	assert delay0 == 1000, 'Attempt 0 should be 1000ms'

	// Attempt 1: 2000ms
	state.attempt_count = 1
	delay1 := calculate_backoff_delay(state, config)
	assert delay1 == 2000, 'Attempt 1 should be 2000ms'

	// Attempt 2: 4000ms
	state.attempt_count = 2
	delay2 := calculate_backoff_delay(state, config)
	assert delay2 == 4000, 'Attempt 2 should be 4000ms'

	// Attempt 3: 8000ms
	state.attempt_count = 3
	delay3 := calculate_backoff_delay(state, config)
	assert delay3 == 8000, 'Attempt 3 should be 8000ms'
}

// test_backoff_ceiling verifies that delay is clamped to the maximum.
fn test_backoff_ceiling() {
	config := WsConfig{
		reconnect_base_delay_ms:  1000
		reconnect_max_delay_ms:   60000
		reconnect_jitter_percent: 0
	}

	mut state := new_reconnect_state()
	state.attempt_count = 10 // 1000 * 2^10 = 1024000 > 60000

	delay := calculate_backoff_delay(state, config)
	assert delay == 60000, 'Delay should be clamped to 60000ms ceiling, got ${delay}'
}

// test_should_reconnect verifies the reconnection attempt limit.
fn test_should_reconnect() {
	config := WsConfig{
		reconnect_max_attempts: 5
	}

	mut state := new_reconnect_state()
	assert should_reconnect(state, config) == true, 'Should reconnect at attempt 0'

	state.attempt_count = 4
	assert should_reconnect(state, config) == true, 'Should reconnect at attempt 4'

	state.attempt_count = 5
	assert should_reconnect(state, config) == false, 'Should NOT reconnect at attempt 5 (limit reached)'
}

// ============================================================================
// HTTP Upgrade Handshake Tests
// ============================================================================

// test_valid_upgrade_request verifies that a properly formatted
// upgrade request is accepted.
fn test_valid_upgrade_request() {
	mut headers := map[string]string{}
	headers['Upgrade'] = 'websocket'
	headers['Connection'] = 'Upgrade'
	headers['Sec-WebSocket-Key'] = 'dGhlIHNhbXBsZSBub25jZQ=='
	headers['Sec-WebSocket-Version'] = '13'

	result := validate_upgrade_request(headers)
	assert result.success == true, 'Valid upgrade should succeed'
	assert result.accept_key.len > 0, 'Accept key should be non-empty'
	assert result.error_reason == '', 'No error reason on success'
}

// test_missing_upgrade_header verifies rejection when Upgrade header is missing.
fn test_missing_upgrade_header() {
	mut headers := map[string]string{}
	headers['Connection'] = 'Upgrade'
	headers['Sec-WebSocket-Key'] = 'dGhlIHNhbXBsZSBub25jZQ=='
	headers['Sec-WebSocket-Version'] = '13'

	result := validate_upgrade_request(headers)
	assert result.success == false, 'Missing Upgrade header should fail'
	assert result.error_reason.contains('Upgrade'), 'Error should mention Upgrade header'
}

// test_wrong_websocket_version verifies rejection of unsupported versions.
fn test_wrong_websocket_version() {
	mut headers := map[string]string{}
	headers['Upgrade'] = 'websocket'
	headers['Connection'] = 'Upgrade'
	headers['Sec-WebSocket-Key'] = 'dGhlIHNhbXBsZSBub25jZQ=='
	headers['Sec-WebSocket-Version'] = '8'

	result := validate_upgrade_request(headers)
	assert result.success == false, 'Version 8 should be rejected'
	assert result.error_reason.contains('version'), 'Error should mention version'
}

// test_missing_websocket_key verifies rejection when the key is missing.
fn test_missing_websocket_key() {
	mut headers := map[string]string{}
	headers['Upgrade'] = 'websocket'
	headers['Connection'] = 'Upgrade'
	headers['Sec-WebSocket-Version'] = '13'

	result := validate_upgrade_request(headers)
	assert result.success == false, 'Missing key should fail'
	assert result.error_reason.contains('Key'), 'Error should mention Key'
}

// ============================================================================
// Heartbeat Tests
// ============================================================================

// test_heartbeat_alive verifies that a connection with recent pong
// responses is considered alive.
fn test_heartbeat_alive() {
	config := WsConfig{
		heartbeat_timeout_ms: 10000
	}
	mut conn := new_ws_connection('test-hb-001', '127.0.0.1:12352', config)
	conn.state = .open
	conn.last_pong_recv_at = 0 // Never received a pong (fresh connection)
	conn.missed_pongs = 0

	status := check_heartbeat(conn)
	assert status.is_alive == true, 'Fresh connection should be alive'
}

// test_heartbeat_dead verifies that a connection with too many missed
// pongs is considered dead.
fn test_heartbeat_dead() {
	config := WsConfig{
		heartbeat_timeout_ms: 10000
	}
	mut conn := new_ws_connection('test-hb-002', '127.0.0.1:12353', config)
	conn.state = .open
	conn.missed_pongs = 5 // More than 3 = dead

	status := check_heartbeat(conn)
	assert status.is_alive == false, 'Connection with 5 missed pongs should be dead'
	assert status.missed_pongs == 5, 'Should report 5 missed pongs'
}

// test_ping_payload_generation verifies that ping payloads are generated
// with the expected format.
fn test_ping_payload_generation() {
	payload := generate_ping_payload()
	payload_str := payload.bytestr()
	assert payload_str.starts_with('aerie-ping:'), 'Ping payload should start with "aerie-ping:"'
}

// ============================================================================
// Opcode Utility Tests
// ============================================================================

// test_opcode_from_u8_valid verifies conversion of valid opcode bytes.
fn test_opcode_from_u8_valid() {
	assert opcode_from_u8(0x0) or { WsOpcode.close } == WsOpcode.continuation
	assert opcode_from_u8(0x1) or { WsOpcode.close } == WsOpcode.text
	assert opcode_from_u8(0x2) or { WsOpcode.close } == WsOpcode.binary
	assert opcode_from_u8(0x8) or { WsOpcode.text } == WsOpcode.close
	assert opcode_from_u8(0x9) or { WsOpcode.close } == WsOpcode.ping
	assert opcode_from_u8(0xA) or { WsOpcode.close } == WsOpcode.pong
}

// test_opcode_from_u8_reserved verifies rejection of reserved opcodes.
fn test_opcode_from_u8_reserved() {
	// Opcodes 0x3-0x7 and 0xB-0xF are reserved
	result := opcode_from_u8(0x3)
	assert result == none, 'Reserved opcode 0x3 should return none'

	result2 := opcode_from_u8(0xF)
	assert result2 == none, 'Reserved opcode 0xF should return none'
}

// test_opcode_name verifies human-readable opcode names.
fn test_opcode_name() {
	assert opcode_name(.text) == 'text'
	assert opcode_name(.binary) == 'binary'
	assert opcode_name(.close) == 'close'
	assert opcode_name(.ping) == 'ping'
	assert opcode_name(.pong) == 'pong'
	assert opcode_name(.continuation) == 'continuation'
}

// ============================================================================
// State Name Tests
// ============================================================================

// test_state_name verifies human-readable state names.
fn test_state_name() {
	assert state_name(.connecting) == 'connecting'
	assert state_name(.open) == 'open'
	assert state_name(.closing) == 'closing'
	assert state_name(.closed) == 'closed'
}

// ============================================================================
// Connection Statistics Tests
// ============================================================================

// test_connection_stats verifies statistics snapshot generation.
fn test_connection_stats() {
	config := WsConfig{}
	mut conn := new_ws_connection('test-stats-001', '10.0.0.1:8080', config)
	conn.state = .open
	conn.messages_sent = 100
	conn.messages_received = 50
	conn.bytes_sent = 4096
	conn.bytes_received = 2048

	stats := connection_stats(conn)
	assert stats.connection_id == 'test-stats-001', 'Connection ID mismatch'
	assert stats.remote_addr == '10.0.0.1:8080', 'Remote addr mismatch'
	assert stats.state == 'open', 'State should be "open"'
	assert stats.messages_sent == 100, 'Messages sent mismatch'
	assert stats.messages_received == 50, 'Messages received mismatch'
}

// test_stats_to_json verifies JSON serialisation of statistics.
fn test_stats_to_json() {
	stats := WsConnectionStats{
		connection_id:      'json-test'
		remote_addr:        '1.2.3.4:5678'
		state:              'open'
		uptime_seconds:     120
		messages_sent:      10
		messages_received:  5
		bytes_sent:         1024
		bytes_received:     512
		subscription_count: 2
		missed_pongs:       0
		total_reconnects:   1
	}

	json := stats_to_json(stats)
	assert json.contains('"connection_id":"json-test"'), 'JSON should contain connection_id'
	assert json.contains('"state":"open"'), 'JSON should contain state'
	assert json.contains('"messages_sent":10'), 'JSON should contain messages_sent'
}

// ============================================================================
// Health Status Tests
// ============================================================================

// test_ws_health_status_enabled verifies health status when WebSocket is enabled.
fn test_ws_health_status_enabled() {
	json := ws_health_status(true, 4002, 42)
	assert json.contains('"enabled":true'), 'Should show enabled'
	assert json.contains('"port":4002'), 'Should show port'
	assert json.contains('"active_connections":42'), 'Should show connection count'
}

// test_ws_health_status_disabled verifies health status when WebSocket is disabled.
fn test_ws_health_status_disabled() {
	json := ws_health_status(false, 0, 0)
	assert json.contains('"enabled":false'), 'Should show disabled'
}
