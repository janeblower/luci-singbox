#!/bin/sh
# Apply or remove the singbox-ui nftables redirect rules.
# Subcommands:
#   apply           Read UCI, generate rules, apply via nft.
#   remove          Delete the singbox_ui table.
#   emit P V4 V6 IF Print rules to stdout (used by tests). V4/V6 are
#                   already comma-separated set bodies; IF is the interface.
#
# Two prerouting chains:
#   prerouting_mark   (priority -150 = mangle)     mark matching connections
#   prerouting_tproxy (priority -149 = mangle + 1)  redirect marked connections

set -eu

emit() {
	port="$1"
	v4="$2"
	v6="$3"
	iface="$4"

	printf 'table inet singbox_ui {\n'
	printf '\tchain prerouting_mark {\n'
	printf '\t\ttype filter hook prerouting priority -150; policy accept;\n\n'
	[ -n "$v4" ] && printf '\t\tiifname "%s" ip  daddr { %s } meta l4proto { tcp, udp } meta mark set 0x1\n' "$iface" "$v4"
	[ -n "$v6" ] && printf '\t\tiifname "%s" ip6 daddr { %s } meta l4proto { tcp, udp } meta mark set 0x1\n' "$iface" "$v6"
	printf '\t}\n\n'
	printf '\tchain prerouting_tproxy {\n'
	printf '\t\ttype filter hook prerouting priority -149; policy accept;\n\n'
	printf '\t\tmeta mark 0x1 meta l4proto { tcp, udp } tproxy ip  to 127.0.0.1:%s\n' "$port"
	printf '\t\tmeta mark 0x1 meta l4proto { tcp, udp } tproxy ip6 to [::1]:%s\n' "$port"
	printf '\t}\n'
	printf '}\n'
}

apply() {
	# UCI list values come back space-separated; nft set syntax wants commas.
	port=$(uci -q get singbox-ui.tproxy.port)
	port=${port:-7893}
	iface=$(uci -q get singbox-ui.tproxy.interface)
	iface=${iface:-br-lan}
	v4=$(uci -q get singbox-ui.fakeip.inet4_range | tr ' ' ',')
	v6=$(uci -q get singbox-ui.fakeip.inet6_range | tr ' ' ',')

	if [ -z "$v4" ] && [ -z "$v6" ]; then
		echo "nftables.sh: no fakeip ranges configured; nothing to apply" >&2
		return 1
	fi

	# Replace any prior incarnation atomically: delete-if-exists then re-add.
	nft delete table inet singbox_ui 2>/dev/null || true
	emit "$port" "$v4" "$v6" "$iface" | nft -f -
}

remove() {
	nft delete table inet singbox_ui 2>/dev/null || true
}

case "${1:-}" in
	apply)  apply ;;
	remove) remove ;;
	emit)
		[ "$#" -eq 5 ] || { echo "Usage: $0 emit PORT V4SET V6SET IFACE" >&2; exit 2; }
		emit "$2" "$3" "$4" "$5"
		;;
	*)
		echo "Usage: $0 {apply|remove|emit PORT V4SET V6SET IFACE}" >&2
		exit 2
		;;
esac
