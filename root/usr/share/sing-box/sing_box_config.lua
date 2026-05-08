local M = {}

local function as_bool(v)
  return v == "1" or v == 1 or v == true
end

function M.read_uci(cursor)
  local cur = cursor or require("uci").cursor()
  local function get(section, option)
    return cur:get("sing-box", section, option)
  end
  local function list(section, option)
    return cur:get_list("sing-box", section, option) or {}
  end
  return {
    fakeip = {
      enabled = as_bool(get("fakeip", "enabled")),
      inet4_range = list("fakeip", "inet4_range"),
      inet6_range = list("fakeip", "inet6_range"),
    },
    tproxy = {
      enabled = as_bool(get("tproxy", "enabled")),
      interface = get("tproxy", "interface") or "br-lan",
      port = tonumber(get("tproxy", "port")) or 7893,
    },
    nftables = {
      enabled = as_bool(get("nftables", "enabled")),
    },
  }
end

function M.build_config(state)
  local out = {}
  if state.fakeip.enabled then
    out.dns = {
      fakeip = {
        enabled = true,
        inet4_range = state.fakeip.inet4_range,
        inet6_range = state.fakeip.inet6_range,
      },
    }
  end
  if state.tproxy.enabled then
    out.inbounds = { {
      type = "tproxy",
      listen = "::",
      listen_port = state.tproxy.port,
    } }
  end
  return out
end

return M
