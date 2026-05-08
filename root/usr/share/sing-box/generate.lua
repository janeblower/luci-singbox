#!/usr/bin/env lua

-- Make the helper module reachable on OpenWrt where /usr/share/sing-box is
-- not on package.path.
package.path = "/usr/share/sing-box/?.lua;" .. package.path

local sbc = require("sing_box_config")
local jsonc = require("luci.jsonc")

local state = sbc.read_uci()
local config = sbc.build_config(state)

local out = assert(io.open("/tmp/sing-box.json", "w"))
out:write(jsonc.stringify(config, true))
out:write("\n")
out:close()

io.write("OK\n")
