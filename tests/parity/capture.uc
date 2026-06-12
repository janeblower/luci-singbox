// tests/parity/capture.uc — run on the PRE-refactor tree to write goldens.
// Usage: ucode -L tests/parity -L <lib> tests/parity/capture.uc
let fs = require("fs");
let canon = require("canon").canon;
let corpus = require("corpus");
let ob = require("outbound");
let inb = require("inbound");

let dir = "tests/parity/golden";
fs.mkdir(dir);
for (let fx in corpus) {
    let got = (fx.kind === "outbound")
        ? ob.build_constructor_for(fx.section, fx.type)
        : inb.build_one(fx.section);
    let f = fs.open(sprintf("%s/%s.json", dir, fx.name), "w");
    f.write(sprintf("%J\n", canon(got)));
    f.close();
    print(sprintf("wrote %s\n", fx.name));
}
