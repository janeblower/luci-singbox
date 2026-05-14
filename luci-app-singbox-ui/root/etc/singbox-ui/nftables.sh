#!/bin/sh
# Apply or remove the singbox-ui nftables redirect rules.
# Subcommands:
#   apply           Read UCI, generate rules, apply via nft.
#   remove          Delete the singbox_ui table.
#   emit P V4 V6 IF Print rules to stdout (used by tests). V4/V6 are
#                   already comma-separated set bodies; IF is the interface.
#                   Additionally scans /tmp/singbox-ui/rs_*.json for sing-box
#                   rule-set caches and appends nft named sets + marking rules
#                   for each ip_cidr entry found.
#
# Two prerouting chains:
#   prerouting_mark   (priority -150 = mangle)     mark matching connections
#   prerouting_tproxy (priority -149 = mangle + 1)  redirect marked connections

set -eu

# Populated by emit_ruleset_data() before the prerouting_mark chain is printed,
# then injected into the chain body alongside the fakeip rules.
RS_MARK_RULES=""

emit_ruleset_data() {
	rs_tmpdir=/tmp/singbox-ui
	RS_MARK_RULES=""

	[ -d "$rs_tmpdir" ] || return 0
	command -v jq >/dev/null 2>&1 || return 0

	for json_file in "$rs_tmpdir"/rs_*.json; do
		[ -f "$json_file" ] || continue
		fname=$(basename "$json_file" .json)
		name=${fname#rs_}

		rules=$(jq -r '
			.rules[]? | select(.ip_cidr) |
			((.ip_cidr | join(",")) + "|" +
			 (.network // "") + "|" +
			 (.port_range // [] | join(",")))
		' "$json_file" 2>/dev/null) || rules=""
		[ -z "$rules" ] && continue

		idx=0
		old_ifs=$IFS
		IFS='
'
		for line in $rules; do
			cidrs=${line%%|*}
			rest=${line#*|}
			network=${rest%%|*}
			ports=${rest#*|}
			set_name="rs_${name}_${idx}"

			printf '\tset %s {\n'           "$set_name"
			printf '\t\ttype ipv4_addr\n'
			printf '\t\tflags interval\n'
			printf '\t\telements = { %s }\n' "$cidrs"
			printf '\t}\n\n'

			case "$network" in
				tcp) l4proto_expr="meta l4proto tcp" ;;
				udp) l4proto_expr="meta l4proto udp" ;;
				*)   l4proto_expr="meta l4proto { tcp, udp }" ;;
			esac

			port_expr=""
			if [ -n "$ports" ]; then
				nft_ports=$(printf '%s' "$ports" | sed 's/:/-/g')
				case "$nft_ports" in
					*,*) nft_ports="{ $(printf '%s' "$nft_ports" | sed 's/,/, /g') }" ;;
				esac
				case "$network" in
					tcp) port_expr=" tcp dport $nft_ports" ;;
					udp) port_expr=" udp dport $nft_ports" ;;
					*)   port_expr=" th dport $nft_ports" ;;
				esac
			fi

			line_out=$(printf '\t\tip daddr @%s %s%s ct state new meta mark set 0x1\n' \
				"$set_name" "$l4proto_expr" "$port_expr")
			RS_MARK_RULES="${RS_MARK_RULES}${line_out}
"
			idx=$((idx + 1))
		done
		IFS=$old_ifs
	done
}

emit() {
	port="$1"
	v4="$2"
	v6="$3"
	iface="$4"

	printf 'table inet singbox_ui {\n'

	# Named sets first (nft accepts any order, but sets-before-chains is the
	# canonical layout and matches the spec example).
	emit_ruleset_data

	printf '\tchain prerouting_mark {\n'
	printf '\t\ttype filter hook prerouting priority -150; policy accept;\n\n'
	[ -n "$v4" ] && printf '\t\tiifname "%s" ip  daddr { %s } meta l4proto { tcp, udp } meta mark set 0x1\n' "$iface" "$v4"
	[ -n "$v6" ] && printf '\t\tiifname "%s" ip6 daddr { %s } meta l4proto { tcp, udp } meta mark set 0x1\n' "$iface" "$v6"
	[ -n "$RS_MARK_RULES" ] && printf '%s' "$RS_MARK_RULES"
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
