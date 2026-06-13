// lib/builder/protocols/ssh.uc — SSH proxy outbound (E2 DSL). cipher/mac/kex 1.14+.
let reg = require("builder.protocols.registry");

reg.register({
    kind: "outbound", type: "ssh", sing_box_type: "ssh",
    shared: { dial: true },
    fields: [
        { name: "server", type: "string", tab: "basic", required: true,
          validate: "host", ui_label: "Server", json_key: "server", omit_when: "never" },
        { name: "server_port", type: "number", tab: "basic", required: true,
          validate: "port", default: 22, ui_label: "Server port",
          json_key: "server_port", coerce: "num", omit_when: "never" },
        { name: "ssh_user", type: "string", tab: "basic", ui_label: "User",
          default: "root", json_key: "user" },
        { name: "server_password", type: "string", tab: "basic", secret: true,
          ui_label: "Password", json_key: "password" },
        { name: "private_key", type: "string", tab: "basic", secret: true, multiline: true,
          ui_label: "Private key (PEM)", advanced: true, json_key: "private_key" },
        { name: "private_key_path", type: "string", tab: "basic",
          ui_label: "Private key path", advanced: true, json_key: "private_key_path" },
        { name: "private_key_passphrase", type: "string", tab: "basic", secret: true,
          ui_label: "Private key passphrase", advanced: true, json_key: "private_key_passphrase" },
        { name: "host_key", type: "list", tab: "basic", ui_label: "Host key(s)",
          advanced: true, json_key: "host_key", coerce: "array" },
        { name: "host_key_algorithms", type: "list", tab: "basic", ui_label: "Host key algorithms",
          advanced: true, json_key: "host_key_algorithms", coerce: "array" },
        { name: "client_version", type: "string", tab: "basic", ui_label: "Client version",
          placeholder: "SSH-2.0-OpenSSH_7.4p1", advanced: true, json_key: "client_version" },
        { name: "ssh_cipher", type: "list", tab: "basic", ui_label: "Ciphers (1.14+)",
          advanced: true, json_key: "cipher", coerce: "array" },
        { name: "ssh_mac", type: "list", tab: "basic", ui_label: "MACs (1.14+)",
          advanced: true, json_key: "mac", coerce: "array" },
        { name: "ssh_kex_algorithm", type: "list", tab: "basic", ui_label: "KEX algorithms (1.14+)",
          advanced: true, json_key: "kex_algorithm", coerce: "array" },
    ],
});

return {};
