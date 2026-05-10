#!/usr/bin/env lua

-- Make the helper module reachable on OpenWrt where /usr/share/singbox-ui is
-- not on package.path.
package.path = "/usr/share/singbox-ui/?.lua;" .. package.path

local sbc = require("singbox_ui_config")
local jsonc = require("luci.jsonc")

local state = sbc.read_uci()
local config = sbc.build_config(state)

local out = assert(io.open("/tmp/singbox-ui.json", "w"))
out:write(jsonc.stringify(config, true))
out:write("\n")
out:close()

io.write("OK\n")
