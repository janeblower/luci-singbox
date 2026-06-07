// lib/reveal.uc — reveal-token grant/validate/revoke for secret unmasking.
// Token is router-global with 5-minute TTL, stored under /var/lib/singbox-ui/
// with mode 0600. See docs/secret-reveal.md for threat model.

let fs = require("fs");

const TTL_SEC = 300;
const PATH = getenv("REVEAL_TOKEN_PATH") || "/var/lib/singbox-ui/reveal_token.json";

let _clock_fn = function() { return time(); };
function _set_clock_for_test(fn) { _clock_fn = fn; }
function _now() { return _clock_fn(); }

function _read() {
    let h = fs.open(PATH, "r");
    if (!h) return null;
    let raw = h.read("all"); h.close();
    try { return json(raw); } catch (_) { return null; }
}

function _write(obj) {
    // mkdir -p of parent directory (mode 0700).
    let m = match(PATH, /^(.*)\/[^\/]+$/);
    if (m) {
        try { fs.mkdir(m[1], 0o700); } catch (_) {}
    }
    let h = fs.open(PATH, "w");
    if (!h) return false;
    h.write(sprintf("%J", obj));
    h.close();
    try { fs.chmod(PATH, 0o600); } catch (_) {}
    return true;
}

function _hex_random(n) {
    let h = fs.open("/dev/urandom", "r");
    if (!h) return null;
    let raw = h.read(n);
    h.close();
    let out = "";
    for (let i = 0; i < length(raw); i++)
        out += sprintf("%02x", ord(raw, i));
    return out;
}

function grant(issued_by) {
    let token = _hex_random(16);
    let entry = {
        token: token,
        issued_ts: _now(),
        issued_by: issued_by,
    };
    _write(entry);
    return { token: token, expires_ts: entry.issued_ts + TTL_SEC };
}

function validate(token) {
    if (!token || !length(token)) return false;
    let cur = _read();
    if (!cur) return false;
    if (cur.token !== token) return false;
    return (_now() - cur.issued_ts) < TTL_SEC;
}

function revoke() {
    try { fs.unlink(PATH); } catch (_) {}
}

return {
    grant, validate, revoke,
    TTL_SEC, _set_clock_for_test,
};
