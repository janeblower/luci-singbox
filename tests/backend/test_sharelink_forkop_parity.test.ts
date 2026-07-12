import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode, runUcodeJSON } from "../helpers/ucode.ts";

// Regression suite for the forkop share-link parity work (spec §1, S1-S15).
// Every case below is a link shape real providers ship that our parser either
// rejected outright or silently stripped a parameter from.

function parse<T = Record<string, unknown>>(url: string): Promise<T> {
  return runUcodeJSON<T>(
    `let r = require("sharelink").parse_proxy_url(${JSON.stringify(url)});
     print(sprintf("%J", r));`,
  );
}

// biome-ignore lint/suspicious/noExplicitAny: parsed sing-box outbounds are free-form JSON
type Ob = any;

describe("sharelink forkop parity", () => {
  useGuest();

  // S1 — TLS with no security= param. Providers routinely omit it; without the
  // inference the outbound connected in plaintext to a TLS server.
  it("S1 auto-TLS: sni alone enables TLS", async () => {
    const o: Ob = await parse(
      "vless://11111111-1111-1111-1111-111111111111@h.ex:443?sni=a.com&type=ws",
    );
    expect(o.tls.enabled).toBe(true);
    expect(o.tls.server_name).toBe("a.com");
  });
  it("S1 auto-TLS: pbk alone enables TLS+reality+chrome fp", async () => {
    const o: Ob = await parse(
      "vless://11111111-1111-1111-1111-111111111111@h.ex:443?pbk=PK&sid=ab",
    );
    expect(o.tls.reality.public_key).toBe("PK");
    expect(o.tls.utls.fingerprint).toBe("chrome");
  });
  it("S1 auto-TLS: a bare link stays plaintext", async () => {
    const o: Ob = await parse(
      "vless://11111111-1111-1111-1111-111111111111@h.ex:443?type=tcp",
    );
    expect(o.tls).toBeUndefined();
  });

  // S2 — trailing slash before the query. The whole link used to be rejected.
  it("S2 trailing slash before the query parses", async () => {
    const o: Ob = await parse(
      "vless://11111111-1111-1111-1111-111111111111@h.ex:443/?type=ws&security=tls&host=x.com",
    );
    expect(o.server).toBe("h.ex");
    expect(o.transport.headers.Host).toBe("x.com");
  });
  it("S2 trailing slash: trojan/hy2/tuic too", async () => {
    for (const url of [
      "trojan://pw@h.ex:443/?sni=s.com",
      "hy2://pw@h.ex:443/?sni=s.com",
      "tuic://11111111-1111-1111-1111-111111111111:pw@h.ex:443/?sni=s.com",
    ]) {
      const o: Ob = await parse(url);
      expect(o.tls.server_name).toBe("s.com");
    }
  });

  // S3 — an unknown utls fingerprint is a FATAL sing-box config error.
  it("S3 unknown fp normalises to chrome (vless + trojan)", async () => {
    const v: Ob = await parse(
      "vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=tls&fp=bogus&sni=a.com",
    );
    expect(v.tls.utls.fingerprint).toBe("chrome");
    const t: Ob = await parse("trojan://pw@h.ex:443?sni=s.com&fp=quantum");
    expect(t.tls.utls.fingerprint).toBe("chrome");
  });
  it("S3 known fp is kept; reality without fp forces chrome", async () => {
    const v: Ob = await parse(
      "vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=tls&fp=firefox&sni=a.com",
    );
    expect(v.tls.utls.fingerprint).toBe("firefox");
    const r: Ob = await parse(
      "vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=reality&pbk=PK",
    );
    expect(r.tls.utls.fingerprint).toBe("chrome");
  });

  // S4/S5 — field aliases (peer==sni, insecure==allowInsecure) and the wider
  // truthiness every provider assumes (yes/on).
  it("S4/S5 vless peer alias + insecure=yes", async () => {
    const o: Ob = await parse(
      "vless://11111111-1111-1111-1111-111111111111@h.ex:443?peer=p.com&insecure=yes",
    );
    expect(o.tls.server_name).toBe("p.com");
    expect(o.tls.insecure).toBe(true);
  });
  it("S4/S5 hysteria2 allowInsecure=on", async () => {
    const o: Ob = await parse("hy2://pw@h.ex:443?sni=s.com&allowInsecure=on");
    expect(o.tls.insecure).toBe(true);
  });
  it("S5 trojan allowInsecure=true still works (no regression)", async () => {
    const o: Ob = await parse("trojan://pw@h.ex:443?allowInsecure=true");
    expect(o.tls.insecure).toBe(true);
  });

  // S6 — ws path default and the http/h2 host CSV list.
  it("S6 ws path defaults to /", async () => {
    const o: Ob = await parse(
      "vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=tls&type=ws",
    );
    expect(o.transport.path).toBe("/");
  });
  it("S6 http host is a CSV list", async () => {
    const o: Ob = await parse(
      "vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=tls&type=http&host=a.com,b.com",
    );
    expect(o.transport.host).toEqual(["a.com", "b.com"]);
  });

  // S7 — xhttp transport: nothing of it existed before.
  it("S7 xhttp defaults", async () => {
    const o: Ob = await parse(
      "vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=tls&type=xhttp&sni=s.com",
    );
    expect(o.transport).toEqual({
      type: "xhttp",
      mode: "auto",
      path: "/",
      x_padding_bytes: "100-1000",
      no_grpc_header: false,
      sc_max_each_post_bytes: 1000000,
      sc_min_posts_interval_ms: 30,
      host: "s.com", // host falls back to sni
    });
  });
  it("S7 xhttp query knobs (camel) + xmux ranges", async () => {
    const xmux = encodeURIComponent(
      JSON.stringify({ maxConcurrency: "8-16", hKeepAlivePeriod: 45 }),
    );
    const o: Ob = await parse(
      `vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=tls&type=xhttp&sni=s.com&mode=stream-up&xPaddingBytes=200-300&scMinPostsIntervalMs=10&xmux=${xmux}`,
    );
    expect(o.transport.mode).toBe("stream-up");
    expect(o.transport.x_padding_bytes).toBe("200-300");
    expect(o.transport.sc_min_posts_interval_ms).toBe(10);
    expect(o.transport.xmux).toEqual({
      max_concurrency: "8-16",
      h_keep_alive_period: 45,
    });
  });
  it("S7 xhttp settings nested in ?extra= JSON", async () => {
    const extra = encodeURIComponent(
      JSON.stringify({
        downloadSettings: {
          xhttpSettings: {
            extra: { noGRPCHeader: true, scMaxEachPostBytes: 500000 },
          },
        },
      }),
    );
    const o: Ob = await parse(
      `vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=tls&type=xhttp&sni=s.com&extra=${extra}`,
    );
    expect(o.transport.no_grpc_header).toBe(true);
    expect(o.transport.sc_max_each_post_bytes).toBe(500000);
  });
  it("S7 xhttp mode is whitelisted (junk -> auto)", async () => {
    const o: Ob = await parse(
      "vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=tls&type=xhttp&sni=s.com&mode=gun",
    );
    expect(o.transport.mode).toBe("auto");
  });

  // S8 — hysteria2 port hopping.
  it("S8 hop range in the port position -> server_ports", async () => {
    const o: Ob = await parse("hy2://pw@h.ex:1000-2000?sni=s.com");
    expect(o.server_ports).toEqual(["1000:2000"]);
    expect(o.server_port).toBeUndefined();
  });
  it("S8 mport list -> server_ports", async () => {
    const o: Ob = await parse(
      "hy2://pw@h.ex:443?mport=1000-2000,443&sni=s.com",
    );
    expect(o.server_ports).toEqual(["1000:2000", "443:443"]);
    expect(o.server_port).toBeUndefined();
  });
  it("S8 a plain port still emits server_port", async () => {
    const o: Ob = await parse("hy2://pw@h.ex:443?sni=s.com");
    expect(o.server_port).toBe(443);
    expect(o.server_ports).toBeUndefined();
  });

  // S9 — hysteria2 bandwidth + network.
  it("S9 hysteria2 upmbps/downmbps/network", async () => {
    const o: Ob = await parse(
      "hy2://pw@h.ex:443?sni=s.com&upmbps=50&downmbps=200&network=tcp",
    );
    expect(o.up_mbps).toBe(50);
    expect(o.down_mbps).toBe(200);
    expect(o.network).toBe("tcp");
  });

  // S10 — ALPN depends on the transport.
  it("S10 ws + alpn -> http/1.1 only", async () => {
    const o: Ob = await parse(
      "vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=tls&type=ws&alpn=h2,http/1.1&sni=s.com",
    );
    expect(o.tls.alpn).toEqual(["http/1.1"]);
  });
  it("S10 xhttp without alpn -> h2 + http/1.1", async () => {
    const o: Ob = await parse(
      "vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=tls&type=xhttp&sni=s.com",
    );
    expect(o.tls.alpn).toEqual(["h2", "http/1.1"]);
  });

  // S11 — vless packet_encoding / encryption / flow whitelist.
  it("S11 packetEncoding -> packet_encoding (whitelisted)", async () => {
    const ok: Ob = await parse(
      "vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=tls&packetEncoding=xudp&sni=s.com",
    );
    expect(ok.packet_encoding).toBe("xudp");
    const junk: Ob = await parse(
      "vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=tls&packetEncoding=bogus&sni=s.com",
    );
    expect(junk.packet_encoding).toBeUndefined();
  });
  it("S11 encryption passes through, none is dropped", async () => {
    const o: Ob = await parse(
      "vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=tls&encryption=mlkem768x25519plus&sni=s.com",
    );
    expect(o.encryption).toBe("mlkem768x25519plus");
    const n: Ob = await parse(
      "vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=tls&encryption=none&sni=s.com",
    );
    expect(n.encryption).toBeUndefined();
  });
  it("S11 an unknown flow rejects the link", async () => {
    const r = await runUcode(
      `let r = require("sharelink").parse_proxy_url("vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=tls&flow=xtls-rprx-direct&sni=s.com");
       print(r == null ? "REJECT" : "ACCEPT");`,
    );
    expect(r.stdout.trim()).toBe("REJECT");
  });

  // S12 — ws early data.
  it("S12 ws ed -> max_early_data", async () => {
    const o: Ob = await parse(
      "vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=tls&type=ws&ed=2048&sni=s.com",
    );
    expect(o.transport.max_early_data).toBe(2048);
  });

  // S13 — SIP002 ?plugin-opts= as its own param.
  it("S13 ss plugin-opts query param", async () => {
    const o: Ob = await parse(
      "ss://aes-128-gcm:pw@h.ex:8388?plugin=obfs-local&plugin-opts=obfs%3Dhttp%3Bobfs-host%3Dbing.com#n",
    );
    expect(o.plugin).toBe("obfs-local");
    expect(o.plugin_opts).toBe("obfs=http;obfs-host=bing.com");
  });
  it("S13 legacy plugin=name;opts still splits", async () => {
    const o: Ob = await parse(
      "ss://aes-128-gcm:pw@h.ex:8388?plugin=obfs-local%3Bobfs%3Dhttp#n",
    );
    expect(o.plugin).toBe("obfs-local");
    expect(o.plugin_opts).toBe("obfs=http");
  });

  // S14 — socks4 / socks4a.
  it("S14 socks4a version from the scheme; user==pass drops the password", async () => {
    const o: Ob = await parse("socks4a://user:user@h.ex:1080#n");
    expect(o.version).toBe("4a");
    expect(o.username).toBe("user");
    expect(o.password).toBeUndefined();
  });
  it("S14 socks4 version; socks5 unchanged", async () => {
    expect(((await parse("socks4://h.ex:1080")) as Ob).version).toBe("4");
    expect(((await parse("socks5://bob:pw@h.ex:1080")) as Ob).version).toBe(
      "5",
    );
  });

  // S15 — a node name containing an escaped '#' ("Server#2").
  it("S15 %23 in the fragment survives the percent-decode", async () => {
    const url =
      "vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=tls&sni=s.com#Server%232";
    const r = await runUcode(
      `let s = require("sharelink");
       let l = s.parse_proxy_link(${JSON.stringify(url)});
       print(sprintf("%s|%s", l.display_name, l.outbound.server));`,
    );
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("Server#2|h.ex");
  });

  // DELIBERATE DIVERGENCE from forkop: it rejects a reality link with no pbk;
  // we degrade to plain TLS (the reality block would be FATAL without a
  // public_key, but the rest of the link is usable). Pinned so the choice is
  // explicit rather than accidental.
  it("reality without pbk degrades to plain TLS (we are softer than forkop)", async () => {
    const o: Ob = await parse(
      "vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=reality&sid=ab#n",
    );
    expect(o.tls.enabled).toBe(true);
    expect(o.tls.reality).toBeUndefined();
  });

  // Guard the schemes forkop does not have at all.
  it("tuic / anytls / hysteria(v1) still parse", async () => {
    expect(
      (
        (await parse(
          "tuic://11111111-1111-1111-1111-111111111111:pw@h.ex:443?congestion_control=bbr",
        )) as Ob
      ).congestion_control,
    ).toBe("bbr");
    expect(((await parse("anytls://pw@h.ex:443")) as Ob).password).toBe("pw");
    expect(
      ((await parse("hysteria://h.ex:443?auth=tok&upmbps=50")) as Ob).auth_str,
    ).toBe("tok");
  });
});
