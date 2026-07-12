import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

// Phase 3 (F1-F5): subscription BODY formats. Everything goes through the
// production entry point (`subscription.uc fetch-subs`), not a bare
// `ucode -L lib` probe of the parser — the formats only matter if a real fetch
// turns them into sub_<name>.txt nodes.

const LIB = "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const SUB_UC = "/tmp/work/singbox-ui/root/usr/share/singbox-ui/subscription.uc";

let counter = 0;
function tmpDir(): string {
  return `/tmp/sbfmt-${Date.now()}-${counter++}`;
}

// curl stub: copies FAKE_BODY_FILE to -o, writes a minimal header dump to -D.
const CURL_STUB = `#!/bin/sh
out=""; hdr=""; prev=""
for a in "$@"; do
  case "$prev" in -o) out="$a" ;; -D) hdr="$a" ;; esac
  prev="$a"
done
[ -n "$hdr" ] && printf 'HTTP/1.1 200 OK\\r\\nserver: stub\\r\\n\\r\\n' >"$hdr"
[ -n "$out" ] && cat "\${FAKE_BODY_FILE:-/dev/null}" >"$out"
exit 0
`;

// Fetch one subscription whose body is `body`, return the node lines + stat.
async function fetchBody(
  body: string,
  opts: { b64?: boolean; gzip?: boolean } = {},
): Promise<{ lines: string[]; stat: Record<string, unknown> }> {
  const dir = tmpDir();
  await exec(`mkdir -p ${dir}/bin ${dir}/rt ${dir}/cache ${dir}/uci`);
  await putFile(CURL_STUB, `${dir}/bin/curl`);
  await exec(`chmod +x ${dir}/bin/curl`);
  // base64 is done host-side (the OpenWrt guest has no base64 applet); gzip has
  // to be done in the guest because putFile ships text, not bytes.
  if (opts.gzip) {
    await putFile(body, `${dir}/body.raw`);
    await exec(`gzip -c <${dir}/body.raw >${dir}/body`);
  } else {
    await putFile(
      opts.b64 ? Buffer.from(body, "utf8").toString("base64") : body,
      `${dir}/body`,
    );
  }
  await putFile(
    `config outbound 'sub1'\n\toption type 'subscription'\n\toption sub_url 'https://example.test/sub'\n`,
    `${dir}/uci/singbox-ui`,
  );
  await exec(
    `cd /tmp/work && env UCI_CONFIG_DIR=${dir}/uci SINGBOX_TMPDIR=${dir}/rt ` +
      `SINGBOX_SUB_CACHE=${dir}/cache CURL=${dir}/bin/curl FAKE_BODY_FILE=${dir}/body ` +
      `SINGBOX_RETRY_SLEEP=0 ucode -L ${LIB} ${SUB_UC} fetch-subs 2>/dev/null`,
  );
  const txt = await exec(`cat ${dir}/rt/sub_sub1.txt 2>/dev/null || true`);
  const stat = await exec(
    `cat ${dir}/rt/sub_sub1.stat 2>/dev/null || echo '{}'`,
  );
  await exec(`rm -rf ${dir}`);
  return {
    lines: txt.stdout.split("\n").filter((l) => l.trim() !== ""),
    stat: JSON.parse(stat.stdout.trim() || "{}"),
  };
}

const CLASH_YAML = `port: 7890
mode: rule
proxies:
  - name: "🇺🇸 US-1"
    type: vmess
    server: a.example.com
    port: 443
    uuid: 11111111-1111-1111-1111-111111111111
    alterId: 4
    cipher: auto
    tls: true
    servername: a.example.com
    skip-cert-verify: true
    packet-encoding: packetaddr
    network: ws
    ws-opts:
      path: /ray
      headers:
        Host: cdn.example.com
  - {name: SS-1, type: ss, server: b.example.com, port: 8388, cipher: aes-128-gcm, password: "p@ss"}
  - name: R1
    type: vless
    server: c.example.com
    port: 443
    uuid: 22222222-2222-2222-2222-222222222222
    flow: xtls-rprx-vision
    client-fingerprint: chrome
    reality-opts:
      public-key: PUBKEY
      short-id: ab12
  - name: H2
    type: hysteria2
    server: d.example.com
    port: 8443
    password: hpass
    obfs: salamander
    obfs-password: obfspw
    up: 50
    down: 200
  - name: G1
    type: trojan
    server: e.example.com
    port: 443
    password: tpass
    network: grpc
    alpn: [h2, http/1.1]
    grpc-opts:
      grpc-service-name: tunnel
  - name: S5
    type: socks5
    server: f.example.com
    port: 1080
    username: u
    password: p
  - name: BROKEN
    type: ssr
    server: g.example.com
    port: 1
proxy-groups:
  - name: PROXY
    type: select
`;

describe("test_subformat", () => {
  useGuest();

  it("F1: Clash YAML proxies become sing-box nodes (ws/reality/grpc/hy2/socks)", async () => {
    const { lines, stat } = await fetchBody(CLASH_YAML);
    expect(stat.format).toBe("clash");
    // 7 proxies, one (ssr) is not representable
    expect(lines.length).toBe(6);
    expect(stat.skipped).toBe(1);

    const nodes = lines.map((l) => JSON.parse(l));
    const byName: Record<string, any> = {};
    for (const n of nodes) byName[n.n] = n.o;

    const vmess = byName["🇺🇸 US-1"];
    expect(vmess.type).toBe("vmess");
    expect(vmess.alter_id).toBe(4);
    expect(vmess.packet_encoding).toBe("packetaddr");
    expect(vmess.transport).toEqual({
      type: "ws",
      path: "/ray",
      headers: { Host: "cdn.example.com" },
    });
    expect(vmess.tls.server_name).toBe("a.example.com");
    expect(vmess.tls.insecure).toBe(true);

    expect(byName["SS-1"]).toMatchObject({
      type: "shadowsocks",
      method: "aes-128-gcm",
      password: "p@ss",
      server_port: 8388,
    });

    const vless = byName.R1;
    expect(vless.type).toBe("vless");
    expect(vless.flow).toBe("xtls-rprx-vision");
    expect(vless.tls.reality).toEqual({
      enabled: true,
      public_key: "PUBKEY",
      short_id: "ab12",
    });
    expect(vless.tls.utls.fingerprint).toBe("chrome");

    const hy2 = byName.H2;
    expect(hy2.type).toBe("hysteria2");
    expect(hy2.obfs).toEqual({ type: "salamander", password: "obfspw" });
    expect(hy2.up_mbps).toBe(50);
    expect(hy2.down_mbps).toBe(200);

    const grpc = byName.G1;
    expect(grpc.transport).toEqual({ type: "grpc", service_name: "tunnel" });
    expect(grpc.tls.alpn).toEqual(["h2", "http/1.1"]);

    expect(byName.S5).toMatchObject({
      type: "socks",
      version: "5",
      username: "u",
    });
  });

  it("F2: sing-box JSON — {outbounds:[…]}, bare array and a single outbound", async () => {
    const wrapped = await fetchBody(
      JSON.stringify({
        outbounds: [
          {
            type: "trojan",
            tag: "T1",
            server: "h.example.com",
            server_port: 443,
            password: "p",
          },
          { type: "selector", tag: "sel", outbounds: ["T1"] },
        ],
      }),
    );
    expect(wrapped.stat.format).toBe("singbox");
    expect(wrapped.lines.length).toBe(1);
    // a subscription may not ship local policy (selector/direct/block) — skipped
    expect(wrapped.stat.skipped).toBe(1);
    const n = JSON.parse(wrapped.lines[0]);
    expect(n.n).toBe("T1");
    expect(n.o.tag).toBeUndefined();
    expect(n.o.type).toBe("trojan");

    const bare = await fetchBody(
      JSON.stringify([
        {
          type: "vless",
          tag: "V",
          server: "v.example.com",
          server_port: 443,
          uuid: "u",
        },
      ]),
    );
    expect(bare.lines.length).toBe(1);

    const single = await fetchBody(
      JSON.stringify({
        type: "hysteria2",
        tag: "S",
        server: "s.example.com",
        server_port: 443,
        password: "p",
      }),
    );
    expect(single.lines.length).toBe(1);
    expect(JSON.parse(single.lines[0]).o.type).toBe("hysteria2");
  });

  it("F6: an Xray config JSON is translated to sing-box outbounds", async () => {
    const { lines, stat } = await fetchBody(
      JSON.stringify({
        outbounds: [
          // every Xray config ships these; they are local policy, not nodes,
          // and must not inflate `skipped`
          { protocol: "freedom", tag: "direct" },
          { protocol: "blackhole", tag: "block" },
          {
            protocol: "vless",
            tag: "R1",
            settings: {
              vnext: [
                {
                  address: "r.example.com",
                  port: 443,
                  users: [
                    {
                      id: "uuid-1",
                      flow: "xtls-rprx-vision",
                      encryption: "none",
                    },
                  ],
                },
              ],
            },
            streamSettings: {
              network: "tcp",
              security: "reality",
              realitySettings: {
                serverName: "www.example.org",
                publicKey: "PUBKEY",
                shortId: "ab12",
                fingerprint: "chrome",
              },
            },
          },
          {
            protocol: "vmess",
            tag: "W1",
            settings: {
              vnext: [
                {
                  address: "w.example.com",
                  port: 80,
                  users: [{ id: "uuid-2", alterId: 0, security: "auto" }],
                },
              ],
            },
            streamSettings: {
              network: "ws",
              wsSettings: {
                path: "/ray",
                headers: { Host: "cdn.example.com" },
              },
            },
          },
          {
            protocol: "shadowsocks",
            tag: "S1",
            settings: {
              servers: [
                {
                  address: "s.example.com",
                  port: 8388,
                  method: "aes-128-gcm",
                  password: "p@ss",
                },
              ],
            },
          },
          // kcp has no sing-box equivalent: skip the node rather than ship an
          // outbound that would silently talk plain TCP
          {
            protocol: "vless",
            tag: "KCP",
            settings: {
              vnext: [
                {
                  address: "k.example.com",
                  port: 1,
                  users: [{ id: "uuid-3" }],
                },
              ],
            },
            streamSettings: { network: "kcp" },
          },
        ],
      }),
    );
    expect(stat.format).toBe("xray");
    expect(stat.skipped).toBe(1); // the kcp node only
    expect(lines.length).toBe(3);

    const byName: Record<string, any> = {};
    for (const l of lines) {
      const n = JSON.parse(l);
      byName[n.n] = n.o;
    }
    expect(byName.R1).toMatchObject({
      type: "vless",
      server: "r.example.com",
      server_port: 443,
      uuid: "uuid-1",
      flow: "xtls-rprx-vision",
      tls: {
        enabled: true,
        server_name: "www.example.org",
        utls: { enabled: true, fingerprint: "chrome" },
        reality: { enabled: true, public_key: "PUBKEY", short_id: "ab12" },
      },
    });
    expect(byName.W1).toMatchObject({
      type: "vmess",
      uuid: "uuid-2",
      alter_id: 0,
      security: "auto",
      transport: {
        type: "ws",
        path: "/ray",
        headers: { Host: "cdn.example.com" },
      },
    });
    expect(byName.S1).toMatchObject({
      type: "shadowsocks",
      method: "aes-128-gcm",
      password: "p@ss",
    });
  });

  it("F3: a gzip-compressed body is transparently decompressed", async () => {
    const { lines, stat } = await fetchBody(
      "trojan://pw@t.example.com:443#T\nvless://uuid@v.example.com:443?security=tls#V\n",
      { gzip: true },
    );
    expect(stat.format).toBe("uri");
    expect(lines.length).toBe(2);
    expect(lines[0]).toMatch(/^trojan:\/\//);
  });

  it("F3+F1: gzip'd Clash YAML (both layers at once)", async () => {
    const { lines, stat } = await fetchBody(CLASH_YAML, { gzip: true });
    expect(stat.format).toBe("clash");
    expect(lines.length).toBe(6);
  });

  it("F4: base64 wrapping a base64 URI list is unwrapped (depth 1)", async () => {
    const inner = Buffer.from("trojan://pw@t.example.com:443#T\n").toString(
      "base64",
    );
    const { lines, stat } = await fetchBody(inner, { b64: true });
    expect(stat.format).toBe("uri");
    expect(lines.length).toBe(1);
    expect(lines[0]).toMatch(/^trojan:\/\//);
  });

  it("F4: base64-wrapped Clash YAML decodes to nodes", async () => {
    const { lines, stat } = await fetchBody(CLASH_YAML, { b64: true });
    expect(stat.format).toBe("clash");
    expect(lines.length).toBe(6);
  });

  it("F5: skipped counts the links we could not parse", async () => {
    const { lines, stat } = await fetchBody(
      [
        "trojan://pw@t.example.com:443#ok",
        "wireguard://nope@x:1", // unsupported scheme
        "vless://@:0", // malformed
        "ss://aes-128-gcm:pw@s.example.com:8388#ok2",
      ].join("\n"),
    );
    expect(lines.length).toBe(2);
    expect(stat.skipped).toBe(2);
  });

  it("hostile body: garbage YAML/JSON yields no nodes and does not abort the fetch", async () => {
    const res = await fetchBody("proxies:\n  - {{{{ broken\n  - name: x\n");
    expect(res.lines.length).toBe(0);
    // the run still completed (a .stat is only written on success — none here)
    const html = await fetchBody("<html><body>login required</body></html>");
    expect(html.lines.length).toBe(0);
  });
});
