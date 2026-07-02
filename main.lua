local DataStorage = require("datastorage")
local Device = require("device")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local _ = require("gettext")
local json = require("json")

local TailscalePlugin = WidgetContainer:extend{
    name = "tailscale",
    is_doc_only = false,
}

-- ─── platform detection ───────────────────────────────────────────

function TailscalePlugin:detectArch()
    local handle = io.popen("uname -m 2>/dev/null")
    if handle then
        local machine = handle:read("*a") or ""
        handle:close()
        machine = machine:gsub("%s+$", "")
        if machine == "aarch64" or machine == "arm64" then
            return "arm64"
        end
    end
    return "arm"
end

function TailscalePlugin:init()
    logger.info("Tailscale plugin initializing")
    self.plugin_dir = DataStorage:getFullDataDir() .. "/plugins/tailscale.koplugin"

    if Device:isPocketBook() then
        self.ts_dir = "/mnt/ext1/tailscale"
    else
        self.ts_dir = self.plugin_dir
    end
    self.ts_arch = self:detectArch()
    self.ts_bin = self.ts_dir .. "/bin"
    logger.info("Tailscale: dir=" .. self.ts_dir .. " arch=" .. self.ts_arch)

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

-- ─── path helpers ─────────────────────────────────────────────────

function TailscalePlugin:getBinDir()
    return self.ts_bin
end

function TailscalePlugin:getAuthKeyPath()
    return self:getBinDir() .. "/auth.key"
end

function TailscalePlugin:getHeadscaleUrlPath()
    return self:getBinDir() .. "/headscale.url"
end

function TailscalePlugin:getLogPath()
    return self:getBinDir() .. "/tailscale.log"
end

-- ─── capability checks (Lua owns these, not shell) ────────────────

function TailscalePlugin:isRunning()
    local handle = io.popen("pgrep tailscaled 2>/dev/null")
    if not handle then return false end
    local result = handle:read("*a") or ""
    handle:close()
    return result ~= ""
end

function TailscalePlugin:binariesExist()
    local h = io.popen("test -f '" .. self.ts_bin .. "/tailscale' && test -f '"
        .. self.ts_bin .. "/tailscaled' && echo 'yes'")
    if not h then return false end
    local result = h:read("*a") or ""
    h:close()
    return result:match("yes") ~= nil
end

function TailscalePlugin:hasNetwork()
    local h = io.popen("ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && echo 'ok'")
    if not h then return false end
    local result = h:read("*a") or ""
    h:close()
    return result:match("ok") ~= nil
end

function TailscalePlugin:hasTunDevice()
    local h = io.popen("test -c /dev/net/tun && echo 'yes'")
    if not h then return false end
    local result = h:read("*a") or ""
    h:close()
    return result:match("yes") ~= nil
end

-- ─── state directory resolution (formerly shell logic) ────────────

function TailscalePlugin:resolveStateDir()
    -- Test if bin dir supports chmod; if so, use it directly.
    -- Otherwise, fall back to /tmp/tailscale (tmpfs).
    local test_file = self.ts_bin .. "/.chmod_test"
    local h = io.popen("touch '" .. test_file .. "' 2>/dev/null && chmod 0600 '" .. test_file .. "' 2>/dev/null && echo 'yes'")
    if h then
        local result = h:read("*a") or ""
        h:close()
        os.execute("rm -f '" .. test_file .. "' 2>/dev/null")
        if result:match("yes") then
            return self.ts_bin
        end
    end
    os.execute("rm -f '" .. test_file .. "' 2>/dev/null")

    -- Use tmpfs, copy existing state so node identity is preserved
    local tmpfs = "/tmp/tailscale"
    os.execute("mkdir -p '" .. tmpfs .. "' 2>/dev/null")
    for _, f in ipairs({"tailscaled.state", "tailscaled.log.conf"}) do
        os.execute("[ -f '" .. self.ts_bin .. "/" .. f .. "' ] && cp -f '"
            .. self.ts_bin .. "/" .. f .. "' '" .. tmpfs .. "/" .. f .. "' 2>/dev/null || true")
    end
    return tmpfs
end

-- ─── loopback setup (formerly shell logic) ────────────────────────

function TailscalePlugin:ensureLoopback()
    local h = io.popen("ifconfig lo 2>/dev/null | grep -q '127\\.0\\.0\\.1' && echo 'yes'")
    if h then
        local result = h:read("*a") or ""
        h:close()
        if result:match("yes") then return end
    end
    -- Bring up loopback — needed for SOCKS5/HTTP proxy binds
    os.execute("ifconfig lo 127.0.0.1 netmask 255.0.0.0 up 2>/dev/null || true")
    -- PocketBook NOPASSWD sudo
    os.execute("[ -x /ebrmain/cramfs/bin/sudo ] && /ebrmain/cramfs/bin/sudo /sbin/ifconfig lo 127.0.0.1 netmask 255.0.0.0 up 2>/dev/null || true")
    -- iproute2 fallback (reMarkable, Cervantes)
    os.execute("ip addr add 127.0.0.1/8 dev lo 2>/dev/null || true")
    os.execute("ip link set lo up 2>/dev/null || true")
end

-- ─── auth key / headscale url reading ─────────────────────────────

function TailscalePlugin:readAuthKey()
    local f = io.open(self:getAuthKeyPath(), "r")
    if not f then return nil end
    local key = f:read("*a") or ""
    f:close()
    key = key:gsub("%s+$", ""):gsub("^%s+", "")
    -- Accept Tailscale (tskey-) and Headscale (hskey-auth-) formats
    if key:match("^tskey%-") or key:match("^hskey%-auth%-") then
        return key
    end
    return nil
end

function TailscalePlugin:readHeadscaleUrl()
    for _, path in ipairs({self:getHeadscaleUrlPath(), self.plugin_dir .. "/headscale.url"}) do
        local f = io.open(path, "r")
        if f then
            local url = f:read("*a") or ""
            f:close()
            url = url:gsub("%s+$", "")
            if url ~= "" then return url end
        end
    end
    return nil
end

function TailscalePlugin:readHostname()
    local h = io.popen("'" .. self.ts_bin .. "/tailscale' status --json 2>/dev/null")
    if not h then return nil end
    local raw = h:read("*a") or ""
    h:close()
    local ok, parsed = pcall(function() return json.decode(raw) end)
    if ok and parsed and parsed.Self and parsed.Self.HostName then
        return parsed.Self.HostName
    end
    return nil
end

-- ─── command builders (Lua owns all flag decisions) ───────────────

function TailscalePlugin:buildDaemonCommand(state_dir)
    -- Build the tailscaled startup command.
    -- All flags decided here, passed to thin shell executor via env vars.
    local tun_flag = self:hasTunDevice() and "" or "--tun=userspace-networking"
    local cmd = "./tailscaled"
        .. " --statedir='" .. state_dir .. "/'"
        .. " --socks5-server=127.0.0.1:1055"
        .. " --outbound-http-proxy-listen=127.0.0.1:1056"
    if tun_flag ~= "" then
        cmd = cmd .. " " .. tun_flag
    end
    -- Env vars for shell executor
    self._daemon_cmd = cmd
    self._daemon_state_dir = state_dir
    self._daemon_tun_flag = tun_flag
end

function TailscalePlugin:buildUpCommand()
    -- Build the tailscale up command.
    -- Handles standard, headscale, auth key, hostname — all in one place.
    local flags = "--accept-routes --accept-dns=false --netfilter-mode=off"

    local hostname = self:readHostname()
    if hostname then
        flags = flags .. " --hostname='" .. hostname .. "'"
    end

    local headscale_url = self:readHeadscaleUrl()
    if headscale_url then
        flags = flags .. " --login-server='" .. headscale_url .. "'"
    end

    local auth_key = self:readAuthKey()
    if auth_key then
        flags = flags .. " --auth-key='" .. auth_key .. "'"
    end

    self._up_flags = flags
    self._up_auth_key = auth_key
    self._up_headscale_url = headscale_url
end

-- ─── thin shell executors ─────────────────────────────────────────

function TailscalePlugin:execStartScript()
    -- Shell script is a dumb executor — all decisions are already made.
    -- We pass everything through environment variables.
    local state_dir = self:resolveStateDir()
    self:ensureLoopback()
    self:buildDaemonCommand(state_dir)
    self:buildUpCommand()

    local env = "TS_BIN='" .. self.ts_bin .. "'"
        .. " TS_STATEDIR='" .. state_dir .. "'"
        .. " TS_TUN_FLAG='" .. (self._daemon_tun_flag or "") .. "'"
    if self._up_headscale_url then
        env = env .. " TS_LOGIN_SERVER='" .. self._up_headscale_url .. "'"
    end
    if self._up_auth_key then
        env = env .. " TS_AUTH_KEY='" .. self._up_auth_key .. "'"
    end
    env = env .. " TS_UP_FLAGS='" .. (self._up_flags or "") .. "'"
    env = env .. " TS_DIR='" .. self.ts_dir .. "'"

    os.execute(env .. " sh '" .. self.plugin_dir .. "/bin/start_tailscale.sh'")
end

function TailscalePlugin:execStopScript()
    os.execute("TS_BIN='" .. self.ts_bin .. "' sh '" .. self.plugin_dir .. "/bin/stop_tailscale.sh'")
end

function TailscalePlugin:execInstallScript()
    os.execute("TS_BIN='" .. self.ts_bin .. "' TS_ARCH='" .. self.ts_arch .. "' sh '"
        .. self.plugin_dir .. "/bin/install-tailscale.sh'")
end

function TailscalePlugin:execUninstallScript()
    os.execute("TS_BIN='" .. self.ts_bin .. "' sh '" .. self.plugin_dir .. "/bin/uninstall-tailscale.sh'")
end

-- ─── user-facing actions ──────────────────────────────────────────

function TailscalePlugin:onToggleTailscale(callback)
    if self:isRunning() then
        self:disconnectTailscale()
    else
        self:connectTailscale()
    end
    if callback then callback() end
end

function TailscalePlugin:onFlushSettings() end

function TailscalePlugin:addToMainMenu(menu_items)
    menu_items.tailscale = {
        text = _("Tailscale VPN"),
        sorting_hint = "network",
        sub_item_table = {
            {
                text = _("Tailscale VPN"),
                keep_menu_open = true,
                checked_func = function() return self:isRunning() end,
                callback = function(touchmenu_instance)
                    self:onToggleTailscale(function()
                        if touchmenu_instance and touchmenu_instance.updateItems then
                            touchmenu_instance:updateItems()
                        end
                    end)
                end,
            },
            { text = _("Status"), callback = function() self:showStatus() end },
            { text = _("Start/Stop Daemon"), callback = function() self:toggleDaemon() end },
            { text = _("Install/Update Tailscale"), callback = function() self:installTailscale() end },
            {
                text = _("Settings / Config"),
                sub_item_table = {
                    { text = _("Configure Auth Key"), callback = function() self:configureAuthKey() end },
                    { text = _("Headscale URL info"), callback = function() self:configureHeadscale() end },
                    { text = _("Uninstall Tailscale"), callback = function() self:uninstallTailscale() end },
                }
            }
        }
    }
end

-- ─── install ──────────────────────────────────────────────────────

function TailscalePlugin:installTailscale()
    if self:binariesExist() then
        UIManager:show(InfoMessage:new{
            text = _("Tailscale already installed.\nWould you like to check for updates?\nThis will download 57MB if update needed."),
            timeout = 5,
        })
        UIManager:scheduleIn(3, function()
            self.install_warning_msg = InfoMessage:new{
                text = _("Checking for updates...\nDownloading binaries (24MB+33MB)\nThis may take 5-10 minutes on slow WiFi.\nDO NOT CLOSE KOReader during installation."),
                timeout = 0,
            }
            UIManager:show(self.install_warning_msg)
            UIManager:forceRePaint()
            self:runInstallation()
        end)
        return
    end

    self.install_warning_msg = InfoMessage:new{
        text = _("Installing Tailscale...\nDownloading binaries (24MB+33MB)\nThis may take 5-10 minutes on slow WiFi.\nDO NOT CLOSE KOReader during installation."),
        timeout = 0,
    }
    UIManager:show(self.install_warning_msg)
    UIManager:forceRePaint()
    self:runInstallation()
end

function TailscalePlugin:runInstallation()
    local h = io.popen("TS_BIN='" .. self.ts_bin .. "' TS_ARCH='" .. self.ts_arch .. "' sh '"
        .. self.plugin_dir .. "/bin/install-tailscale.sh' 2>&1")
    if not h then
        if self.install_warning_msg then UIManager:close(self.install_warning_msg) end
        UIManager:show(InfoMessage:new{ text = _("Installation failed to start."), timeout = 6 })
        return
    end
    local result = h:read("*a") or ""
    h:close()

    if self.install_warning_msg then UIManager:close(self.install_warning_msg) end

    if result:match("Failed") or result:match("ERROR") then
        UIManager:show(InfoMessage:new{
            text = _("Installation failed.\n" .. result:sub(1, 200)),
            timeout = 8,
        })
        return
    end

    if self:binariesExist() then
        local daemon_running = self:isRunning()
        local msg = _("Installation complete!")
        if daemon_running then
            msg = msg .. _("\nDaemon auto-started.")
        else
            msg = msg .. _("\nAdd Auth Key + Start daemon to connect.")
        end
        UIManager:show(InfoMessage:new{ text = msg, timeout = 6 })
    else
        UIManager:show(InfoMessage:new{ text = _("Installation may have failed. Check logs."), timeout = 6 })
    end
end

-- ─── daemon control ───────────────────────────────────────────────

function TailscalePlugin:startDaemon()
    self:execStartScript()
    UIManager:show(InfoMessage:new{ text = _("Tailscale daemon started"), timeout = 2 })
end

function TailscalePlugin:stopDaemon()
    self:execStopScript()
    UIManager:show(InfoMessage:new{ text = _("Tailscale daemon stopped"), timeout = 2 })
end

function TailscalePlugin:toggleDaemon()
    if self:isRunning() then self:stopDaemon() else self:startDaemon() end
end

-- ─── connect / disconnect ─────────────────────────────────────────

function TailscalePlugin:connectTailscale()
    if not self:binariesExist() then
        UIManager:show(InfoMessage:new{
            text = _("Tailscale not installed.\nPlease run 'Install Tailscale' first."),
            timeout = 3,
        })
        return
    end
    if not self:hasNetwork() then
        UIManager:show(InfoMessage:new{
            text = _("No network connectivity.\nEnable WiFi before starting Tailscale."),
            timeout = 6,
        })
        return
    end
    self:execStartScript()
    UIManager:show(InfoMessage:new{
        text = _("Tailscale started\nCheck " .. self:getLogPath() .. " for status"),
        timeout = 4,
    })
end

function TailscalePlugin:disconnectTailscale()
    self:execStopScript()
    UIManager:show(InfoMessage:new{ text = _("Tailscale disconnected"), timeout = 2 })
end

-- ─── status ───────────────────────────────────────────────────────

function TailscalePlugin:showStatus()
    if not self:binariesExist() then
        UIManager:show(InfoMessage:new{
            text = _("Tailscale not installed."),
            timeout = 3,
        })
        return
    end

    local lines = {}
    table.insert(lines, self:isRunning() and "Daemon: Running" or "Daemon: Not running")

    local h = io.popen("'" .. self.ts_bin .. "/tailscale' status --json 2>/dev/null")
    if not h then
        UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n"), timeout = 8 })
        return
    end
    local jraw = h:read("*a") or ""
    h:close()

    local function join(tbl, sep)
        local s = ""
        for i, v in ipairs(tbl) do
            s = s .. (i > 1 and sep or "") .. tostring(v)
        end
        return s
    end

    if jraw ~= "" then
        local ok, parsed = pcall(function() return json.decode(jraw) end)
        if ok and type(parsed) == "table" then
            table.insert(lines, "State: " .. (parsed.BackendState or "Unknown"))
            if parsed.Self and type(parsed.Self) == "table" then
                local ips = parsed.Self.TailscaleIPs or {}
                if type(ips) == "table" and #ips > 0 then
                    table.insert(lines, "IPs: " .. join(ips, ", "))
                elseif type(ips) == "function" then
                    local ok2, result = pcall(ips)
                    if ok2 and type(result) == "table" and #result > 0 then
                        table.insert(lines, "IPs: " .. join(result, ", "))
                    end
                end
                if parsed.Self.HostName then
                    table.insert(lines, "Device: " .. tostring(parsed.Self.HostName))
                end
            end
        end
    else
        -- Fallback to terse commands
        local ip_h = io.popen("'" .. self.ts_bin .. "/tailscale' ip 2>/dev/null")
        if ip_h then
            local ips = (ip_h:read("*a") or ""):gsub("%s+$", "\n"):gsub("\n+", ", ")
            ip_h:close()
            if ips ~= "" then table.insert(lines, "IPs: " .. ips) end
        end
    end

    UIManager:show(InfoMessage:new{
        text = _("Tailscale Status:\n") .. table.concat(lines, "\n"),
        timeout = 8,
    })
end

-- ─── configuration ────────────────────────────────────────────────

function TailscalePlugin:configureAuthKey()
    local key = self:readAuthKey()
    if key then
        local display = key:sub(1, 12) .. "..."
        UIManager:show(InfoMessage:new{
            text = _("Auth key found: " .. display .. "\nRestart Tailscale to apply."),
            timeout = 4,
        })
    else
        UIManager:show(InfoMessage:new{
            text = _("No valid auth key found.\nEdit:\n" .. self:getAuthKeyPath()
                .. "\nAdd a Tailscale (tskey-) or Headscale (hskey-auth-) key."),
            timeout = 8,
        })
    end
end

function TailscalePlugin:configureHeadscale()
    local url = self:readHeadscaleUrl()
    if url then
        UIManager:show(InfoMessage:new{
            text = _("Headscale URL: " .. url .. "\nRemove " .. self:getHeadscaleUrlPath() .. " to disable."),
            timeout = 6,
        })
    else
        UIManager:show(InfoMessage:new{
            text = _("No Headscale URL configured.\nCreate " .. self:getHeadscaleUrlPath()
                .. "\nwith your Headscale server URL.\nSCP the file into place."),
            timeout = 8,
        })
    end
end

function TailscalePlugin:uninstallTailscale()
    UIManager:show(InfoMessage:new{
        text = _("Uninstalling Tailscale..."),
        timeout = 2,
    })
    self:execUninstallScript()
    UIManager:show(InfoMessage:new{
        text = _("Tailscale removed.\nRestart KOReader to finish."),
        timeout = 3,
    })
end

return TailscalePlugin
