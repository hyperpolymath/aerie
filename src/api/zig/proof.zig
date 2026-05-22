// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// proof.zig — Proof Envelope Generation
//
// Every API response (GraphQL, gRPC, REST) is wrapped in a ProofEnvelope
// that provides tamper-evident hashing. Phase 1 uses "light" mode (SHA-256
// hash only). Phase 2+ will add Ed448 signatures ("full" mode).
//
// Replaces: proof.v

const std  = @import("std");
const t    = @import("types.zig");

/// Generate a UUID v4 string into `out` (must be at least 37 bytes).
/// Uses std.crypto.random for cryptographically secure bytes.
/// Sets the version 4 and variant bits per RFC 4122.
pub fn generateUuidV4(out: *[37]u8) void {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    // Version 4: bits 12-15 of time_hi_and_version
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    // Variant bits: bits 6-7 of clk_seq_hi_res
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    _ = std.fmt.bufPrint(
        out,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],
            bytes[6],  bytes[7],
            bytes[8],  bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
        },
    ) catch {
        // bufPrint cannot fail for a 37-byte buffer with exactly 36 chars
        // of formatted output; branch unreachable in practice.
        @memcpy(out[0..36], "00000000-0000-4000-8000-000000000000");
        out[36] = 0;
        return;
    };
    out[36] = 0;
}

/// Format the current UTC time as RFC 3339 into `out` (at least 32 bytes).
pub fn formatRfc3339(out: *[32]u8) void {
    const ts = std.time.timestamp();
    const epoch = std.time.epoch.EpochSeconds{ .secs = @bitCast(ts) };
    const day   = epoch.getEpochDay();
    const ds    = epoch.getDaySeconds();

    const yd   = day.calculateYearDay();
    const year = yd.year;
    const md   = yd.calculateMonthDay();
    const month = md.month.numeric();
    const day_n = md.day_index + 1;

    const hour   = ds.getHoursIntoDay();
    const minute = ds.getMinutesIntoHour();
    const second = ds.getSecondsIntoMinute();

    _ = std.fmt.bufPrint(
        out[0..20],
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{ year, month, day_n, hour, minute, second },
    ) catch {};
    out[20] = 0;
}

/// SHA-256 hex digest of `input` written into `out` (65 bytes: 64 hex + null).
pub fn sha256Hex(input: []const u8, out: *[65]u8) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &digest, .{});
    for (digest, 0..) |b, i| {
        _ = std.fmt.bufPrint(out[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};
    }
    out[64] = 0;
}

/// Build a ProofEnvelope for the given response body and policy context.
/// Phase 1: light mode (SHA-256 hashes only). Signature field unused.
pub fn wrapResponse(body: []const u8, policy_context: []const u8) t.ProofEnvelope {
    var env: t.ProofEnvelope = std.mem.zeroes(t.ProofEnvelope);
    sha256Hex(body, &env.result_hash);
    sha256Hex(policy_context, &env.policy_hash);
    generateUuidV4(&env.query_id);
    formatRfc3339(&env.issued_at);
    @memcpy(env.proof_type[0..5], "light");
    env.proof_type[5] = 0;
    return env;
}

/// Serialise a ProofEnvelope to JSON, appending to `buf`.
/// Returns a slice into `buf` of the written bytes.
pub fn envelopeToJson(env: t.ProofEnvelope, buf: []u8) ![]const u8 {
    return try std.fmt.bufPrint(buf,
        "{{\"result_hash\":\"{s}\",\"policy_hash\":\"{s}\"," ++
        "\"query_id\":\"{s}\",\"issued_at\":\"{s}\"," ++
        "\"proof_type\":\"{s}\",\"signature\":\"\"}}",
        .{
            std.mem.sliceTo(&env.result_hash, 0),
            std.mem.sliceTo(&env.policy_hash, 0),
            std.mem.sliceTo(&env.query_id,    0),
            std.mem.sliceTo(&env.issued_at,   0),
            std.mem.sliceTo(&env.proof_type,  0),
        },
    );
}

/// Wrap a JSON body in a proof envelope, returning
///   {"data":<body>,"proof":<envelope>}
/// written into `out`. Returns a slice of the written bytes.
pub fn wrapBodyWithProof(
    body:           []const u8,
    policy_context: []const u8,
    out:            []u8,
) ![]const u8 {
    const env = wrapResponse(body, policy_context);

    var proof_buf: [512]u8 = undefined;
    const proof_json = try envelopeToJson(env, &proof_buf);

    return try std.fmt.bufPrint(out, "{{\"data\":{s},\"proof\":{s}}}", .{ body, proof_json });
}

/// Return the canonical policy context string for a module name.
/// Mirrors policy_context_string() from policy.v.
pub fn policyContextString(module_name: []const u8, out: []u8) ![]const u8 {
    return try std.fmt.bufPrint(
        out,
        "aerie-policy-v1:phase1-permissive:module={s}:entitlements=all",
        .{module_name},
    );
}
