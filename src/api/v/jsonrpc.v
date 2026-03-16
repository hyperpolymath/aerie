// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// jsonrpc.v — JSON-RPC 2.0 Protocol Implementation
//
// Implements the JSON-RPC 2.0 specification (https://www.jsonrpc.org/specification)
// for the Aerie gateway. JSON-RPC is the wire protocol used by:
//   - MCP (Model Context Protocol) — AI tool orchestration
//   - LSP (Language Server Protocol) — IDE integration
//   - DAP (Debug Adapter Protocol) — debugger communication
//
// This module provides complete support for:
//   - Request messages (method call with id, expects response)
//   - Response messages (result or error, correlated by id)
//   - Notification messages (method call without id, no response)
//   - Batch requests (array of requests processed atomically)
//   - Standard error codes per JSON-RPC 2.0 Section 5.1
//   - ID tracking for request/response correlation
//
// The JSON-RPC protocol runs over any transport (TCP, WebSocket, stdio).
// This module is transport-agnostic — it handles message parsing,
// validation, routing, and response generation. Transport binding is
// handled by the caller (e.g., WebSocket frames, TCP streams, stdin/stdout).
//
// Architecture:
//   - Stateless message processing (no session state in this module)
//   - ID tracking is caller's responsibility (this module validates format)
//   - Method dispatch maps to Aerie resolvers via MethodRegistry
//   - Batch support processes requests in order, collects responses
//
// Design influences:
//   - MCP specification: method naming conventions, notification patterns
//   - LSP specification: initialisation handshake, capability negotiation
//   - cadre-router: method dispatch via trie lookup

module main

import time

// ============================================================================
// JSON-RPC 2.0 Constants
// ============================================================================

// The JSON-RPC protocol version string. Every request and response
// MUST include this exact string in the "jsonrpc" field.
const jsonrpc_version = '2.0'

// ============================================================================
// JSON-RPC 2.0 Error Codes (Section 5.1)
// ============================================================================

// JsonRpcErrorCode defines the standard error codes from JSON-RPC 2.0
// Section 5.1, plus the server error range (-32000 to -32099) reserved
// for implementation-defined errors.
//
// Error code ranges:
//   -32700           : Parse error (invalid JSON)
//   -32600           : Invalid Request (not a valid JSON-RPC object)
//   -32601           : Method not found
//   -32602           : Invalid params
//   -32603           : Internal error
//   -32000 to -32099 : Server error (implementation-defined)
pub enum JsonRpcErrorCode as i32 {
	parse_error      = -32700 // Invalid JSON received by the server
	invalid_request  = -32600 // The JSON sent is not a valid Request object
	method_not_found = -32601 // The method does not exist or is not available
	invalid_params   = -32602 // Invalid method parameter(s)
	internal_error   = -32603 // Internal JSON-RPC error
	// Server errors (-32000 to -32099) — Aerie-specific
	server_error            = -32000 // Generic server error
	server_not_initialised  = -32001 // Server not yet initialised (MCP/LSP pattern)
	server_shutting_down    = -32002 // Server is shutting down
	request_cancelled       = -32003 // Request was cancelled by the client
	rate_limited            = -32004 // Too many requests (Aerie policy gate)
}

// error_code_name returns a human-readable label for the given error code.
// Used in audit logging and error response generation.
pub fn error_code_name(code JsonRpcErrorCode) string {
	return match code {
		.parse_error { 'Parse error' }
		.invalid_request { 'Invalid Request' }
		.method_not_found { 'Method not found' }
		.invalid_params { 'Invalid params' }
		.internal_error { 'Internal error' }
		.server_error { 'Server error' }
		.server_not_initialised { 'Server not initialised' }
		.server_shutting_down { 'Server shutting down' }
		.request_cancelled { 'Request cancelled' }
		.rate_limited { 'Rate limited' }
	}
}

// ============================================================================
// JSON-RPC 2.0 Message Types
// ============================================================================

// JsonRpcIdType discriminates the type of the "id" field in a JSON-RPC
// message. The spec allows string, number, or null. Null id indicates
// a notification (no response expected).
pub enum JsonRpcIdType {
	string_id  // "id": "abc-123"
	number_id  // "id": 42
	null_id    // "id": null (or absent — notification)
}

// JsonRpcId represents the polymorphic "id" field from a JSON-RPC
// message. The id is used to correlate requests with responses.
// Notifications have a null id (no response expected).
pub struct JsonRpcId {
pub:
	id_type    JsonRpcIdType
	string_val string // Populated when id_type == .string_id
	number_val i64    // Populated when id_type == .number_id
}

// null_id creates a null JsonRpcId (used for notifications).
pub fn null_id() JsonRpcId {
	return JsonRpcId{
		id_type:    .null_id
		string_val: ''
		number_val: 0
	}
}

// string_id creates a string-typed JsonRpcId.
pub fn string_id(val string) JsonRpcId {
	return JsonRpcId{
		id_type:    .string_id
		string_val: val
		number_val: 0
	}
}

// number_id creates a number-typed JsonRpcId.
pub fn number_id(val i64) JsonRpcId {
	return JsonRpcId{
		id_type:    .number_id
		string_val: ''
		number_val: val
	}
}

// id_to_json serialises a JsonRpcId to its JSON representation.
// String ids are quoted, number ids are bare, null ids are "null".
pub fn id_to_json(id JsonRpcId) string {
	return match id.id_type {
		.string_id { '"${id.string_val}"' }
		.number_id { '${id.number_val}' }
		.null_id { 'null' }
	}
}

// id_matches returns true if two JsonRpcIds are equal. Used to
// correlate responses with their originating requests.
pub fn id_matches(a JsonRpcId, b JsonRpcId) bool {
	if a.id_type != b.id_type {
		return false
	}
	return match a.id_type {
		.string_id { a.string_val == b.string_val }
		.number_id { a.number_val == b.number_val }
		.null_id { true }
	}
}

// ============================================================================
// Request Message
// ============================================================================

// JsonRpcRequest represents an inbound JSON-RPC 2.0 request.
// A request has a method name, optional parameters, and an id for
// response correlation. If the id is null, the message is a notification
// and no response should be sent.
//
// Wire format:
//   {"jsonrpc": "2.0", "method": "telemetry/snapshot", "params": {...}, "id": 1}
pub struct JsonRpcRequest {
pub:
	jsonrpc string     // MUST be "2.0"
	method  string     // Method name (e.g., "telemetry/snapshot")
	params  string     // Raw JSON string of parameters (object or array)
	id      JsonRpcId  // Request id (null for notifications)
}

// is_notification returns true if this request is a notification
// (no id, no response expected).
pub fn (r JsonRpcRequest) is_notification() bool {
	return r.id.id_type == .null_id
}

// ============================================================================
// Response Message
// ============================================================================

// JsonRpcResponse represents an outbound JSON-RPC 2.0 response.
// Contains either a result (on success) or an error (on failure),
// but never both. The id MUST match the originating request.
//
// Wire format (success):
//   {"jsonrpc": "2.0", "result": {...}, "id": 1}
//
// Wire format (error):
//   {"jsonrpc": "2.0", "error": {"code": -32601, "message": "Method not found"}, "id": 1}
pub struct JsonRpcResponse {
pub:
	jsonrpc  string    // Always "2.0"
	id       JsonRpcId // Matches the request id
	is_error bool      // True if this is an error response
	result   string    // JSON result (empty if is_error)
	error    JsonRpcError // Error details (zero-value if !is_error)
}

// JsonRpcError holds the error information for an error response.
// The code and message fields are required; data is optional and
// may contain additional information about the error.
pub struct JsonRpcError {
pub:
	code    JsonRpcErrorCode // Numeric error code
	message string           // Short human-readable description
	data    string           // Optional additional data (JSON string)
}

// ============================================================================
// Response Builders
// ============================================================================

// success_response creates a successful JSON-RPC response with the
// given result payload and request id.
pub fn success_response(id JsonRpcId, result string) JsonRpcResponse {
	return JsonRpcResponse{
		jsonrpc:  jsonrpc_version
		id:       id
		is_error: false
		result:   result
		error:    JsonRpcError{}
	}
}

// error_response creates an error JSON-RPC response with the given
// error code, message, and optional data payload.
pub fn error_response(id JsonRpcId, code JsonRpcErrorCode, message string, data string) JsonRpcResponse {
	return JsonRpcResponse{
		jsonrpc:  jsonrpc_version
		id:       id
		is_error: true
		result:   ''
		error:    JsonRpcError{
			code:    code
			message: message
			data:    data
		}
	}
}

// parse_error_response creates a parse error response. Since the
// request could not be parsed, the id is null per the specification.
pub fn parse_error_response() JsonRpcResponse {
	return error_response(
		null_id(),
		.parse_error,
		'Parse error: invalid JSON',
		''
	)
}

// invalid_request_response creates an invalid request error response.
pub fn invalid_request_response(id JsonRpcId) JsonRpcResponse {
	return error_response(
		id,
		.invalid_request,
		'Invalid Request: not a valid JSON-RPC 2.0 object',
		''
	)
}

// method_not_found_response creates a method not found error response.
pub fn method_not_found_response(id JsonRpcId, method string) JsonRpcResponse {
	return error_response(
		id,
		.method_not_found,
		'Method not found: ${method}',
		''
	)
}

// ============================================================================
// Response Serialisation
// ============================================================================

// response_to_json serialises a JsonRpcResponse to its JSON wire format.
// Produces a complete, valid JSON-RPC 2.0 response object.
pub fn response_to_json(resp JsonRpcResponse) string {
	id_json := id_to_json(resp.id)

	if resp.is_error {
		mut error_json := '{"code":${int(resp.error.code)},"message":"${resp.error.message}"'
		if resp.error.data.len > 0 {
			error_json += ',"data":${resp.error.data}'
		}
		error_json += '}'
		return '{"jsonrpc":"${resp.jsonrpc}","error":${error_json},"id":${id_json}}'
	}

	return '{"jsonrpc":"${resp.jsonrpc}","result":${resp.result},"id":${id_json}}'
}

// ============================================================================
// Notification Message
// ============================================================================

// JsonRpcNotification represents a server-to-client notification.
// Notifications are one-way messages with no id and no response expected.
// The server sends notifications for real-time events like telemetry
// updates, audit events, and route changes.
//
// Wire format:
//   {"jsonrpc": "2.0", "method": "telemetry/update", "params": {...}}
pub struct JsonRpcNotification {
pub:
	jsonrpc string // Always "2.0"
	method  string // Notification method name
	params  string // JSON parameters
}

// notification_to_json serialises a notification to its JSON wire format.
pub fn notification_to_json(notif JsonRpcNotification) string {
	if notif.params.len > 0 {
		return '{"jsonrpc":"${notif.jsonrpc}","method":"${notif.method}","params":${notif.params}}'
	}
	return '{"jsonrpc":"${notif.jsonrpc}","method":"${notif.method}"}'
}

// new_notification creates a new server notification with the given
// method name and parameters.
pub fn new_notification(method string, params string) JsonRpcNotification {
	return JsonRpcNotification{
		jsonrpc: jsonrpc_version
		method:  method
		params:  params
	}
}

// ============================================================================
// Request Parsing
// ============================================================================

// parse_jsonrpc_request parses a raw JSON string into a JsonRpcRequest.
// Validates all required fields per the JSON-RPC 2.0 specification.
//
// Validation rules:
//   - "jsonrpc" field MUST be exactly "2.0"
//   - "method" field MUST be a non-empty string
//   - "params" field is optional (defaults to empty object)
//   - "id" field is optional (absent = notification)
//
// Returns the parsed request, or none if the JSON is invalid or
// does not conform to the JSON-RPC 2.0 specification.
pub fn parse_jsonrpc_request(raw_json string) ?JsonRpcRequest {
	// Validate it looks like a JSON object
	trimmed := raw_json.trim_space()
	if trimmed.len == 0 || trimmed[0] != `{` {
		return none
	}

	// Extract jsonrpc version
	version := extract_json_string_value(raw_json, 'jsonrpc')
	if version != jsonrpc_version {
		return none
	}

	// Extract method (required)
	method := extract_json_string_value(raw_json, 'method')
	if method.len == 0 {
		return none
	}

	// Extract params (optional — default to empty)
	params := extract_json_object_value(raw_json, 'params')

	// Extract id (optional — absent means notification)
	id := extract_jsonrpc_id(raw_json)

	return JsonRpcRequest{
		jsonrpc: version
		method:  method
		params:  params
		id:      id
	}
}

// ============================================================================
// Batch Request Processing
// ============================================================================

// JsonRpcBatchResult holds the results of processing a batch of
// JSON-RPC requests. Batch requests are arrays of individual request
// objects processed atomically.
pub struct JsonRpcBatchResult {
pub:
	responses []JsonRpcResponse // One response per non-notification request
	is_batch  bool              // True if the input was a batch (array)
	count     int               // Total number of requests in the batch
}

// parse_and_process_batch handles both single requests and batch
// requests. If the input is a JSON array, each element is parsed
// and processed individually. Notifications in a batch do not
// generate responses.
//
// Per the spec:
//   - An empty batch array is an invalid request
//   - All requests in a batch are processed independently
//   - Responses may be returned in any order
//   - If a batch contains only notifications, no response is sent
pub fn parse_and_process_batch(raw_json string, mut redis RedisClient, policy PolicyDecision) JsonRpcBatchResult {
	trimmed := raw_json.trim_space()

	// Check if this is a batch request (JSON array)
	if trimmed.len > 0 && trimmed[0] == `[` {
		return process_batch_array(trimmed, mut redis, policy)
	}

	// Single request
	request := parse_jsonrpc_request(trimmed) or {
		return JsonRpcBatchResult{
			responses: [parse_error_response()]
			is_batch:  false
			count:     1
		}
	}

	response := dispatch_jsonrpc_request(request, mut redis, policy)

	// Notifications do not get responses
	if request.is_notification() {
		return JsonRpcBatchResult{
			responses: []JsonRpcResponse{}
			is_batch:  false
			count:     1
		}
	}

	return JsonRpcBatchResult{
		responses: [response]
		is_batch:  false
		count:     1
	}
}

// process_batch_array processes a JSON array of JSON-RPC requests.
// Each request is parsed and dispatched independently.
fn process_batch_array(raw_json string, mut redis RedisClient, policy PolicyDecision) JsonRpcBatchResult {
	// Split the array into individual request strings
	// This is a simplified parser that handles the common case of
	// well-formed JSON arrays of objects.
	requests := split_json_array(raw_json)

	if requests.len == 0 {
		// Empty batch is an invalid request per the spec
		return JsonRpcBatchResult{
			responses: [invalid_request_response(null_id())]
			is_batch:  true
			count:     0
		}
	}

	mut responses := []JsonRpcResponse{}

	for request_json in requests {
		request := parse_jsonrpc_request(request_json) or {
			responses << parse_error_response()
			continue
		}

		response := dispatch_jsonrpc_request(request, mut redis, policy)

		// Only include responses for non-notifications
		if !request.is_notification() {
			responses << response
		}
	}

	return JsonRpcBatchResult{
		responses: responses
		is_batch:  true
		count:     requests.len
	}
}

// batch_result_to_json serialises a batch result to its JSON wire format.
// Single requests return a single response object. Batch requests return
// an array of response objects. Empty response arrays (all notifications)
// return nothing (caller should not send a response).
pub fn batch_result_to_json(result JsonRpcBatchResult) string {
	if result.responses.len == 0 {
		return ''
	}

	if !result.is_batch {
		// Single request — return single response object
		return response_to_json(result.responses[0])
	}

	// Batch request — return array of response objects
	mut parts := []string{}
	for resp in result.responses {
		parts << response_to_json(resp)
	}
	return '[${parts.join(",")}]'
}

// ============================================================================
// Method Dispatch
// ============================================================================

// MethodEntry maps a JSON-RPC method name to its handler metadata.
// Used by the MethodRegistry for method dispatch and capability
// advertisement (MCP/LSP initialisation handshake).
pub struct MethodEntry {
pub:
	name        string // Full method name (e.g., "telemetry/snapshot")
	description string // Human-readable description
	is_readonly bool   // True if the method only reads data (no side effects)
	requires_id bool   // True if this method requires a request id (not a notification)
}

// MethodRegistry holds all registered JSON-RPC methods and provides
// O(1) dispatch by method name. Methods follow the MCP/LSP naming
// convention: "namespace/action" (e.g., "telemetry/snapshot").
pub struct MethodRegistry {
pub:
	methods map[string]MethodEntry
}

// new_method_registry creates a MethodRegistry pre-populated with
// the Aerie gateway's JSON-RPC methods. These methods map to the
// same resolvers used by REST, GraphQL, gRPC, and WebSocket protocols.
//
// Method naming follows the MCP convention (namespace/action):
//   telemetry/snapshot         -> resolve_telemetry
//   routes/forensics           -> resolve_route_forensics
//   audit/snapshot             -> resolve_audit
//   audit/temporal             -> resolve_temporal_audit
//   smokeping/snapshot         -> resolve_smokeping
//   system/health              -> health_check
//   system/capabilities        -> capability advertisement
//   $/cancelRequest            -> request cancellation (LSP convention)
pub fn new_method_registry() MethodRegistry {
	mut methods := map[string]MethodEntry{}

	methods['telemetry/snapshot'] = MethodEntry{
		name:        'telemetry/snapshot'
		description: 'Fetch current telemetry snapshot from LibreSpeed probes'
		is_readonly: true
		requires_id: true
	}
	methods['routes/forensics'] = MethodEntry{
		name:        'routes/forensics'
		description: 'Fetch BGP route forensics for a target IP/hostname'
		is_readonly: true
		requires_id: true
	}
	methods['audit/snapshot'] = MethodEntry{
		name:        'audit/snapshot'
		description: 'Fetch recent audit events from the Redis log'
		is_readonly: true
		requires_id: true
	}
	methods['audit/temporal'] = MethodEntry{
		name:        'audit/temporal'
		description: 'Query bitemporal audit data from VerisimDB'
		is_readonly: true
		requires_id: true
	}
	methods['smokeping/snapshot'] = MethodEntry{
		name:        'smokeping/snapshot'
		description: 'Fetch latency/jitter data from SmokePing probes'
		is_readonly: true
		requires_id: true
	}
	methods['system/health'] = MethodEntry{
		name:        'system/health'
		description: 'Return gateway health status and protocol availability'
		is_readonly: true
		requires_id: true
	}
	methods['system/capabilities'] = MethodEntry{
		name:        'system/capabilities'
		description: 'Advertise available methods and server capabilities'
		is_readonly: true
		requires_id: true
	}
	methods['initialize'] = MethodEntry{
		name:        'initialize'
		description: 'MCP/LSP initialisation handshake'
		is_readonly: true
		requires_id: true
	}
	methods['initialized'] = MethodEntry{
		name:        'initialized'
		description: 'MCP/LSP initialisation complete notification'
		is_readonly: true
		requires_id: false
	}
	methods['shutdown'] = MethodEntry{
		name:        'shutdown'
		description: 'Request graceful server shutdown'
		is_readonly: false
		requires_id: true
	}
	methods['exit'] = MethodEntry{
		name:        'exit'
		description: 'Exit notification (after shutdown)'
		is_readonly: false
		requires_id: false
	}
	methods['$/cancelRequest'] = MethodEntry{
		name:        '$/cancelRequest'
		description: 'Cancel a pending request (LSP convention)'
		is_readonly: false
		requires_id: false
	}

	return MethodRegistry{
		methods: methods
	}
}

// has_method checks whether a method name is registered in this registry.
pub fn (r MethodRegistry) has_method(name string) bool {
	return name in r.methods
}

// get_method retrieves a method entry by name. Returns none if
// the method is not registered.
pub fn (r MethodRegistry) get_method(name string) ?MethodEntry {
	if name in r.methods {
		return r.methods[name]
	}
	return none
}

// method_names returns a list of all registered method names.
// Used by the system/capabilities response.
pub fn (r MethodRegistry) method_names() []string {
	mut names := []string{}
	for name, _ in r.methods {
		names << name
	}
	return names
}

// ============================================================================
// Method Dispatch (Request -> Resolver -> Response)
// ============================================================================

// dispatch_jsonrpc_request routes a parsed JSON-RPC request to the
// appropriate Aerie resolver and wraps the result in a JSON-RPC response.
// Unknown methods return a method_not_found error.
pub fn dispatch_jsonrpc_request(request JsonRpcRequest, mut redis RedisClient, policy PolicyDecision) JsonRpcResponse {
	registry := new_method_registry()

	// Check if method exists
	if !registry.has_method(request.method) {
		return method_not_found_response(request.id, request.method)
	}

	// Dispatch to resolver based on method name
	result := match request.method {
		'telemetry/snapshot' {
			resolve_telemetry(mut redis, policy)
		}
		'routes/forensics' {
			target := extract_json_string_value(request.params, 'target')
			if target.len == 0 {
				response_to_json(error_response(
					request.id,
					.invalid_params,
					'Missing required parameter: target',
					''
				))
			} else {
				resolve_route_forensics(target, mut redis, policy)
			}
		}
		'audit/snapshot' {
			limit_str := extract_json_string_value(request.params, 'limit')
			limit := if limit_str.len > 0 { limit_str.int() } else { 50 }
			resolve_audit(limit, mut redis, policy)
		}
		'audit/temporal' {
			mode := extract_json_string_value(request.params, 'mode')
			if mode.len == 0 {
				response_to_json(error_response(
					request.id,
					.invalid_params,
					'Missing required parameter: mode (as_of, between, history)',
					''
				))
			} else {
				mut params := map[string]string{}
				params['time'] = extract_json_string_value(request.params, 'time')
				params['start'] = extract_json_string_value(request.params, 'start')
				params['end'] = extract_json_string_value(request.params, 'end')
				params['event_id'] = extract_json_string_value(request.params, 'event_id')
				limit_str := extract_json_string_value(request.params, 'limit')
				if limit_str.len > 0 {
					params['limit'] = limit_str
				}
				verisimdb := new_verisimdb_client()
				resolve_temporal_audit(mode, params, mut redis, verisimdb, policy)
			}
		}
		'smokeping/snapshot' {
			target := extract_json_string_value(request.params, 'target')
			if target.len == 0 {
				response_to_json(error_response(
					request.id,
					.invalid_params,
					'Missing required parameter: target',
					''
				))
			} else {
				resolve_smokeping(target, mut redis, policy)
			}
		}
		'system/health' {
			cfg := read_protocol_config()
			health_check(cfg)
		}
		'system/capabilities' {
			capabilities_response(registry)
		}
		'initialize' {
			handle_initialize(request)
		}
		'initialized' {
			// Notification — no response needed
			''
		}
		'shutdown' {
			'{"status":"shutdown_acknowledged"}'
		}
		'exit' {
			// Notification — no response needed
			''
		}
		'$/cancelRequest' {
			// Cancellation is a notification — no response
			''
		}
		else {
			// This branch should never be reached due to the has_method check above,
			// but we handle it defensively.
			return method_not_found_response(request.id, request.method)
		}
	}

	// If the method returned an already-formatted error response, return as-is
	if result.contains('"error"') && result.contains('"jsonrpc"') {
		// Already a full JSON-RPC error — parse and return
		return error_response(request.id, .internal_error, result, '')
	}

	// Notifications and empty results don't get responses
	if result.len == 0 && request.is_notification() {
		return success_response(request.id, 'null')
	}

	return success_response(request.id, result)
}

// capabilities_response generates the system/capabilities response
// listing all available methods and server metadata.
fn capabilities_response(registry MethodRegistry) string {
	mut method_list := []string{}
	for name, entry in registry.methods {
		method_list << '{"name":"${name}","description":"${entry.description}","readonly":${entry.is_readonly}}'
	}
	methods_json := '[${method_list.join(",")}]'

	now := time.now().format_rfc3339()
	return '{"server":"aerie-gateway","version":"0.3.0","protocol":"jsonrpc-2.0","timestamp":"${now}","methods":${methods_json}}'
}

// handle_initialize processes the MCP/LSP "initialize" request and
// returns the server capabilities. This follows the standard MCP
// handshake pattern where the client sends "initialize" and the
// server responds with its capabilities.
fn handle_initialize(request JsonRpcRequest) string {
	now := time.now().format_rfc3339()
	return '{"capabilities":{"telemetry":true,"routes":true,"audit":true,"temporal_audit":true,"smokeping":true},"serverInfo":{"name":"aerie-gateway","version":"0.3.0"},"protocolVersion":"2.0","timestamp":"${now}"}'
}

// ============================================================================
// ID Tracking
// ============================================================================

// IdTracker maintains a set of outstanding request IDs for a single
// client connection. Used to detect duplicate IDs, correlate responses,
// and implement request cancellation.
//
// Thread safety: IdTracker is designed for single-threaded access
// within one connection handler. For multi-connection tracking,
// use a separate IdTracker per connection.
pub struct IdTracker {
pub mut:
	outstanding map[string]i64 // Map of id_json -> unix_timestamp of request
	next_id     i64            // Auto-incrementing counter for server-initiated requests
}

// new_id_tracker creates an empty ID tracker with the counter
// starting at 1 (0 is reserved as "no id").
pub fn new_id_tracker() IdTracker {
	return IdTracker{
		outstanding: map[string]i64{}
		next_id:     1
	}
}

// track_request registers a request ID as outstanding. Returns false
// if the ID is already outstanding (duplicate detection).
pub fn (mut t IdTracker) track_request(id JsonRpcId) bool {
	id_json := id_to_json(id)
	if id_json in t.outstanding {
		return false // Duplicate ID
	}
	t.outstanding[id_json] = time.now().unix()
	return true
}

// complete_request removes a request ID from the outstanding set.
// Called when a response is received for the request. Returns false
// if the ID was not outstanding (unexpected response).
pub fn (mut t IdTracker) complete_request(id JsonRpcId) bool {
	id_json := id_to_json(id)
	if id_json in t.outstanding {
		t.outstanding.delete(id_json)
		return true
	}
	return false
}

// is_outstanding returns true if a request with the given ID is
// still awaiting a response.
pub fn (t IdTracker) is_outstanding(id JsonRpcId) bool {
	id_json := id_to_json(id)
	return id_json in t.outstanding
}

// outstanding_count returns the number of requests awaiting responses.
pub fn (t IdTracker) outstanding_count() int {
	return t.outstanding.len
}

// generate_id creates a new auto-incrementing numeric ID for
// server-initiated requests (e.g., server-to-client method calls).
pub fn (mut t IdTracker) generate_id() JsonRpcId {
	id := number_id(t.next_id)
	t.next_id++
	return id
}

// cancel_request marks a request as cancelled. Removes it from
// the outstanding set and returns true if it was found.
pub fn (mut t IdTracker) cancel_request(id JsonRpcId) bool {
	return t.complete_request(id)
}

// timed_out_requests returns a list of request IDs that have been
// outstanding longer than the given timeout in seconds.
pub fn (t IdTracker) timed_out_requests(timeout_seconds i64) []string {
	now := time.now().unix()
	mut expired := []string{}
	for id_json, timestamp in t.outstanding {
		if now - timestamp > timeout_seconds {
			expired << id_json
		}
	}
	return expired
}

// ============================================================================
// JSON Parsing Utilities
// ============================================================================

// extract_json_string_value extracts a string value from a JSON object
// by key name. Handles both "key":"value" and "key": "value" formats.
// Returns empty string if the key is not found.
fn extract_json_string_value(json string, key string) string {
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

// extract_json_object_value extracts a JSON object or array value
// from a parent JSON object by key name. Handles nested braces/brackets
// by counting depth. Returns empty string if the key is not found.
fn extract_json_object_value(json string, key string) string {
	patterns := ['"${key}":', '"${key}" :']
	for pattern in patterns {
		idx := json.index(pattern) or { continue }
		start := idx + pattern.len

		// Skip whitespace after the colon
		mut pos := start
		for pos < json.len && (json[pos] == ` ` || json[pos] == `\t` || json[pos] == `\n`) {
			pos++
		}

		if pos >= json.len {
			continue
		}

		// Determine the value type by its first character
		first_char := json[pos]
		if first_char == `{` || first_char == `[` {
			// Object or array — find matching closing bracket
			close_char := if first_char == `{` { `}` } else { `]` }
			mut depth := 1
			mut end := pos + 1
			for end < json.len && depth > 0 {
				if json[end] == first_char {
					depth++
				} else if json[end] == close_char {
					depth--
				}
				end++
			}
			if depth == 0 {
				return json[pos..end]
			}
		}
	}
	return ''
}

// extract_jsonrpc_id parses the "id" field from a JSON-RPC message.
// Returns a null_id if the field is absent or null, a string_id if
// the value is a quoted string, or a number_id if it is a bare number.
fn extract_jsonrpc_id(json string) JsonRpcId {
	// Look for "id" field
	patterns := ['"id":', '"id" :']
	for pattern in patterns {
		idx := json.index(pattern) or { continue }
		start := idx + pattern.len

		// Skip whitespace
		mut pos := start
		for pos < json.len && (json[pos] == ` ` || json[pos] == `\t`) {
			pos++
		}

		if pos >= json.len {
			continue
		}

		// Check value type
		if json[pos] == `"` {
			// String id
			end := json.index_after('"', pos + 1) or { continue }
			return string_id(json[pos + 1..end])
		} else if json[pos] == `n` {
			// null
			return null_id()
		} else if json[pos] >= `0` && json[pos] <= `9` || json[pos] == `-` {
			// Number id
			mut end := pos
			if json[end] == `-` {
				end++
			}
			for end < json.len && json[end] >= `0` && json[end] <= `9` {
				end++
			}
			num_str := json[pos..end]
			return number_id(num_str.i64())
		}
	}

	return null_id()
}

// split_json_array splits a JSON array string into individual element
// strings. Handles nested objects and arrays by tracking brace/bracket
// depth. Returns an empty array for invalid input.
fn split_json_array(json string) []string {
	trimmed := json.trim_space()
	if trimmed.len < 2 || trimmed[0] != `[` || trimmed[trimmed.len - 1] != `]` {
		return []string{}
	}

	// Strip outer brackets
	inner := trimmed[1..trimmed.len - 1].trim_space()
	if inner.len == 0 {
		return []string{}
	}

	mut elements := []string{}
	mut depth := 0
	mut start := 0
	mut in_string := false
	mut escape_next := false

	for i, ch in inner.bytes() {
		if escape_next {
			escape_next = false
			continue
		}

		if ch == `\\` && in_string {
			escape_next = true
			continue
		}

		if ch == `"` {
			in_string = !in_string
			continue
		}

		if in_string {
			continue
		}

		if ch == `{` || ch == `[` {
			depth++
		} else if ch == `}` || ch == `]` {
			depth--
		} else if ch == `,` && depth == 0 {
			element := inner[start..i].trim_space()
			if element.len > 0 {
				elements << element
			}
			start = i + 1
		}
	}

	// Last element (after final comma or entire string if no commas)
	last := inner[start..].trim_space()
	if last.len > 0 {
		elements << last
	}

	return elements
}

// ============================================================================
// JSON-RPC Health Status
// ============================================================================

// jsonrpc_health_status returns a JSON health check fragment for the
// JSON-RPC protocol, suitable for inclusion in the gateway's
// /api/v1/health response.
pub fn jsonrpc_health_status(enabled bool, method_count int) string {
	if !enabled {
		return '"jsonrpc":{"enabled":false}'
	}
	return '"jsonrpc":{"enabled":true,"version":"2.0","registered_methods":${method_count}}'
}
