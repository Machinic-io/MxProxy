# TLS test fixture

Self-signed certificate + key used by the proxy's HTTPS integration tests
(`test/proxy_test.zig`). It is a throwaway, test-only identity: self-signed,
tied to no CA, and useless outside these tests — which is exactly why it can
be checked in.

- `localhost.crt` — `CN=127.0.0.1`, `SAN = IP:127.0.0.1, DNS:localhost`,
  ECDSA P-256, valid until 2126.
- `localhost.key` — its PKCS#8 private key (the httpx TLS server accepts
  `PRIVATE KEY` and `EC PRIVATE KEY` PEM labels).

The tests pin `localhost.crt` as the client's trust anchor
(`verify = .caBundle` + `caPem` = the cert), so the full certificate
verification path runs — nothing is skipped except, unavoidably, "issued by a
CA in the system trust store", which no self-signed test cert can satisfy.

## Regenerating

When `test "tls: test fixture certificate is long-lived"` fails (it fires 30
days before expiry), run this in the fixture directory and commit both files:

```sh
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout localhost.key -out localhost.crt -days 36500 -nodes \
  -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1,DNS:localhost"
```
