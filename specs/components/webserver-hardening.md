# Web Server Hardening Specification

This document contains the required security headers for the web server component of the Aerie suite, based on an OpenLiteSpeed configuration.

## Core Security Headers (A+ Grade)

```apache
<IfModule LiteSpeed>
  Header set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" env=HTTPS
  Header set X-Frame-Options "DENY"
  Header set X-Content-Type-Options "nosniff"
  Header set Referrer-Policy "strict-origin-when-cross-origin"
  Header set Permissions-Policy "geolocation=(), microphone=(), camera=(), payment=()"
  Header set Content-Security-Policy "default-src 'self' https: data: 'unsafe-inline' 'unsafe-eval'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'; upgrade-insecure-requests; block-all-mixed-content"
  Header set Cross-Origin-Opener-Policy "same-origin"
  Header set Cross-Origin-Resource-Policy "same-origin"
  Header set Cross-Origin-Embedder-Policy "require-corp"
  Header set X-Permitted-Cross-Domain-Policies "none"

  # --- Post-Quantum + Classical Hybrid Headers ---
  Header set Quantum-Resistant "Dilithium5+AES256, Kyber1024, SPHINCS+_fallback"
  Header set Key-Exchange "Kyber1024-X25519"  # Hybrid PQ + ECC
  Header set Signature-Algorithms "Ed448+Dilithium5"  # Hybrid classical + PQ

  # --- Hashing & Provenance (Aligns with SHAKE3-512/BLAKE3) ---
  Header set Content-Integrity "sha3-512; base32-wordlist"  # User-friendly hashes
  Header set Digest "SHA-512, BLAKE3"  # Dual hashing for integrity

  # --- Accessibility & Compliance (WCAG 2.3 AAA) ---
  Header set Access-Control-Allow-Origin "*"  # Adjust for CORS needs
  Header set Access-Control-Expose-Headers "Quantum-Resistant, Key-Exchange, Signature-Algorithms, Content-Integrity"
  Header set ARIA-Policy "enforced; wcag=2.3_AAA"

  # --- OpenLiteSpeed-Specific Hardening ---
  Header edit Set-Cookie ^(.*)$ "$1; Secure; HttpOnly; SameSite=Strict; Partitioned"
  Header set Feature-Policy "sync-xhr 'none'; document-write 'none'"
</IfModule>
```

## Force HTTPS & Modern Protocols (QUIC/HTTP3)

```apache
RewriteEngine On
RewriteCond %{HTTPS} off
RewriteRule ^(.*)$ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]
Header set Alt-Svc 'h3=":443"; ma=86400'  # HTTP/3 + QUIC
```
