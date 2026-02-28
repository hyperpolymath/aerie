// SPDX-License-Identifier: PMPL-1.0-or-later
//
// verb_governance.v — HTTP Verb Governance & Stealth Mode
//
// Ported from http-capability-gateway (Elixir) into V-lang.
// Enforces which HTTP methods are permitted per route, rejecting
// all others. Stealth mode returns 404 (not 403/405) for denied
// requests so attackers cannot distinguish "exists but denied"
// from "does not exist".
//
// Design influences:
//   - http-capability-gateway: verb governance DSL, stealth mode, O(1) lookups
//   - hybrid-automation-router: pattern-based routing table, policy engine
//   - cadre-router: route metadata with auth requirements
//
// Phase 1: Hardcoded verb rules (compiled into binary).
// Phase 2: YAML policy file loaded at startup (hot-reloadable).

module main

// VerbRule defines the allowed HTTP methods for a route pattern.
// Matches are checked in order; first match wins.
struct VerbRule {
pub:
	pattern string    // URL prefix to match (e.g., "/graphql", "/api/v1/telemetry")
	verbs   []string  // Allowed HTTP verbs (e.g., ["POST"], ["GET"])
	name    string    // Human-readable rule name for audit logging
}

// VerbGovernor holds the compiled verb rules and stealth configuration.
// Designed for O(1) lookups in Phase 2 (currently O(n) linear scan,
// sufficient for <20 routes).
struct VerbGovernor {
pub:
	rules        []VerbRule
	stealth_mode bool   // If true, return 404 instead of 405 for denied verbs
}

// VerbDecision is the result of checking a request against verb rules.
pub struct VerbDecision {
pub:
	allowed    bool
	matched    bool     // True if a rule matched the route (vs. no rule found)
	rule_name  string   // Which rule matched (empty if none)
	verb       string   // The HTTP verb that was requested
	stealth    bool     // True if denial should be disguised as 404
}

// new_verb_governor creates a VerbGovernor with the default aerie rules.
//
// Rules are ordered by specificity (most specific first). The gateway
// only permits the minimum required verbs per endpoint:
//
//   /graphql          — POST only (GraphQL spec requires POST)
//   /api/v1/health    — GET only  (health checks are read-only)
//   /api/v1/telemetry — GET only  (probe data is read-only)
//   /api/v1/routes    — GET only  (route lookups are read-only)
//   /api/v1/audit     — GET only  (audit log is read-only)
//
// OPTIONS is allowed on all routes for CORS preflight.
// All other verb/route combinations are denied.
pub fn new_verb_governor() VerbGovernor {
	return VerbGovernor{
		rules: [
			// CORS preflight must be allowed everywhere
			VerbRule{
				pattern: '/'
				verbs:   ['OPTIONS']
				name:    'cors-preflight'
			},
			// GraphQL requires POST (mutations + queries both use POST)
			VerbRule{
				pattern: '/graphql'
				verbs:   ['POST', 'OPTIONS']
				name:    'graphql-endpoint'
			},
			// Health check — GET only, always accessible
			VerbRule{
				pattern: '/api/v1/health'
				verbs:   ['GET', 'OPTIONS']
				name:    'health-check'
			},
			// REST endpoints — GET only (all probe data is read-only)
			VerbRule{
				pattern: '/api/v1/telemetry'
				verbs:   ['GET', 'OPTIONS']
				name:    'rest-telemetry'
			},
			VerbRule{
				pattern: '/api/v1/routes'
				verbs:   ['GET', 'OPTIONS']
				name:    'rest-routes'
			},
			VerbRule{
				pattern: '/api/v1/audit'
				verbs:   ['GET', 'OPTIONS']
				name:    'rest-audit'
			},
		]
		stealth_mode: true
	}
}

// check evaluates an HTTP request's method and URL against the verb
// governance rules. Returns a VerbDecision indicating whether the
// request is allowed.
//
// Matching logic:
//   1. Find the most specific rule whose pattern matches the URL prefix
//   2. Check if the request's HTTP verb is in that rule's allowed list
//   3. If no rule matches, the request is denied (unknown route)
//   4. If stealth_mode is on, denials look like 404 Not Found
//
// The CORS preflight rule (pattern "/") is checked last as a fallback
// — it only fires if no more specific rule matches and the method is
// OPTIONS.
pub fn (g VerbGovernor) check(method string, url string) VerbDecision {
	verb := method.to_upper()

	// Find the most specific matching rule (skip the catch-all CORS rule)
	for rule in g.rules {
		if rule.pattern == '/' {
			continue
		}
		if url.starts_with(rule.pattern) {
			// Rule matched — check if verb is allowed
			if verb in rule.verbs {
				return VerbDecision{
					allowed:   true
					matched:   true
					rule_name: rule.name
					verb:      verb
					stealth:   false
				}
			}
			// Verb not allowed for this route
			return VerbDecision{
				allowed:   false
				matched:   true
				rule_name: rule.name
				verb:      verb
				stealth:   g.stealth_mode
			}
		}
	}

	// No specific rule matched — check CORS fallback for OPTIONS
	if verb == 'OPTIONS' {
		return VerbDecision{
			allowed:   true
			matched:   true
			rule_name: 'cors-preflight'
			verb:      verb
			stealth:   false
		}
	}

	// No rule matched at all — unknown route, deny
	return VerbDecision{
		allowed:   false
		matched:   false
		rule_name: ''
		verb:      verb
		stealth:   g.stealth_mode
	}
}

// denial_status_code returns the HTTP status code to use when denying
// a request. In stealth mode, returns 404 (indistinguishable from a
// genuine not-found). In normal mode, returns 405 Method Not Allowed.
pub fn (d VerbDecision) denial_status_code() int {
	if d.stealth {
		return 404
	}
	return 405
}

// denial_body returns the response body for a denied request.
// In stealth mode, the body is identical to a genuine 404 response
// so attackers cannot fingerprint the difference.
pub fn (d VerbDecision) denial_body(cfg ProtocolConfig) string {
	if d.stealth {
		// Stealth: identical to genuine 404 — do not leak verb info
		return not_found_response(cfg)
	}
	return '{"error":"Method not allowed","verb":"${d.verb}","rule":"${d.rule_name}"}'
}
