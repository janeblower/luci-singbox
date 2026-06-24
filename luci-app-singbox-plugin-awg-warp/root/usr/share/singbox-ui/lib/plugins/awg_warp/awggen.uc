// lib/plugins/awg_warp/awggen.uc — AmneziaWG param generation.
// Two axes: target (warp|selfhosted) gates S/H; mimic shapes I1 only.
// CRUCIAL: target=warp force-pins S=0, H=1/2/3/4, MTU after reading the preset,
// so a malformed preset can never produce a WARP-breaking config (spec §10).
let fs = require("fs");

// rand_int(lo, hi) — inclusive, from /dev/urandom (no Math.random in ucode prod).
function rand_int(lo, hi) {
	if (hi <= lo) return lo;
	let f = fs.open("/dev/urandom", "r");
	let span = hi - lo + 1;
	let n = lo;
	if (f) {
		let b = f.read(4); f.close();
		if (b != null && length(b) == 4) {
			let v = (ord(b, 0) << 24) + (ord(b, 1) << 16) + (ord(b, 2) << 8) + ord(b, 3);
			if (v < 0) v = -v;
			n = lo + (v % span);
		}
	}
	return n;
}

const MIMICS = [ "quic", "dns", "stun", "dtls", "sip", "tls", "static" ];
// auto excludes tls (anomalous UDP:4500 TLS shape; spec §5.2)
const AUTO_POOL = [ "quic", "dns", "stun", "dtls", "sip", "static" ];

function pick_mimic(m) {
	if (m == "auto" || m == null || !length(`${m}`)) return AUTO_POOL[rand_int(0, length(AUTO_POOL) - 1)];
	for (let x in MIMICS) if (x == m) return m;
	return "static";
}

// i1_for(mimic) — a CPS-tag-shaped concealment packet spec (client-side only,
// WARP-safe). Format token <b 0x...> per amneziawg I-packet syntax. Static here;
// real per-protocol byte templates are filled from docs/protocol-coverage notes.
function i1_for(mimic) {
	// minimal valid CPS tag: a small random hex blob. Server ignores it.
	let n = rand_int(8, 40), hex = "";
	for (let i = 0; i < n; i++) {
		let nib = "0123456789abcdef";
		hex += substr(nib, rand_int(0, 15), 1) + substr(nib, rand_int(0, 15), 1);
	}
	return sprintf("<b 0x%s>", hex);
}

function generate(opts) {
	opts = opts ?? {};
	let mtu = int(`${opts.mtu ?? 1280}`); if (mtu <= 0) mtu = 1280;
	let cap = (mtu < 1280) ? mtu : 1280;

	let jc   = rand_int(1, 25);
	let jmin = rand_int(64, 256);
	let jmax = rand_int(jmin + 64, (cap < jmin + 64) ? jmin + 64 : cap);
	let mimic = pick_mimic(opts.mimic);

	let p = {
		jc: jc, jmin: jmin, jmax: jmax,
		s1: rand_int(15, 150), s2: rand_int(15, 150), s3: 0, s4: 0,
		h1: rand_int(5, 2147483647), h2: rand_int(5, 2147483647),
		h3: rand_int(5, 2147483647), h4: rand_int(5, 2147483647),
		i1: i1_for(mimic), mtu: mtu, target: (opts.target == "selfhosted") ? "selfhosted" : "warp", mimic: mimic,
	};

	if (p.target != "selfhosted") {
		// FORCE WARP-safe — overwrite anything the preset/random produced.
		p.s1 = 0; p.s2 = 0; p.s3 = 0; p.s4 = 0;
		p.h1 = 1; p.h2 = 2; p.h3 = 3; p.h4 = 4;
	}
	return p;
}

function validate_selfhosted(p, mtu) {
	let e = [];
	if (p.jmin >= p.jmax) push(e, "Jmin must be < Jmax");
	if ((p.s1 + 56) == p.s2) push(e, "S1+56 must not equal S2");
	let hs = [p.h1, p.h2, p.h3, p.h4];
	for (let h in hs) if (h < 5) push(e, "H values must be >= 5");
	let seen = {};
	for (let h in hs) { if (seen[h]) push(e, "H values must be distinct"); seen[h] = true; }
	if (p.jmax > ((mtu < 1280) ? mtu : 1280)) push(e, "Jmax must be <= min(MTU,1280)");
	return e;
}

return { generate, validate_selfhosted, pick_mimic };
