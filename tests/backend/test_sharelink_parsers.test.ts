import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Helper: build a vmess:// URL from a JSON object (base64-encoded)
function vmessUrl(obj: Record<string, string>): string {
  return `vmess://${Buffer.from(JSON.stringify(obj)).toString("base64")}`;
}

// Helper: base64-encode a string (mimics `printf '%s' ... | base64 -w0`)
function b64(s: string): string {
  return Buffer.from(s).toString("base64");
}

describe("test_sharelink_parsers", () => {
  useGuest();

  // 9.4: vmess:// (v2rayN base64 JSON) -> sing-box vmess outbound
  it("9.4 vmess:// parsed (ws+tls), ps -> tag", async () => {
    const url = vmessUrl({
      v: "2",
      ps: "node1",
      add: "e.com",
      port: "443",
      id: "11111111-1111-1111-1111-111111111111",
      aid: "0",
      net: "ws",
      path: "/p",
      host: "h.com",
      tls: "tls",
      sni: "s.com",
    });
    const src = `
let r = require("sharelink").parse_proxy_url(${JSON.stringify(url)});
print(sprintf("%s|%s|%d|%s|%s|%s|%s|%s", r.type, r.server, r.server_port, r.uuid, r.transport.type, r.transport.path, r.tls.server_name, r.tag));
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe(
      "vmess|e.com|443|11111111-1111-1111-1111-111111111111|ws|/p|s.com|node1",
    );
  });

  // 9.4: malformed vmess base64 -> null (no crash)
  it("9.4 malformed vmess dropped (returns null)", async () => {
    const src = `
let r = require("sharelink").parse_proxy_url("vmess://!!!notbase64");
print(r==null?"NULL":"LEAK");
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("NULL");
  });

  // 9.3: ss SIP002 ?plugin=name;opts -> plugin + plugin_opts
  it("9.3 ss SIP002 plugin/plugin_opts extracted", async () => {
    const ssUser = b64("aes-256-gcm:pass");
    const url = `ss://${ssUser}@1.2.3.4:8388?plugin=obfs-local;obfs=http;obfs-host=x.com#n`;
    const src = `
let r = require("sharelink").parse_proxy_url(${JSON.stringify(url)});
print(sprintf("%s|%s|%s", r.method, r.plugin, r.plugin_opts));
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe(
      "aes-256-gcm|obfs-local|obfs=http;obfs-host=x.com",
    );
  });

  // 9.3: ss without a plugin must NOT emit plugin keys
  it("9.3 ss without plugin emits no plugin keys", async () => {
    const ssUser = b64("aes-256-gcm:pass");
    const url = `ss://${ssUser}@1.2.3.4:8388#n`;
    const src = `
let r = require("sharelink").parse_proxy_url(${JSON.stringify(url)});
print(r.plugin == null ? "NONE" : "LEAK");
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("NONE");
  });

  // 4.3: vless #fragment becomes the tag
  it("4.3 vless #fragment -> tag", async () => {
    const src = `
let r = require("sharelink").parse_proxy_url("vless://11111111-1111-1111-1111-111111111111@h.example:443?security=tls#MyNode");
print(r.tag);
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("MyNode");
  });

  // 4.3: hy2 #fragment becomes the tag
  it("4.3 hy2 #fragment -> tag", async () => {
    const src = `
let r = require("sharelink").parse_proxy_url("hy2://pw@h.example:443#HyNode");
print(r.tag);
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("HyNode");
  });

  // 1.4/4.4: a percent-encoded query KEY (%73ni == sni) is decoded
  it("1.4 percent-encoded query key (%73ni) decoded to sni", async () => {
    const src = `
let r = require("sharelink").parse_proxy_url("vless://11111111-1111-1111-1111-111111111111@h.example:443?security=tls&%73ni=real.sni");
print(r.tls.server_name);
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("real.sni");
  });

  // REALITY: vless reality link with flow + short_id
  it("vless reality flow + short_id parsed", async () => {
    const src = `
let r = require("sharelink").parse_proxy_url("vless://11111111-1111-1111-1111-111111111111@1.2.3.4:443?type=tcp&security=reality&pbk=PUBKEY&fp=chrome&sid=d38062b9&spx=%2F&flow=xtls-rprx-vision#n");
print(sprintf("%s|%s|%s|%s", r.flow ?? "MISSING", r.tls.reality.short_id ?? "MISSING", r.tls.reality.public_key, r.tls.utls.fingerprint));
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("xtls-rprx-vision|d38062b9|PUBKEY|chrome");
  });

  // vless WITHOUT flow/sid -> clean omission
  it("vless reality without flow/sid omits keys", async () => {
    const src = `
let r = require("sharelink").parse_proxy_url("vless://11111111-1111-1111-1111-111111111111@1.2.3.4:443?security=reality&pbk=PUBKEY#n");
print(sprintf("%s|%s", r.flow == null ? "NONE" : "LEAK", r.tls.reality.short_id == null ? "NONE" : "LEAK"));
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("NONE|NONE");
  });

  // vless alpn + allowInsecure + fp
  it("vless alpn+allowInsecure+fp mapped via SPEC", async () => {
    const src = `
let r = require("sharelink").parse_proxy_url("vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=tls&sni=s.com&alpn=h2,http%2F1.1&allowInsecure=1&fp=chrome#n");
print(sprintf("%s|%d|%s|%s", r.tls.server_name, length(r.tls.alpn), r.tls.insecure===true?"T":"?", r.tls.utls.fingerprint));
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("s.com|2|T|chrome");
  });

  // vless unsupported fields -> absent
  it("vless encryption/mode/headerType/spx left unmapped", async () => {
    const src = `
let r = require("sharelink").parse_proxy_url("vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=tls&encryption=none&mode=gun&headerType=http&spx=%2F#n");
print(sprintf("%s|%s|%s|%s", r.encryption==null?"OMIT":"LEAK", r.mode==null?"OMIT":"LEAK", r.headerType==null?"OMIT":"LEAK", r.spx==null?"OMIT":"LEAK"));
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OMIT|OMIT|OMIT|OMIT");
  });

  // vless without security -> no tls block
  it("vless without security emits no tls block", async () => {
    const src = `
let r = require("sharelink").parse_proxy_url("vless://11111111-1111-1111-1111-111111111111@h.ex:443?type=ws&path=%2Fw#n");
print(r.tls==null ? "NOTLS" : "LEAK");
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("NOTLS");
  });

  // reality missing pbk -> no reality block
  it("vless reality missing pbk omits reality block", async () => {
    const src = `
let r = require("sharelink").parse_proxy_url("vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=reality&sid=ab#n");
print(sprintf("%s|%s", r.tls.enabled===true?"TLS":"?", r.tls.reality==null?"NOREALITY":"LEAK"));
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("TLS|NOREALITY");
  });

  // trojan: sni/peer alias, alpn, allowInsecure, ws transport
  it("trojan sni/peer+alpn+insecure+ws via SPEC", async () => {
    const src = `
let r = require("sharelink").parse_proxy_url("trojan://pw@h.ex:443?peer=p.com&sni=s.com&alpn=h2&allowInsecure=1&type=ws&path=%2Fw&host=ws.com#n");
print(sprintf("%s|%d|%s|%s|%s|%s", r.tls.server_name, length(r.tls.alpn), r.tls.insecure===true?"T":"?", r.transport.type, r.transport.path, r.transport.headers.Host));
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("s.com|1|T|ws|/w|ws.com");
  });

  // hysteria2: alpn + insecure + obfs
  it("hysteria2 alpn+insecure+obfs via SPEC", async () => {
    const src = `
let r = require("sharelink").parse_proxy_url("hy2://pw@h.ex:443?sni=s.com&insecure=1&alpn=h3&obfs=salamander&obfs-password=op#n");
print(sprintf("%s|%s|%d|%s|%s", r.tls.server_name, r.tls.insecure===true?"T":"?", length(r.tls.alpn), r.obfs.type, r.obfs.password));
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("s.com|T|1|salamander|op");
  });

  // hysteria2 pinSHA256 unsupported -> not emitted
  it("hysteria2 pinSHA256/mport declared unsupported", async () => {
    const src = `
let r = require("sharelink").parse_proxy_url("hy2://pw@h.ex:443?sni=s.com&pinSHA256=abc#n");
print(r.tls.pinSHA256==null && r.fingerprint==null ? "OMIT" : "LEAK");
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OMIT");
  });

  // vmess alpn/fp on tls block
  it("vmess alpn+fp mapped via SPEC", async () => {
    const url = vmessUrl({
      v: "2",
      ps: "n",
      add: "e.com",
      port: "443",
      id: "11111111-1111-1111-1111-111111111111",
      aid: "0",
      net: "tcp",
      tls: "tls",
      sni: "s.com",
      alpn: "h2,http/1.1",
      fp: "chrome",
    });
    const src = `
let r = require("sharelink").parse_proxy_url(${JSON.stringify(url)});
print(sprintf("%s|%d|%s", r.tls.server_name, length(r.tls.alpn), r.tls.utls.fingerprint));
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("s.com|2|chrome");
  });

  // tuic
  it("tuic:// parsed", async () => {
    const src = `
let r = require("sharelink").parse_proxy_url("tuic://11111111-1111-1111-1111-111111111111:secret@h.ex:443?congestion_control=bbr&udp_relay_mode=native&sni=s.com&alpn=h3&allow_insecure=1#TU");
print(sprintf("%s|%s|%s|%s|%s|%d|%s|%s", r.type, r.uuid, r.password, r.congestion_control, r.udp_relay_mode, length(r.tls.alpn), r.tls.server_name, r.tls.insecure===true?"T":"?"));
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe(
      "tuic|11111111-1111-1111-1111-111111111111|secret|bbr|native|1|s.com|T",
    );
  });

  // hysteria v1
  it("hysteria:// (v1) parsed", async () => {
    const src = `
let r = require("sharelink").parse_proxy_url("hysteria://h.ex:443?auth=tok&peer=s.com&insecure=1&alpn=h3&upmbps=50&downmbps=100&obfs=xplus#H1");
print(sprintf("%s|%s|%s|%d|%d|%s|%s", r.type, r.auth_str, r.tls.server_name, r.up_mbps, r.down_mbps, r.obfs, r.tls.insecure===true?"T":"?"));
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("hysteria|tok|s.com|50|100|xplus|T");
  });

  // anytls
  it("anytls:// parsed", async () => {
    const src = `
let r = require("sharelink").parse_proxy_url("anytls://mypass@h.ex:443?sni=s.com&insecure=1&alpn=h2#AT");
print(sprintf("%s|%s|%s|%d|%s", r.type, r.password, r.tls.server_name, length(r.tls.alpn), r.tls.insecure===true?"T":"?"));
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("anytls|mypass|s.com|1|T");
  });

  // socks5 base64 user:pass
  it("socks5:// parsed", async () => {
    const socksUser = b64("alice:s3cret");
    const url = `socks5://${socksUser}@h.ex:1080#SK`;
    const src = `
let r = require("sharelink").parse_proxy_url(${JSON.stringify(url)});
print(sprintf("%s|%s|%s|%s|%d", r.type, r.version, r.username, r.password, r.server_port));
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("socks|5|alice|s3cret|1080");
  });

  // socks plain userinfo; udp unsupported
  it("socks:// plain userinfo; udp declared unsupported", async () => {
    const src = `
let r = require("sharelink").parse_proxy_url("socks://bob:pw@h.ex:1080?udp=1#SK2");
print(sprintf("%s|%s|%s|%s", r.username, r.password, r.version, r.udp==null?"OMIT":"LEAK"));
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("bob|pw|5|OMIT");
  });

  // socks user-only literal
  it("socks:// user-only userinfo kept literal", async () => {
    const src = `
let r = require("sharelink").parse_proxy_url("socks://justuser@h.ex:1080#n");
print(sprintf("%s|%s", r.username, r.password==null?"NOPASS":"LEAK"));
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("justuser|NOPASS");
  });
});
