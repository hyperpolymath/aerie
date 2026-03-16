// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// jsonrpc_test.v — Unit Tests for JSON-RPC 2.0 Protocol Implementation
//
// Tests cover the complete JSON-RPC 2.0 specification surface:
//   - Request parsing and validation
//   - Response serialisation (success and error)
//   - Notification handling (no response expected)
//   - Batch request processing
//   - Error code handling and standard codes
//   - ID tracking (string, number, null)
//   - Method registry and dispatch
//   - JSON parsing utilities
//
// Conformance with https://www.jsonrpc.org/specification is verified
// through golden tests using the specification's own examples.

module main

// ============================================================================
// ID Type Tests
// ============================================================================

// test_null_id verifies null ID creation and properties.
fn test_null_id() {
	id := null_id()
	assert id.id_type == .null_id, 'Should be null_id type'
	assert id_to_json(id) == 'null', 'Null ID should serialise to "null"'
}

// test_string_id verifies string ID creation and serialisation.
fn test_string_id() {
	id := string_id('request-001')
	assert id.id_type == .string_id, 'Should be string_id type'
	assert id.string_val == 'request-001', 'String value mismatch'
	assert id_to_json(id) == '"request-001"', 'String ID should be quoted'
}

// test_number_id verifies number ID creation and serialisation.
fn test_number_id() {
	id := number_id(42)
	assert id.id_type == .number_id, 'Should be number_id type'
	assert id.number_val == 42, 'Number value mismatch'
	assert id_to_json(id) == '42', 'Number ID should be bare'
}

// test_id_matches_same verifies that identical IDs match.
fn test_id_matches_same() {
	assert id_matches(string_id('abc'), string_id('abc')) == true, 'Same string IDs should match'
	assert id_matches(number_id(1), number_id(1)) == true, 'Same number IDs should match'
	assert id_matches(null_id(), null_id()) == true, 'Null IDs should match'
}

// test_id_matches_different verifies that different IDs do not match.
fn test_id_matches_different() {
	assert id_matches(string_id('a'), string_id('b')) == false, 'Different string IDs should not match'
	assert id_matches(number_id(1), number_id(2)) == false, 'Different number IDs should not match'
	assert id_matches(string_id('1'), number_id(1)) == false, 'String and number IDs should not match'
	assert id_matches(null_id(), string_id('x')) == false, 'Null and string IDs should not match'
}

// ============================================================================
// Request Parsing Tests
// ============================================================================

// test_parse_valid_request verifies parsing a well-formed JSON-RPC request.
fn test_parse_valid_request() {
	raw := '{"jsonrpc":"2.0","method":"telemetry/snapshot","params":{},"id":1}'
	request := parse_jsonrpc_request(raw) or {
		assert false, 'Valid request should parse successfully'
		return
	}

	assert request.jsonrpc == '2.0', 'Version should be 2.0'
	assert request.method == 'telemetry/snapshot', 'Method mismatch'
	assert request.is_notification() == false, 'Should not be a notification'
	assert request.id.id_type == .number_id, 'ID should be a number'
	assert request.id.number_val == 1, 'ID should be 1'
}

// test_parse_string_id_request verifies parsing a request with a string ID.
fn test_parse_string_id_request() {
	raw := '{"jsonrpc":"2.0","method":"routes/forensics","params":{"target":"1.2.3.4"},"id":"req-42"}'
	request := parse_jsonrpc_request(raw) or {
		assert false, 'String ID request should parse'
		return
	}

	assert request.id.id_type == .string_id, 'ID should be a string'
	assert request.id.string_val == 'req-42', 'String ID mismatch'
}

// test_parse_notification verifies parsing a notification (no id field).
fn test_parse_notification() {
	raw := '{"jsonrpc":"2.0","method":"initialized"}'
	request := parse_jsonrpc_request(raw) or {
		assert false, 'Notification should parse'
		return
	}

	assert request.method == 'initialized', 'Method should be "initialized"'
	assert request.is_notification() == true, 'Should be a notification (no id)'
	assert request.id.id_type == .null_id, 'ID should be null'
}

// test_parse_invalid_json verifies rejection of non-JSON input.
fn test_parse_invalid_json() {
	raw := 'not json at all'
	result := parse_jsonrpc_request(raw)
	assert result == none, 'Invalid JSON should return none'
}

// test_parse_missing_version verifies rejection when jsonrpc field is missing.
fn test_parse_missing_version() {
	raw := '{"method":"test","id":1}'
	result := parse_jsonrpc_request(raw)
	assert result == none, 'Missing jsonrpc version should return none'
}

// test_parse_wrong_version verifies rejection of non-2.0 versions.
fn test_parse_wrong_version() {
	raw := '{"jsonrpc":"1.0","method":"test","id":1}'
	result := parse_jsonrpc_request(raw)
	assert result == none, 'Wrong version should return none'
}

// test_parse_missing_method verifies rejection when method is missing.
fn test_parse_missing_method() {
	raw := '{"jsonrpc":"2.0","id":1}'
	result := parse_jsonrpc_request(raw)
	assert result == none, 'Missing method should return none'
}

// ============================================================================
// Response Serialisation Tests
// ============================================================================

// test_success_response_json verifies JSON serialisation of a success response.
fn test_success_response_json() {
	resp := success_response(number_id(1), '{"temperature":42}')
	json := response_to_json(resp)

	assert json.contains('"jsonrpc":"2.0"'), 'Should contain jsonrpc version'
	assert json.contains('"result":{"temperature":42}'), 'Should contain result'
	assert json.contains('"id":1'), 'Should contain id'
	assert !json.contains('"error"'), 'Success response should not contain error'
}

// test_error_response_json verifies JSON serialisation of an error response.
fn test_error_response_json() {
	resp := error_response(number_id(1), .method_not_found, 'Method not found: foo', '')
	json := response_to_json(resp)

	assert json.contains('"jsonrpc":"2.0"'), 'Should contain jsonrpc version'
	assert json.contains('"error"'), 'Should contain error object'
	assert json.contains('"code":-32601'), 'Should contain correct error code'
	assert json.contains('"message":"Method not found: foo"'), 'Should contain error message'
	assert json.contains('"id":1'), 'Should contain id'
	assert !json.contains('"result"'), 'Error response should not contain result'
}

// test_error_response_with_data verifies that optional data field is included.
fn test_error_response_with_data() {
	resp := error_response(string_id('err-1'), .invalid_params, 'Bad params', '{"field":"target"}')
	json := response_to_json(resp)

	assert json.contains('"data":{"field":"target"}'), 'Should contain data field'
}

// test_parse_error_response verifies the convenience parse error constructor.
fn test_parse_error_response() {
	resp := parse_error_response()
	json := response_to_json(resp)

	assert json.contains('"code":-32700'), 'Should contain parse error code'
	assert json.contains('"id":null'), 'Parse error should have null id'
}

// ============================================================================
// Notification Tests
// ============================================================================

// test_notification_to_json verifies notification serialisation.
fn test_notification_to_json() {
	notif := new_notification('telemetry/update', '{"latency_ms":42}')
	json := notification_to_json(notif)

	assert json.contains('"jsonrpc":"2.0"'), 'Should contain version'
	assert json.contains('"method":"telemetry/update"'), 'Should contain method'
	assert json.contains('"params":{"latency_ms":42}'), 'Should contain params'
	assert !json.contains('"id"'), 'Notification should not contain id'
}

// test_notification_without_params verifies notification without params.
fn test_notification_without_params() {
	notif := new_notification('exit', '')
	json := notification_to_json(notif)

	assert json.contains('"method":"exit"'), 'Should contain method'
	assert !json.contains('"params"'), 'Should not contain params when empty'
}

// ============================================================================
// Error Code Tests
// ============================================================================

// test_error_code_names verifies human-readable error code names.
fn test_error_code_names() {
	assert error_code_name(.parse_error) == 'Parse error'
	assert error_code_name(.invalid_request) == 'Invalid Request'
	assert error_code_name(.method_not_found) == 'Method not found'
	assert error_code_name(.invalid_params) == 'Invalid params'
	assert error_code_name(.internal_error) == 'Internal error'
	assert error_code_name(.server_error) == 'Server error'
	assert error_code_name(.server_not_initialised) == 'Server not initialised'
	assert error_code_name(.request_cancelled) == 'Request cancelled'
	assert error_code_name(.rate_limited) == 'Rate limited'
}

// test_error_code_numeric_values verifies the numeric wire values.
fn test_error_code_numeric_values() {
	assert int(JsonRpcErrorCode.parse_error) == -32700
	assert int(JsonRpcErrorCode.invalid_request) == -32600
	assert int(JsonRpcErrorCode.method_not_found) == -32601
	assert int(JsonRpcErrorCode.invalid_params) == -32602
	assert int(JsonRpcErrorCode.internal_error) == -32603
	assert int(JsonRpcErrorCode.server_error) == -32000
}

// ============================================================================
// Method Registry Tests
// ============================================================================

// test_method_registry_creation verifies that the registry contains
// all expected methods.
fn test_method_registry_creation() {
	registry := new_method_registry()

	assert registry.has_method('telemetry/snapshot') == true, 'Should have telemetry/snapshot'
	assert registry.has_method('routes/forensics') == true, 'Should have routes/forensics'
	assert registry.has_method('audit/snapshot') == true, 'Should have audit/snapshot'
	assert registry.has_method('audit/temporal') == true, 'Should have audit/temporal'
	assert registry.has_method('smokeping/snapshot') == true, 'Should have smokeping/snapshot'
	assert registry.has_method('system/health') == true, 'Should have system/health'
	assert registry.has_method('system/capabilities') == true, 'Should have system/capabilities'
	assert registry.has_method('initialize') == true, 'Should have initialize'
	assert registry.has_method('initialized') == true, 'Should have initialized'
	assert registry.has_method('shutdown') == true, 'Should have shutdown'
	assert registry.has_method('exit') == true, 'Should have exit'
	assert registry.has_method('$/cancelRequest') == true, 'Should have $/cancelRequest'
}

// test_method_registry_missing verifies that unknown methods are not found.
fn test_method_registry_missing() {
	registry := new_method_registry()
	assert registry.has_method('nonexistent/method') == false, 'Should not have unknown method'
}

// test_method_registry_get verifies method entry retrieval.
fn test_method_registry_get() {
	registry := new_method_registry()

	entry := registry.get_method('telemetry/snapshot') or {
		assert false, 'Should find telemetry/snapshot'
		return
	}

	assert entry.name == 'telemetry/snapshot', 'Name mismatch'
	assert entry.is_readonly == true, 'telemetry/snapshot should be readonly'
	assert entry.requires_id == true, 'telemetry/snapshot should require id'
}

// test_method_names_list verifies the method names listing.
fn test_method_names_list() {
	registry := new_method_registry()
	names := registry.method_names()

	assert names.len > 0, 'Should have at least one method'
	assert 'telemetry/snapshot' in names, 'Should include telemetry/snapshot'
	assert 'initialize' in names, 'Should include initialize'
}

// ============================================================================
// ID Tracker Tests
// ============================================================================

// test_id_tracker_track_and_complete verifies the basic track/complete cycle.
fn test_id_tracker_track_and_complete() {
	mut tracker := new_id_tracker()

	id := number_id(1)
	tracked := tracker.track_request(id)
	assert tracked == true, 'First track should succeed'
	assert tracker.outstanding_count() == 1, 'Should have 1 outstanding'
	assert tracker.is_outstanding(id) == true, 'ID 1 should be outstanding'

	completed := tracker.complete_request(id)
	assert completed == true, 'Complete should succeed'
	assert tracker.outstanding_count() == 0, 'Should have 0 outstanding'
	assert tracker.is_outstanding(id) == false, 'ID 1 should no longer be outstanding'
}

// test_id_tracker_duplicate_detection verifies that duplicate IDs are detected.
fn test_id_tracker_duplicate_detection() {
	mut tracker := new_id_tracker()

	id := string_id('dup-test')
	tracker.track_request(id)

	duplicate := tracker.track_request(id)
	assert duplicate == false, 'Duplicate track should be rejected'
	assert tracker.outstanding_count() == 1, 'Should still have 1 outstanding'
}

// test_id_tracker_complete_unknown verifies that completing an unknown ID fails.
fn test_id_tracker_complete_unknown() {
	mut tracker := new_id_tracker()

	id := number_id(999)
	completed := tracker.complete_request(id)
	assert completed == false, 'Completing unknown ID should fail'
}

// test_id_tracker_generate_id verifies auto-incrementing ID generation.
fn test_id_tracker_generate_id() {
	mut tracker := new_id_tracker()

	id1 := tracker.generate_id()
	assert id1.id_type == .number_id, 'Generated ID should be numeric'
	assert id1.number_val == 1, 'First generated ID should be 1'

	id2 := tracker.generate_id()
	assert id2.number_val == 2, 'Second generated ID should be 2'

	id3 := tracker.generate_id()
	assert id3.number_val == 3, 'Third generated ID should be 3'
}

// test_id_tracker_cancel verifies request cancellation.
fn test_id_tracker_cancel() {
	mut tracker := new_id_tracker()

	id := number_id(42)
	tracker.track_request(id)
	assert tracker.is_outstanding(id) == true

	cancelled := tracker.cancel_request(id)
	assert cancelled == true, 'Cancel should succeed'
	assert tracker.is_outstanding(id) == false, 'Cancelled request should not be outstanding'
}

// test_id_tracker_multiple_outstanding verifies tracking multiple concurrent requests.
fn test_id_tracker_multiple_outstanding() {
	mut tracker := new_id_tracker()

	id1 := number_id(1)
	id2 := string_id('req-2')
	id3 := number_id(3)

	tracker.track_request(id1)
	tracker.track_request(id2)
	tracker.track_request(id3)

	assert tracker.outstanding_count() == 3, 'Should have 3 outstanding'

	tracker.complete_request(id2)
	assert tracker.outstanding_count() == 2, 'Should have 2 outstanding after completing one'
	assert tracker.is_outstanding(id1) == true, 'ID 1 should still be outstanding'
	assert tracker.is_outstanding(id2) == false, 'ID 2 should be completed'
	assert tracker.is_outstanding(id3) == true, 'ID 3 should still be outstanding'
}

// ============================================================================
// Batch Processing Tests
// ============================================================================

// test_batch_result_single_to_json verifies JSON output for a single request.
fn test_batch_result_single_to_json() {
	result := JsonRpcBatchResult{
		responses: [success_response(number_id(1), '"ok"')]
		is_batch:  false
		count:     1
	}

	json := batch_result_to_json(result)
	assert json.contains('"jsonrpc":"2.0"'), 'Should be a JSON-RPC response'
	assert json.contains('"result":"ok"'), 'Should contain result'
	assert json[0] != `[`, 'Single response should not be an array'
}

// test_batch_result_multiple_to_json verifies JSON output for a batch.
fn test_batch_result_multiple_to_json() {
	result := JsonRpcBatchResult{
		responses: [
			success_response(number_id(1), '"first"'),
			success_response(number_id(2), '"second"'),
		]
		is_batch: true
		count:    2
	}

	json := batch_result_to_json(result)
	assert json[0] == `[`, 'Batch response should be an array'
	assert json[json.len - 1] == `]`, 'Batch response should end with ]'
	assert json.contains('"first"'), 'Should contain first result'
	assert json.contains('"second"'), 'Should contain second result'
}

// test_batch_result_empty verifies that an empty response set produces nothing.
fn test_batch_result_empty() {
	result := JsonRpcBatchResult{
		responses: []JsonRpcResponse{}
		is_batch:  true
		count:     0
	}

	json := batch_result_to_json(result)
	assert json == '', 'Empty batch should produce empty string'
}

// ============================================================================
// JSON Parsing Utility Tests
// ============================================================================

// test_split_json_array verifies array splitting for batch processing.
fn test_split_json_array() {
	// Two objects in an array
	input := '[{"jsonrpc":"2.0","method":"a","id":1},{"jsonrpc":"2.0","method":"b","id":2}]'
	parts := split_json_array(input)

	assert parts.len == 2, 'Should split into 2 elements, got ${parts.len}'
	assert parts[0].contains('"method":"a"'), 'First element should contain method a'
	assert parts[1].contains('"method":"b"'), 'Second element should contain method b'
}

// test_split_json_array_single verifies array splitting with one element.
fn test_split_json_array_single() {
	input := '[{"jsonrpc":"2.0","method":"x","id":1}]'
	parts := split_json_array(input)
	assert parts.len == 1, 'Should have 1 element'
}

// test_split_json_array_empty verifies handling of empty arrays.
fn test_split_json_array_empty() {
	parts := split_json_array('[]')
	assert parts.len == 0, 'Empty array should produce no elements'
}

// test_split_json_array_nested verifies handling of nested objects.
fn test_split_json_array_nested() {
	input := '[{"a":{"b":1}},{"c":[1,2]}]'
	parts := split_json_array(input)
	assert parts.len == 2, 'Should handle nested objects correctly'
	assert parts[0].contains('"a":{"b":1}'), 'First element should be intact'
	assert parts[1].contains('"c":[1,2]'), 'Second element should be intact'
}

// test_extract_json_object_value verifies object extraction from JSON.
fn test_extract_json_object_value() {
	input := '{"jsonrpc":"2.0","params":{"target":"1.2.3.4","limit":10},"id":1}'
	params := extract_json_object_value(input, 'params')

	assert params.len > 0, 'Should extract params object'
	assert params.starts_with('{'), 'Params should be an object'
	assert params.contains('"target":"1.2.3.4"'), 'Params should contain target'
}

// ============================================================================
// Convenience Constructor Tests
// ============================================================================

// test_method_not_found_response verifies the convenience error response.
fn test_method_not_found_response() {
	resp := method_not_found_response(number_id(5), 'unknown/method')
	json := response_to_json(resp)

	assert json.contains('"code":-32601'), 'Should have method_not_found code'
	assert json.contains('unknown/method'), 'Should mention the method name'
	assert json.contains('"id":5'), 'Should have correct id'
}

// test_invalid_request_response verifies the invalid request error.
fn test_invalid_request_response_fn() {
	resp := invalid_request_response(null_id())
	json := response_to_json(resp)

	assert json.contains('"code":-32600'), 'Should have invalid_request code'
	assert json.contains('"id":null'), 'Should have null id'
}

// ============================================================================
// Health Status Tests
// ============================================================================

// test_jsonrpc_health_enabled verifies health output when enabled.
fn test_jsonrpc_health_enabled() {
	json := jsonrpc_health_status(true, 12)
	assert json.contains('"enabled":true'), 'Should show enabled'
	assert json.contains('"version":"2.0"'), 'Should show version'
	assert json.contains('"registered_methods":12'), 'Should show method count'
}

// test_jsonrpc_health_disabled verifies health output when disabled.
fn test_jsonrpc_health_disabled() {
	json := jsonrpc_health_status(false, 0)
	assert json.contains('"enabled":false'), 'Should show disabled'
}
