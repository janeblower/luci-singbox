// lib/plugins/awg_warp/awggen.uc — AmneziaWG param generation.
// WARP-only: S=0 and H=1/2/3/4 are forced (Cloudflare reserves those bytes), so a
// preset can never produce a WARP-breaking config (spec §10).
//
// Gone, deliberately:
//   * the mimic axis (quic/dns/stun/... presets, pick_mimic, AUTO_POOL). i1_for()
//     never read its argument — the I1 blob was random hex whatever you picked —
//     so the UI dropdown, the UCI field and the threading were pure theatre.
//   * the selfhosted target axis (validate_selfhosted, the S/H randomisation it
//     guarded). Nothing ever set awg_target: the branch was unreachable, and
//     generate() overwrote its random S/H with the WARP constants anyway.
// Both are in git history if a real self-hosted mode ever ships.
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

// i1() — a CPS-tag-shaped concealment packet spec (client-side only, WARP-safe).
// Format token <b 0x...> per amneziawg I-packet syntax; the server ignores it.
function i1() {
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

	return {
		jc: jc, jmin: jmin, jmax: jmax,
		// WARP-safe constants, not randomised: Cloudflare reserves these bytes.
		s1: 0, s2: 0, s3: 0, s4: 0,
		h1: 1, h2: 2, h3: 3, h4: 4,
		i1: i1(), mtu: mtu,
	};
}

return { generate };
