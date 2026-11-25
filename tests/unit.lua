-- Headless unit tests for main.lua: KOReader is stubbed out, nothing touches
-- the device, the network or the filesystem. Lua 5.1 / LuaJIT compatible:
--   lua tests/unit.lua        (or: luajit tests/unit.lua)

local script = (arg and arg[0]) or "tests/unit.lua"
local root = script:match("^(.*)/tests/unit%.lua$")
    or (script:match("^unit%.lua$") and "..")
    or "."

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
        print("ok   - " .. name)
    else
        failed = failed + 1
        print("FAIL - " .. name .. (detail ~= nil and (": " .. tostring(detail)) or ""))
    end
end

-- ─── minimal JSON decoder (stands in for KOReader's json module) ──
-- Only what the plug-in parses: objects, arrays, strings, numbers, booleans.

local function json_decode(s)
    local pos = 1
    local function fail(msg) error(msg .. " at " .. pos, 0) end
    local function skip() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end
    local parse_value

    local function parse_string()
        pos = pos + 1
        local buf = {}
        while true do
            local c = s:sub(pos, pos)
            if c == "" then fail("unterminated string") end
            if c == '"' then
                pos = pos + 1
                return table.concat(buf)
            end
            if c == "\\" then
                local e = s:sub(pos + 1, pos + 1)
                local simple = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
                    b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
                if simple[e] then
                    buf[#buf + 1] = simple[e]
                    pos = pos + 2
                elseif e == "u" then
                    buf[#buf + 1] = "?"
                    pos = pos + 6
                else
                    fail("bad escape")
                end
            else
                buf[#buf + 1] = c
                pos = pos + 1
            end
        end
    end

    local function parse_number()
        local num = s:match("^-?%d+%.?%d*[eE][-+]?%d+", pos) or s:match("^-?%d+%.?%d*", pos)
        if not num then fail("bad number") end
        pos = pos + #num
        return tonumber(num)
    end

    parse_value = function()
        skip()
        local c = s:sub(pos, pos)
        if c == "{" then
            pos = pos + 1
            local obj = {}
            skip()
            if s:sub(pos, pos) == "}" then pos = pos + 1; return obj end
            while true do
                skip()
                if s:sub(pos, pos) ~= '"' then fail("expected key") end
                local k = parse_string()
                skip()
                if s:sub(pos, pos) ~= ":" then fail("expected colon") end
                pos = pos + 1
                obj[k] = parse_value()
                skip()
                local d = s:sub(pos, pos)
                if d == "," then
                    pos = pos + 1
                elseif d == "}" then
                    pos = pos + 1
                    return obj
                else
                    fail("expected , or }")
                end
            end
        elseif c == "[" then
            pos = pos + 1
            local arr = {}
            skip()
            if s:sub(pos, pos) == "]" then pos = pos + 1; return arr end
            while true do
                arr[#arr + 1] = parse_value()
                skip()
                local d = s:sub(pos, pos)
                if d == "," then
                    pos = pos + 1
                elseif d == "]" then
                    pos = pos + 1
                    return arr
                else
                    fail("expected , or ]")
                end
            end
        elseif c == '"' then
            return parse_string()
        elseif s:sub(pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif s:sub(pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        elseif s:sub(pos, pos + 3) == "null" then
            pos = pos + 4
            return nil
        elseif c == "-" or c:match("%d") then
            return parse_number()
        else
            fail("unexpected character '" .. c .. "'")
        end
    end

    local value = parse_value()
    skip()
    if pos <= #s then fail("trailing data") end
    return value
end

-- ─── KOReader stubs ───────────────────────────────────────────────

local function new_settings()
    local data = {}
    return {
        readSetting = function(_, key, default)
            local v = data[key]
            if v == nil then return default end
            return v
        end,
        saveSetting = function(_, key, value) data[key] = value end,
        delSetting = function(_, key) data[key] = nil end,
        flush = function() end,
        _data = data,
    }
end

local ui_calls = { shows = 0 }
local UIManager = {
    show = function(_, widget)
        ui_calls.shows = ui_calls.shows + 1
        ui_calls.last = widget
    end,
    close = function() end,
    forceRePaint = function() end,
    scheduleIn = function(_, delay, fn) ui_calls.scheduled = { delay = delay, fn = fn } end,
    unschedule = function() end,
    quit = function() end,
}

local function widget_module(kind)
    local M = {}
    M.__index = M
    M.new = function(_, opts)
        opts = opts or {}
        opts.kind = kind
        return setmetatable(opts, { __index = M })
    end
    M.onShowKeyboard = function() end
    return M
end

package.preload["datastorage"] = function()
    return {
        getSettingsDir = function() return "/tmp" end,
        getFullDataDir = function() return "/tmp/koreader" end,
    }
end
package.preload["device"] = function()
    return {
        isPocketBook = function() return false end,
        screen = { getWidth = function() return 600 end, getHeight = function() return 800 end },
    }
end
package.preload["ui/uimanager"] = function() return UIManager end
package.preload["ui/widget/container/widgetcontainer"] = function()
    local WC = {}
    WC.__index = WC
    WC.extend = function(self, o)
        o = o or {}
        o.__index = o
        return setmetatable(o, { __index = self })
    end
    return WC
end
package.preload["ui/widget/infomessage"] = function() return widget_module("info") end
package.preload["ui/widget/inputdialog"] = function() return widget_module("input") end
package.preload["ui/widget/buttondialog"] = function() return widget_module("button") end
package.preload["luasettings"] = function()
    return { open = function() return new_settings() end }
end
package.preload["logger"] = function()
    return {
        info = function() end, warn = function() end,
        err = function() end, debug = function() end,
    }
end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["json"] = function() return { decode = json_decode, encode = function() return "" end } end
package.preload["dispatcher"] = function()
    local D = { actions = {} }
    D.registerAction = function(_, id, opts) D.actions[id] = opts end
    return D
end

G_reader_settings = { readSetting = function() return nil end }

local Plugin = dofile(root .. "/main.lua")

local function new_plugin()
    local p = setmetatable({}, { __index = Plugin })
    p.ts_dir = "/tmp/ts"
    p.plugin_dir = "/tmp/ts"
    p.ts_bin = "/tmp/ts/bin"
    p.settings = new_settings()
    return p
end

-- ─── networking flags ─────────────────────────────────────────────

do
    local p = new_plugin()
    p.hasTunDevice = function() return true end
    check("default flags keep every option off",
        p:networkingFlags() == "--accept-routes --ssh=false --netfilter-mode=off",
        p:networkingFlags())

    p.settings:saveSetting("accept_routes", false)
    check("routes off is spelled out",
        p:networkingFlags() == "--accept-routes=false --ssh=false --netfilter-mode=off",
        p:networkingFlags())

    p.settings:saveSetting("accept_routes", true)
    check("routes on passes --accept-routes",
        p:networkingFlags() == "--accept-routes --ssh=false --netfilter-mode=off",
        p:networkingFlags())

    p.settings:saveSetting("tailscale_ssh", true)
    check("ssh on passes --ssh",
        p:networkingFlags() == "--accept-routes --ssh --netfilter-mode=off",
        p:networkingFlags())

    p.settings:saveSetting("tailscale_ssh", false)
    check("ssh off passes --ssh=false",
        p:networkingFlags():find(" --ssh=false ", 1, true) ~= nil, p:networkingFlags())

    p.settings:saveSetting("force_userspace", true)
    check("Lua does not own the DNS flag",
        p:networkingFlags():find("accept-dns", 1, true) == nil,
        p:networkingFlags())
end

-- ─── quoting / start environment ─────────────────────────────────

do
    local p = new_plugin()
    check("shellQuote survives a single quote", p:shellQuote("a'b") == "'a'\\''b'", p:shellQuote("a'b"))

    p._tun_flag = "--tun=tailscale0"
    p._network_mode = "kernel TUN"
    p._up_flags = "--accept-routes"
    local url = "https://hs.example/it's;reboot"
    p._up_headscale_url = url
    local env = p:getStartEnvironment("/tmp/state")
    check("start env sets TS_LOGS_DIR under the state dir",
        env:find("TS_LOGS_DIR='/tmp/state/logs'", 1, true) ~= nil, env)
    check("headscale URL is quoted, quotes and semicolon included",
        env:find("TS_LOGIN_SERVER='" .. url:gsub("'", "'\\''") .. "'", 1, true) ~= nil, env)
    check("headscale URL never appears unquoted",
        env:find("TS_LOGIN_SERVER=" .. url, 1, true) == nil, env)
end

-- ─── status summary ──────────────────────────────────────────────

do
    local p = new_plugin()
    local lines = p:summaryFromStatusJSON(
        '{"BackendState":"Running","Self":{"TailscaleIPs":["100.64.0.1","fd7a::1"],"HostName":"reader"}}')
    check("summary: state", lines and lines[1] == "State: Running", lines and lines[1])
    check("summary: IPs", lines and lines[2] == "IPs: 100.64.0.1, fd7a::1", lines and lines[2])
    check("summary: device", lines and lines[3] == "Device: reader", lines and lines[3])
    check("summary: undecodable body is nil, so callers fall back",
        p:summaryFromStatusJSON("not json at all") == nil)
    check("summary: empty body is nil", p:summaryFromStatusJSON("") == nil)
end

-- ─── dispatcher toggle ──────────────────────────────────────────

do
    local p = new_plugin()
    local order = {}
    p.connectTailscale = function() order[#order + 1] = "connect" end
    p.disconnectTailscale = function() order[#order + 1] = "disconnect" end
    p.getBackendState = function() return "Running" end
    local ret = p:onToggleTailscale()
    check("toggle disconnects when Running", ret == true and order[1] == "disconnect" and #order == 1,
        table.concat(order, ","))
    p.getBackendState = function() return "Stopped" end
    ret = p:onToggleTailscale()
    check("toggle connects when not Running", ret == true and order[2] == "connect" and #order == 2,
        table.concat(order, ","))

    local q = new_plugin()
    local ev = {}
    q.stopLoginPolling = function() ev[#ev + 1] = "stop-poll" end
    q.execStopScript = function() ev[#ev + 1] = "stop-daemon" end
    q:disconnectTailscale()
    check("disconnect stops polling before the daemon",
        ev[1] == "stop-poll" and ev[2] == "stop-daemon", table.concat(ev, ","))
end

-- ─── result ──────────────────────────────────────────────────────

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
    os.exit(1)
end
os.exit(0)
