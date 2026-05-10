-- tests/test_generate_smoke.lua
local h = dofile("tests/helpers.lua")

-- Stub the OpenWrt-only modules.
local fake_data = {
  ["singbox-ui"] = {
    fakeip = {
      enabled = "1",
      inet4_range = { "198.18.0.0/15" },
      inet6_range = { "fc00::/18" },
    },
    tproxy = { enabled = "1", interface = "br-lan", port = "7893" },
    nftables = { enabled = "0" },
  },
}

package.preload["uci"] = function()
  return { cursor = function() return h.fake_cursor(fake_data) end }
end

local cjson = require("cjson")
package.preload["luci.jsonc"] = function()
  return { stringify = function(v) return cjson.encode(v) end }
end

-- Redirect /tmp/singbox-ui.json to a unique tmp file.
local tmp = os.tmpname()
local real_open = io.open
io.open = function(path, mode)
  if path == "/tmp/singbox-ui.json" then return real_open(tmp, mode) end
  return real_open(path, mode)
end

-- Make the entrypoint find the helper module locally.
package.path = "luci-app-singbox-ui/root/usr/share/singbox-ui/?.lua;" .. package.path

dofile("luci-app-singbox-ui/root/usr/share/singbox-ui/generate.lua")

local f = assert(io.open(tmp, "r"))
local body = f:read("*a")
f:close()
os.remove(tmp)

local decoded = cjson.decode(body)
h.test("generate.lua: dns.fakeip emitted", function()
  h.assert_deep_equal(decoded.dns.fakeip.enabled, true)
  h.assert_deep_equal(decoded.dns.fakeip.inet4_range, { "198.18.0.0/15" })
end)
h.test("generate.lua: tproxy inbound emitted", function()
  h.assert_deep_equal(decoded.inbounds[1].type, "tproxy")
  h.assert_deep_equal(decoded.inbounds[1].listen_port, 7893)
end)
h.summary()
