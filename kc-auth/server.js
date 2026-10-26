// Kiro Crew token API. Runs behind oauth2-proxy, which handles Google login + allowlist.
//   GET /kc-auth/health -> {"ok": true}
//   GET /kc-auth/token  -> {"token": "...", "email": "...", "expiresIn": "8h"}
//
// /kc-auth/token mints an OWNER token, so it does not trust headers alone: any
// local process (or, on macOS, any container via host.docker.internal) can
// reach this port and set X-Forwarded-Email. oauth2-proxy forwards the user's
// Google ID token as "Authorization: Bearer <jwt>" (PASS_AUTHORIZATION_HEADER),
// and a token is minted only when that JWT is signed by Google, issued for
// GOOGLE_CLIENT_ID, unexpired, and names a verified email that is on the
// allowlist or ends in @<one of ALLOWED_DOMAINS> (exact domain, as oauth2-proxy).
// No dependencies: Node 18+ (global fetch, JWK keys in node:crypto).
const http = require("http");
const crypto = require("crypto");
const fs = require("fs");
const { execFile } = require("child_process");

const PORT = Number(process.env.PORT || 3000);
const HOST = "127.0.0.1"; // loopback only: oauth2-proxy is the only way in
const KIROCREW_BIN = process.env.KIROCREW_BIN || "kirocrew";
const TOKEN_TTL = process.env.TOKEN_TTL || "8h";
const GOOGLE_CLIENT_ID = process.env.GOOGLE_CLIENT_ID || "";
const ALLOWLIST_FILE = process.env.ALLOWLIST_FILE || "";
const ALLOWED_DOMAINS = new Set(
  (process.env.ALLOWED_DOMAINS || "")
    .split(",")
    .map((domain) => domain.trim().toLowerCase())
    .filter(Boolean),
);

const GOOGLE_CERTS_URL = "https://www.googleapis.com/oauth2/v3/certs";
const GOOGLE_ISSUERS = new Set(["accounts.google.com", "https://accounts.google.com"]);
const CLOCK_SKEW_SECS = 60;
const MIN_CERT_REFETCH_MS = 60 * 1000;

if (!GOOGLE_CLIENT_ID || !ALLOWLIST_FILE) {
  console.error("kc-auth: GOOGLE_CLIENT_ID and ALLOWLIST_FILE must be set");
  process.exit(1);
}
if (ALLOWED_DOMAINS.has("*")) {
  console.error("kc-auth: ALLOWED_DOMAINS must not contain *");
  process.exit(1);
}

function generateToken() {
  return new Promise((resolve, reject) => {
    execFile(KIROCREW_BIN, ["token", "--ttl", TOKEN_TTL], { timeout: 15000 }, (err, stdout, stderr) => {
      if (err) return reject(err);
      const match = `${stdout}\n${stderr}`.match(/[?&]token=([^\s&]+)/);
      match ? resolve(match[1]) : reject(new Error("No token in kirocrew output"));
    });
  });
}

// --- Google signing keys, cached for the max-age Google sends -------------
let certs = { keys: new Map(), expiresAt: 0, fetchedAt: 0 };

async function fetchCerts() {
  const res = await fetch(GOOGLE_CERTS_URL);
  if (!res.ok) throw new Error(`Google certs HTTP ${res.status}`);
  const body = await res.json();
  const maxAge = Number((res.headers.get("cache-control") || "").match(/max-age=(\d+)/)?.[1] || 3600);
  const keys = new Map();
  for (const jwk of body.keys || []) {
    if (jwk.kid && jwk.kty === "RSA") keys.set(jwk.kid, crypto.createPublicKey({ key: jwk, format: "jwk" }));
  }
  const now = Date.now();
  certs = { keys, expiresAt: now + maxAge * 1000, fetchedAt: now };
}

async function signingKey(kid) {
  const now = Date.now();
  if (now >= certs.expiresAt) await fetchCerts();
  // Google rotates keys; refetch once for an unknown kid, but not in a tight loop.
  if (!certs.keys.has(kid) && now - certs.fetchedAt >= MIN_CERT_REFETCH_MS) await fetchCerts();
  return certs.keys.get(kid);
}

// --- allowlist, re-read when the file changes ------------------------------
let allowlist = { mtimeMs: -1, emails: new Set() };

function allowedEmails() {
  const { mtimeMs } = fs.statSync(ALLOWLIST_FILE);
  if (mtimeMs !== allowlist.mtimeMs) {
    const emails = fs.readFileSync(ALLOWLIST_FILE, "utf8")
      .split("\n")
      .map((line) => line.trim().toLowerCase())
      .filter((line) => line && !line.startsWith("#"));
    allowlist = { mtimeMs, emails: new Set(emails) };
  }
  return allowlist.emails;
}

function isAllowed(email) {
  if (allowedEmails().has(email)) return true;
  const at = email.lastIndexOf("@");
  return at > 0 && ALLOWED_DOMAINS.has(email.slice(at + 1));
}

// --- ID token verification -------------------------------------------------
class AuthError extends Error {}

function decodeSegment(segment) {
  return JSON.parse(Buffer.from(segment, "base64url").toString("utf8"));
}

async function verifyGoogleIdToken(authorization) {
  const match = /^Bearer\s+([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)$/.exec(authorization || "");
  if (!match) throw new AuthError("no Google ID token in Authorization header");
  const [, rawHeader, rawPayload, rawSignature] = match;

  let header, payload;
  try {
    header = decodeSegment(rawHeader);
    payload = decodeSegment(rawPayload);
  } catch {
    throw new AuthError("malformed ID token");
  }
  if (header.alg !== "RS256" || !header.kid) throw new AuthError(`unsupported ID token alg ${header.alg}`);

  const key = await signingKey(header.kid);
  if (!key) throw new AuthError("ID token signed with an unknown key");
  const signed = crypto.verify(
    "RSA-SHA256",
    Buffer.from(`${rawHeader}.${rawPayload}`),
    key,
    Buffer.from(rawSignature, "base64url"),
  );
  if (!signed) throw new AuthError("bad ID token signature");

  const now = Math.floor(Date.now() / 1000);
  const audiences = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
  if (!GOOGLE_ISSUERS.has(payload.iss)) throw new AuthError(`wrong issuer ${payload.iss}`);
  if (!audiences.includes(GOOGLE_CLIENT_ID)) throw new AuthError("ID token issued for another client");
  if (typeof payload.exp !== "number" || payload.exp + CLOCK_SKEW_SECS < now) throw new AuthError("ID token expired");
  if (typeof payload.iat === "number" && payload.iat - CLOCK_SKEW_SECS > now) throw new AuthError("ID token issued in the future");
  if (payload.email_verified !== true || typeof payload.email !== "string") throw new AuthError("email not verified");

  const email = payload.email.toLowerCase();
  if (!isAllowed(email)) throw new AuthError(`${email} is not on the allowlist`);
  return email;
}

function sendJson(res, status, body) {
  res.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store" });
  res.end(JSON.stringify(body));
}

const server = http.createServer(async (req, res) => {
  const { pathname } = new URL(req.url, "http://localhost");

  if (req.method === "GET" && pathname === "/kc-auth/health") {
    return sendJson(res, 200, { ok: true });
  }

  if (req.method === "GET" && pathname === "/kc-auth/token") {
    let email;
    try {
      email = await verifyGoogleIdToken(req.headers["authorization"]);
      const forwarded = String(req.headers["x-forwarded-email"] || "").toLowerCase();
      if (forwarded && forwarded !== email) throw new AuthError("X-Forwarded-Email does not match the ID token");
    } catch (e) {
      if (e instanceof AuthError) {
        console.warn(`Token refused: ${e.message}`);
        return sendJson(res, 401, { error: "Not authenticated" });
      }
      console.error("Token check failed:", e.message);
      return sendJson(res, 503, { error: "Could not verify login" });
    }
    try {
      const token = await generateToken();
      console.log(`Token issued for ${email}`);
      return sendJson(res, 200, { token, email, expiresIn: TOKEN_TTL });
    } catch (e) {
      console.error("Token generation failed:", e.message);
      return sendJson(res, 500, { error: "Could not generate token" });
    }
  }

  sendJson(res, 404, { error: "Not found" });
});

server.listen(PORT, HOST, () => console.log(`kc-auth listening on http://${HOST}:${PORT}`));
