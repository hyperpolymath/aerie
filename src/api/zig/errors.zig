// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// errors.zig — the gateway's error taxonomy. One place decides which
// HTTP status an error becomes; resolvers and middleware classify, they
// do not hand-pick codes. REST errors return their real status (the
// Phase-1 fix for the old everything-is-200 bodies); GraphQL keeps
// 200-with-errors per its spec.

const std = @import("std");

pub const ApiError = error{
    BadRequest,          // 400 — malformed input
    Unauthorized,        // 401 — missing/invalid key (Phase 2)
    Forbidden,           // 403 — no entitlement for the module (Phase 2)
    NotFound,            // 404 — unknown route (or stealth denial)
    MethodNotAllowed,    // 405 — wrong verb
    TooManyRequests,     // 429 — rate limit (Phase 3)
    UpstreamUnavailable, // 502 — probe down / connector failed
    UpstreamTimeout,     // 504 — probe timed out
    Internal,            // 500 — the boundary case
};

pub fn statusOf(err: ApiError) u16 {
    return switch (err) {
        ApiError.BadRequest => 400,
        ApiError.Unauthorized => 401,
        ApiError.Forbidden => 403,
        ApiError.NotFound => 404,
        ApiError.MethodNotAllowed => 405,
        ApiError.TooManyRequests => 429,
        ApiError.UpstreamUnavailable => 502,
        ApiError.UpstreamTimeout => 504,
        ApiError.Internal => 500,
    };
}

pub fn messageOf(err: ApiError) []const u8 {
    return switch (err) {
        ApiError.BadRequest => "bad request",
        ApiError.Unauthorized => "missing or invalid API key",
        ApiError.Forbidden => "no entitlement for this module",
        ApiError.NotFound => "not found",
        ApiError.MethodNotAllowed => "method not allowed",
        ApiError.TooManyRequests => "rate limit exceeded",
        ApiError.UpstreamUnavailable => "upstream probe unavailable",
        ApiError.UpstreamTimeout => "upstream probe timed out",
        ApiError.Internal => "internal error",
    };
}

test "errors: taxonomy maps to distinct, honest statuses" {
    try std.testing.expectEqual(@as(u16, 400), statusOf(ApiError.BadRequest));
    try std.testing.expectEqual(@as(u16, 401), statusOf(ApiError.Unauthorized));
    try std.testing.expectEqual(@as(u16, 429), statusOf(ApiError.TooManyRequests));
    try std.testing.expectEqual(@as(u16, 504), statusOf(ApiError.UpstreamTimeout));
}
