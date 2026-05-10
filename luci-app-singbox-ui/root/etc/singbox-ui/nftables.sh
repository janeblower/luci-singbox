#!/bin/sh
# Apply or remove the singbox-ui nftables redirect rules.
# Subcommands:
#   apply           Read UCI, generate rules, apply via nft.
#   remove          Delete the singbox_ui table.
#   emit P V4 V6    Print rules to stdout (used by tests). V4/V6 are
#                   already comma-separated set bodies.

set -eu

emit() {
	port="$1"
	v4="$2"
	v6="$3"
	cat <<EOF
table inet singbox_ui {
	chain prerouting {
		type filter hook prerouting priority mangle; policy accept;

		ip daddr { ${v4} } meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:${port} meta mark set 1
		ip6 daddr { ${v6} } meta l4proto { tcp, udp } tproxy ip6 to [::1]:${port} meta mark set 1
	}
}
EOF
}

apply() {
	# UCI list values come back space-separated; nft set syntax wants commas.
	port=$(uci -q get singbox-ui.tproxy.port)
	port=${port:-7893}
	v4=$(uci -q get singbox-ui.fakeip.inet4_range | tr ' ' ',')
	v6=$(uci -q get singbox-ui.fakeip.inet6_range | tr ' ' ',')

	if [ -z "$v4" ] && [ -z "$v6" ]; then
		echo "nftables.sh: no fakeip ranges configured; nothing to apply" >&2
		return 1
	fi

	# Replace any prior incarnation atomically: delete-if-exists then re-add.
	nft delete table inet singbox_ui 2>/dev/null || true
	emit "$port" "$v4" "$v6" | nft -f -
}

remove() {
	nft delete table inet singbox_ui 2>/dev/null || true
}

case "${1:-}" in
	apply)  apply ;;
	remove) remove ;;
	emit)
		[ "$#" -eq 4 ] || { echo "Usage: $0 emit PORT V4SET V6SET" >&2; exit 2; }
		emit "$2" "$3" "$4"
		;;
	*)
		echo "Usage: $0 {apply|remove|emit PORT V4SET V6SET}" >&2
		exit 2
		;;
esac
