package.path = "root/usr/share/sing-box/?.lua;tests/?.lua;" .. package.path
local h = require("helpers")
local sbc = require("sing_box_config")

h.test("build_config: empty when nothing enabled", function()
  local out = sbc.build_config({
    fakeip = { enabled = false, inet4_range = {}, inet6_range = {} },
    tproxy = { enabled = false, interface = "br-lan", port = 7893 },
  })
  h.assert_deep_equal(out, {})
end)

h.test("build_config: emits dns.fakeip when fakeip enabled", function()
  local out = sbc.build_config({
    fakeip = {
      enabled = true,
      inet4_range = { "198.18.0.0/15" },
      inet6_range = { "fc00::/18" },
    },
    tproxy = { enabled = false, interface = "br-lan", port = 7893 },
  })
  h.assert_deep_equal(out, {
    dns = {
      fakeip = {
        enabled = true,
        inet4_range = { "198.18.0.0/15" },
        inet6_range = { "fc00::/18" },
      },
    },
  })
end)

h.test("build_config: emits tproxy inbound when tproxy enabled", function()
  local out = sbc.build_config({
    fakeip = { enabled = false, inet4_range = {}, inet6_range = {} },
    tproxy = { enabled = true, interface = "br-lan", port = 7893 },
  })
  h.assert_deep_equal(out, {
    inbounds = { {
      type = "tproxy",
      listen = "::",
      listen_port = 7893,
    } },
  })
end)

h.test("build_config: both sections enabled", function()
  local out = sbc.build_config({
    fakeip = {
      enabled = true,
      inet4_range = { "198.18.0.0/15" },
      inet6_range = { "fc00::/18" },
    },
    tproxy = { enabled = true, interface = "br-lan", port = 1234 },
  })
  h.assert_deep_equal(out.dns.fakeip.enabled, true)
  h.assert_deep_equal(out.inbounds[1].listen_port, 1234)
end)

h.test("build_config: multiple ranges preserved in order", function()
  local out = sbc.build_config({
    fakeip = {
      enabled = true,
      inet4_range = { "198.18.0.0/15", "10.0.0.0/8" },
      inet6_range = {},
    },
    tproxy = { enabled = false, interface = "br-lan", port = 7893 },
  })
  h.assert_deep_equal(out.dns.fakeip.inet4_range, { "198.18.0.0/15", "10.0.0.0/8" })
  h.assert_deep_equal(out.dns.fakeip.inet6_range, {})
end)

-- read_uci tests use the fake cursor from helpers.

h.test("read_uci: parses '1' as enabled and string port as number", function()
  local cur = h.fake_cursor({
    ["sing-box"] = {
      fakeip = {
        enabled = "1",
        inet4_range = { "198.18.0.0/15" },
        inet6_range = { "fc00::/18" },
      },
      tproxy = {
        enabled = "0",
        interface = "br-lan",
        port = "7893",
      },
    },
  })
  local s = sbc.read_uci(cur)
  h.assert_deep_equal(s.fakeip.enabled, true)
  h.assert_deep_equal(s.tproxy.enabled, false)
  h.assert_deep_equal(s.tproxy.port, 7893)
  h.assert_deep_equal(s.fakeip.inet4_range, { "198.18.0.0/15" })
end)

h.test("read_uci: missing values fall back to safe defaults", function()
  local cur = h.fake_cursor({ ["sing-box"] = {} })
  local s = sbc.read_uci(cur)
  h.assert_deep_equal(s.fakeip.enabled, false)
  h.assert_deep_equal(s.fakeip.inet4_range, {})
  h.assert_deep_equal(s.tproxy.port, 7893)
  h.assert_deep_equal(s.tproxy.interface, "br-lan")
end)

h.summary()
