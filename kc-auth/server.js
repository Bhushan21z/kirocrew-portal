// Kiro Crew token API. Runs behind oauth2-proxy, which handles Google login + allowlist.
//   GET /kc-auth/health -> {"ok": true}
//   GET /kc-auth/token  -> {"token": "...", "email": "...", "expiresIn": "8h"}
const http = require("http");
const { execFile } = require("child_process");

const PORT = Number(process.env.PORT || 3000);
const HOST = "127.0.0.1"; // loopback only: oauth2-proxy is the only way in
const KIROCREW_BIN = process.env.KIROCREW_BIN || "kirocrew";
const TOKEN_TTL = process.env.TOKEN_TTL || "8h";

function generateToken() {
  return new Promise((resolve, reject) => {
    execFile(KIROCREW_BIN, ["token", "--ttl", TOKEN_TTL], { timeout: 15000 }, (err, stdout, stderr) => {
      if (err) return reject(err);
      const match = `${stdout}\n${stderr}`.match(/[?&]token=([^\s&]+)/);
      match ? resolve(match[1]) : reject(new Error("No token in kirocrew output"));
    });
  });
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
    const email = req.headers["x-forwarded-email"];
    if (!email) return sendJson(res, 401, { error: "Not authenticated" });
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
