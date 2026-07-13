import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

// import_section, driven through the PRODUCTION path (the rpcd handler, not
// `ucode -L lib`), because that is where the trust boundary lives: kind and name
// reach a shell argv, and the JSON body carries passwords.
//
// The method is a pure read — it parses the JSON against the section's descriptor
// and returns what to write; the frontend applies it into LuCI's own changeset.
// That is why it sits on the READ ACL.

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const SB = `${WORK}/singbox-ui/root/usr/share/singbox-ui`;
const RPCD = `${WORK}/singbox-ui/root/usr/libexec/rpcd/singbox-ui`;
const TMP = `/tmp/sb-import-${process.pid}`;

const CONFIG = `config outbound 'v1'
\toption enabled '1'
\toption type 'vless'
\toption server 'a.b'
\toption server_port '443'
\toption server_uuid '11111111-2222-3333-4444-555555555555'
\toption tls_enabled '1'
\toption tls_server_name 'sni.example'

config outbound 'sub1'
\toption enabled '1'
\toption type 'subscription'
\toption sub_url 'https://example.com/sub'

config route_rule 'rr1'
\toption enabled '1'
\toption type 'default'
\tlist domain_suffix '.ru'
\toption action 'route'
\toption outbound 'v1'
`;

const ENV =
  `UCI_CONFIG_DIR=${TMP} UCODE_LIB=${SB}/lib ` +
  `EXPORT_SECTION_UC=${SB}/export_section.uc IMPORT_SECTION_UC=${SB}/import_section.uc`;

interface ImportResult {
  status: string;
  message?: string;
  tag?: string | null;
  fields?: Record<string, string | string[]>;
  known?: string[];
  extra?: Record<string, unknown>;
}

async function rpcd(method: string, args: unknown): Promise<ImportResult> {
  const body = JSON.stringify(args).replace(/'/g, `'\\''`);
  const r = await exec(
    `cd ${WORK} && printf '%s' '${body}' | ${ENV} ucode -L ${SB}/lib ${RPCD} call ${method}`,
  );
  expect(r.exitCode).toBe(0);
  return JSON.parse(r.stdout) as ImportResult;
}

describe("import_section (rpcd prod path)", () => {
  useGuest();

  it("setup", async () => {
    await exec(`mkdir -p ${TMP}`);
    await putFile(CONFIG, `${TMP}/singbox-ui`);
  });

  it("is advertised by `list` with the json param", async () => {
    const r = await exec(`cd ${WORK} && ucode -L ${SB}/lib ${RPCD} list`);
    const sigs = JSON.parse(r.stdout) as Record<string, unknown>;
    expect(sigs.import_section).toEqual({
      kind: "string",
      name: "string",
      json: "string",
    });
  });

  it("returns the changed fields, the known set, and no extra", async () => {
    const r = await rpcd("import_section", {
      kind: "outbound",
      name: "v1",
      json: JSON.stringify({
        type: "vless",
        tag: "v1",
        server: "new.example",
        server_port: 8443,
        uuid: "11111111-2222-3333-4444-555555555555",
        tls: { enabled: true, server_name: "sni.example" },
      }),
    });

    expect(r.status).toBe("ok");
    expect(r.tag).toBe("v1");
    expect(r.fields?.server).toBe("new.example");
    // UCI has no types: a JSON number comes back as a string.
    expect(r.fields?.server_port).toBe("8443");
    expect(r.fields?.tls_enabled).toBe("1");
    expect(r.extra).toEqual({});

    // `known` is what lets the caller apply a DIFF. It must cover the shared
    // blocks (not just the protocol's own fields) or the editor could never clear
    // a TLS/transport/dial setting.
    expect(r.known).toContain("server");
    expect(r.known).toContain("tls_enabled");
    expect(r.known).toContain("transport_type");
    expect(r.known).toContain("bind_interface");
    // …and must NOT cover UCI-only options, which a JSON edit must never touch.
    expect(r.known).not.toContain("enabled");
    expect(r.known).not.toContain("builtin");
    expect(r.known).not.toContain("json_extra");
  });

  it("a dropped tls block leaves tls_enabled out of fields, so the caller clears it", async () => {
    const r = await rpcd("import_section", {
      kind: "outbound",
      name: "v1",
      json: JSON.stringify({
        type: "vless",
        tag: "v1",
        server: "a.b",
        server_port: 443,
        uuid: "11111111-2222-3333-4444-555555555555",
      }),
    });
    expect(r.status).toBe("ok");
    // Absent, not "0": it is in `known`, so the caller removes it. An unset UCI
    // option is already false, and writing "0" for every unset flag would bury the
    // real settings.
    expect(r.fields).not.toHaveProperty("tls_enabled");
    expect(r.known).toContain("tls_enabled");
  });

  it("an unrecognised key lands in extra instead of being dropped", async () => {
    const r = await rpcd("import_section", {
      kind: "outbound",
      name: "v1",
      json: JSON.stringify({
        type: "vless",
        tag: "v1",
        server: "a.b",
        server_port: 443,
        uuid: "11111111-2222-3333-4444-555555555555",
        some_future_key: { nested: [1, 2] },
      }),
    });
    expect(r.status).toBe("ok");
    expect(r.extra).toEqual({ some_future_key: { nested: [1, 2] } });
  });

  it("a changed tag is reported, so the caller renames instead of creating", async () => {
    const r = await rpcd("import_section", {
      kind: "outbound",
      name: "v1",
      json: JSON.stringify({
        type: "vless",
        tag: "tokyo",
        server: "a.b",
        server_port: 443,
        uuid: "11111111-2222-3333-4444-555555555555",
      }),
    });
    expect(r.status).toBe("ok");
    expect(r.tag).toBe("tokyo");
  });

  it("works for a headerless kind (route_rule has no type/tag)", async () => {
    const r = await rpcd("import_section", {
      kind: "route_rule",
      name: "rr1",
      json: JSON.stringify({
        domain_suffix: [".ru", ".su"],
        action: "route",
        outbound: "v1",
      }),
    });
    expect(r.status).toBe("ok");
    expect(r.tag).toBeNull();
    expect(r.fields?.domain_suffix).toEqual([".ru", ".su"]);
    expect(r.fields?.action).toBe("route");
  });

  it("refuses a subscription outbound — there is no single object to edit", async () => {
    const r = await rpcd("import_section", {
      kind: "outbound",
      name: "sub1",
      json: JSON.stringify({ type: "subscription", tag: "sub1" }),
    });
    expect(r.status).toBe("error");
    expect(r.message).toContain("subscription");
  });

  it("rejects a bogus kind and a bogus name at the trust boundary", async () => {
    const bad = await rpcd("import_section", {
      kind: "../etc",
      name: "v1",
      json: "{}",
    });
    expect(bad.status).toBe("error");
    expect(bad.message).toContain("invalid kind");

    const badName = await rpcd("import_section", {
      kind: "outbound",
      name: "../../x",
      json: "{}",
    });
    expect(badName.status).toBe("error");
    expect(badName.message).toContain("invalid or missing name");
  });

  it("rejects a non-object body", async () => {
    const r = await rpcd("import_section", {
      kind: "outbound",
      name: "v1",
      json: "[1,2,3]",
    });
    expect(r.status).toBe("error");
  });

  it("leaves no staging tmpfile behind", async () => {
    // The body carries passwords, so it is staged in a 0600 tmpfile rather than
    // passed on the command line (argv is world-readable in /proc). Cleanup is
    // unconditional.
    const r = await exec(`ls /tmp/singbox-ui-import.* 2>/dev/null | wc -l`);
    expect(r.stdout.trim()).toBe("0");
  });

  it("export_section covers the new kinds", async () => {
    for (const kind of ["route_rule"]) {
      const r = await rpcd("export_section", { kind, name: "rr1" });
      expect(r.status).toBe("ok");
    }
  });

  it("cleanup", async () => {
    await exec(`rm -rf ${TMP}`);
  });
});
