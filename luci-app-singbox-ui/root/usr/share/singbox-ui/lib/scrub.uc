// Secret-masking helper. See docs/superpowers/specs/phase-c1.md C1.1.
// Pure function: returns a new object; original is unchanged.

// readonly — do not mutate
const SECRET_KEYS = [
    "uuid",
    "password",
    "private_key",
    "public_key",     // reality public_key (spec C1.1)
    "short_id",       // reality short_id — sensitive (spec C1.1)
    "key_pem",
    "cert_pem",       // inline cert content (spec C1.1) — NOT *_path
    "secret",         // clash_api.secret
    "auth_str",       // hysteria2 obfs auth
    "proxy_url",      // share-link export contains creds
    "sub_url",        // subscription URL contains user-id
];

// Recursively replaces values whose KEY is in SECRET_KEYS with "***".
// Walks objects and arrays. Primitives are returned as-is.
function scrub_secrets(value) {
    if (type(value) == "array") {
        let out = [];
        for (let item in value)
            push(out, scrub_secrets(item));
        return out;
    }
    if (type(value) == "object") {
        let out = {};
        for (let k in value) {
            if (index(SECRET_KEYS, k) >= 0 && value[k] !== null && value[k] !== "")
                out[k] = "***";
            else
                out[k] = scrub_secrets(value[k]);
        }
        return out;
    }
    return value;
}

return { SECRET_KEYS, scrub_secrets };
