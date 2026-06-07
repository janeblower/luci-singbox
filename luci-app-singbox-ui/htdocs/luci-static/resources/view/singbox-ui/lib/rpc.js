'use strict';
'require rpc';

return L.Class.extend({
    callRefresh:    rpc.declare({ object: 'singbox-ui', method: 'refresh',     params: [ 'what' ] }),
    callRestart:    rpc.declare({ object: 'singbox-ui', method: 'restart' }),
    callStatus:     rpc.declare({ object: 'singbox-ui', method: 'status' }),
    callReadConfig: rpc.declare({ object: 'singbox-ui', method: 'read_config',
                                  params: [ 'token' ] }),
    callClashGet:    rpc.declare({ object: 'singbox-ui', method: 'clash_get',
                                   params: [ 'path' ] }),
    callClashMutate: rpc.declare({ object: 'singbox-ui', method: 'clash_mutate',
                                   params: [ 'method', 'path', 'body' ] }),
    callExportSection: rpc.declare({ object: 'singbox-ui', method: 'export_section',
                                     params: [ 'kind', 'name', 'token' ] }),
    callPreviewConfig: rpc.declare({ object: 'singbox-ui', method: 'preview_config',
                                     params: [ 'token' ] }),
    callDhcpLeases: rpc.declare({ object: 'luci-rpc',   method: 'getDHCPLeases',
                                  expect: { '': {} } }),

    // ── Reveal-token helpers ─────────────────────────────────────────────────
    // SECURITY: reveal token MUST live only in window memory.
    // Do NOT serialize to localStorage / sessionStorage / cookies.
    // See docs/secret-reveal.md threat model.

    revealGrant: rpc.declare({
        object: 'singbox-ui',
        method: 'reveal_token_grant',
    }),

    revealRevoke: rpc.declare({
        object: 'singbox-ui',
        method: 'reveal_token_revoke',
    }),

    // withRevealToken(args) — augment args with the active reveal token, if any.
    // Token is router-global; checks expiry against client clock as a UX
    // convenience (server is the actual authority).
    withRevealToken: function(args) {
        var t = window.singboxUiRevealToken;
        if (!t) return args || {};
        if (Math.floor(Date.now() / 1000) >= t.expires_ts) {
            window.singboxUiRevealToken = null;
            return args || {};
        }
        return Object.assign({}, args || {}, { token: t.token });
    },
});
