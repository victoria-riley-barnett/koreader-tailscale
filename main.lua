local DataStorage = require("datastorage")
local Device = require("device")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local logger = require("logger")
local _ = require("gettext")
local json = require("json")
local Dispatcher = require("dispatcher")

local TailscalePlugin = WidgetContainer:extend{
    name = "tailscale",
    is_doc_only = false,
    http_proxy_url = "http://127.0.0.1:1056",
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

-- Derive the plugin dir from this module's own path. The DataStorage
-- default is wrong when KOReader loads plugins via extra_plugin_paths
-- (reMarkable), which is why we probe instead of assuming (#35).
function TailscalePlugin:detectPluginDir()
    local src = debug.getinfo(1, "S").source or ""
    local dir = src:gsub("^@", ""):gsub("/main%.lua$", "")
    if dir:sub(1, 1) ~= "/" then
        -- Loader used a relative path; anchor it to the data dir.
        dir = DataStorage:getFullDataDir() .. "/" .. dir
    end
    local probe = io.open(dir .. "/bin/start_tailscale.sh", "r")
    if probe then
        probe:close()
        return dir
    end
    -- Fall back to the standard location if the derived dir has no scripts.
    return DataStorage:getFullDataDir() .. "/plugins/tailscale.koplugin"
end

function TailscalePlugin:init()
    logger.info("Tailscale plugin initializing")
    self.plugin_dir = self:detectPluginDir()

    if Device:isPocketBook() then
        self.ts_dir = "/mnt/ext1/tailscale"
    else
        self.ts_dir = self.plugin_dir
    end
    self.ts_arch = self:detectArch()
    self.ts_bin = self.ts_dir .. "/bin"
    logger.info("Tailscale: dir=" .. self.ts_dir .. " arch=" .. self.ts_arch)

    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/tailscale.lua")
    self.settings:readSetting("use_exit_node", false)
    self.settings:readSetting("exit_node", "")
    self.settings:readSetting("auto_http_proxy", false)
    self.settings:readSetting("http_proxy_backup_active", false)

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- Register a Dispatcher action so the toggle appears under "System action..."
    Dispatcher:registerAction("toggle_tailscale_vpn",
      { category = "none", event = "ToggleTailscale", title = _("Toggle Tailscale VPN"), general = true })

    self:installUSBMSHook()
    self:resumeAfterUSBMS()
end

--- Stop Tailscale before KOReader enters USB storage mode, then auto-restart afterwards.
-- KOReader signals USB storage mode by calling UIManager:quit(86) (KO_RC_USBMS); that exit
-- code is used nowhere else, so it is a reliable, USB-specific trigger. tailscaled runs from
-- the partition KOReader wants to export, so it keeps the filesystem busy and must be killed.
-- We wrap UIManager.quit once (it is a singleton, and the plugin is re-instantiated for both
-- ReaderUI and FileManager). The closure captures device-stable paths, not a plugin instance.
function TailscalePlugin:installUSBMSHook()
    if UIManager._tailscale_usbms_hook then
        return
    end
    UIManager._tailscale_usbms_hook = true

    local ts_bin = self.ts_bin
    local plugin_dir = self.plugin_dir
    local marker = self:getRestartMarkerPath()
    local orig_quit = UIManager.quit
    UIManager.quit = function(uimgr, exit_code, ...)
        if exit_code == 86 then -- KO_RC_USBMS
            -- Standalone pgrep so this does not depend on a plugin instance.
            local handle = io.popen("pgrep tailscaled 2>/dev/null")
            local running = handle and handle:read("*a") or ""
            if handle then handle:close() end
            if running ~= "" then
                logger.info("Tailscale plugin: stopping tailscaled before USB storage mode")
                local f = io.open(marker, "w")
                if f then
                    f:write("1")
                    f:close()
                end
                -- Synchronous: the filesystem must be free before the USBMS tool unmounts it.
                os.execute("TS_BIN='" .. ts_bin .. "' sh '" .. plugin_dir .. "/bin/stop_tailscale.sh'")
            end
        end
        return orig_quit(uimgr, exit_code, ...)
    end
end

--- After returning from a USB storage session, KOReader restarts cold (no resume event),
-- so we detect the marker left by the quit(86) hook and bring Tailscale back up.
function TailscalePlugin:resumeAfterUSBMS()
    local marker = self:getRestartMarkerPath()
    local mf = io.open(marker, "r")
    if not mf then
        return
    end
    mf:close()
    os.remove(marker)
    logger.info("Tailscale plugin: restarting Tailscale after USB storage session")
    -- Deferred so we don't block UI startup (start_tailscale.sh sleeps ~2s).
    UIManager:scheduleIn(2, function()
        self:connectTailscale()
    end)
end

-- ─── path helpers ─────────────────────────────────────────────────

function TailscalePlugin:getBinDir()
    return self.ts_bin
end

function TailscalePlugin:getAuthKeyPath()
    return self:getBinDir() .. "/auth.key"
end

function TailscalePlugin:getRestartMarkerPath()
    return self:getBinDir() .. "/restart_after_usbms"
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
    local h = io.popen("test -c /dev/net/tun && test -r /dev/net/tun && test -w /dev/net/tun && echo 'yes'")
    if not h then return false end
    local result = h:read("*a") or ""
    h:close()
    return result:match("yes") ~= nil
end

function TailscalePlugin:isUserspaceForced()
    local f = io.open(self:getBinDir() .. "/force-userspace", "r")
    if not f then return false end
    f:close()
    return true
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
    -- Scan lines for a valid key, skipping comments and blank lines
    for raw_line in f:lines() do
        local line = raw_line:gsub("^%s+", ""):gsub("%s+$", "")
        -- Skip comment lines (#) and blanks
        if line ~= "" and not line:match("^#") then
            -- Accept Tailscale (tskey-) and Headscale (hskey-auth-) formats
            if line:match("^tskey%-") or line:match("^hskey%-auth%-") then
                f:close()
                return line
            end
        end
    end
    f:close()
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

-- ─── command builders (Lua owns all flag decisions) ───────────────

function TailscalePlugin:resolveTunFlag()
    -- Prefer a usable kernel TUN device, with an escape hatch for unstable
    -- e-reader kernels. Pass both the flag and selected mode to the executor.
    if self:isUserspaceForced() then
        self._tun_flag = "--tun=userspace-networking"
        self._network_mode = "userspace (forced)"
    elseif self:hasTunDevice() then
        self._tun_flag = "--tun=tailscale0"
        self._network_mode = "kernel TUN"
    else
        self._tun_flag = "--tun=userspace-networking"
        self._network_mode = "userspace (no usable /dev/net/tun)"
    end
end

function TailscalePlugin:buildUpCommand()
    -- Build core flags only. Auth key, login-server, and hostname are
    -- deferred to the shell script (needs running daemon for hostname,
    -- and shell owns command reconstruction for the retry path).
    self._up_flags = "--accept-routes --accept-dns=false --netfilter-mode=off"
    self._up_auth_key = self:readAuthKey()
    self._up_headscale_url = self:readHeadscaleUrl()
end

-- ─── thin shell executors ─────────────────────────────────────────

function TailscalePlugin:flushSettings()
    if self.settings then
        self.settings:flush()
    end
end

function TailscalePlugin:shellQuote(value)
    value = tostring(value or "")
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

function TailscalePlugin:getStartEnvironment(state_dir)
    -- All decisions are made here in Lua and passed to the shell via env vars.
    local env = "TS_BIN=" .. self:shellQuote(self.ts_bin)
        .. " TS_STATEDIR=" .. self:shellQuote(state_dir)
        .. " TS_TUN_FLAG=" .. self:shellQuote(self._tun_flag or "")
        .. " TS_NETWORK_MODE=" .. self:shellQuote(self._network_mode or "unknown")
        .. " TS_UP_FLAGS=" .. self:shellQuote(self._up_flags or "")
        .. " TS_DIR=" .. self:shellQuote(self.ts_dir)
    if self._up_headscale_url then
        env = env .. " TS_LOGIN_SERVER=" .. self:shellQuote(self._up_headscale_url)
    end
    if self._up_auth_key then
        env = env .. " TS_AUTH_KEY=" .. self:shellQuote(self._up_auth_key)
    end
    if self.settings and self.settings:readSetting("use_exit_node") then
        local exit_node = (self.settings:readSetting("exit_node") or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if exit_node ~= "" then
            env = env .. " USE_EXIT_NODE=1 EXIT_NODE=" .. self:shellQuote(exit_node)
        end
    end
    return env
end

function TailscalePlugin:execStartScript()
    -- Shell script is a dumb executor — all decisions are already made.
    local state_dir = self:resolveStateDir()
    self:ensureLoopback()
    self:resolveTunFlag()
    self:buildUpCommand()

    local env = self:getStartEnvironment(state_dir)
    local ok, _, code = os.execute(env .. " sh '" .. self.plugin_dir .. "/bin/start_tailscale.sh'")
    return ok == true and code == 0
end

function TailscalePlugin:execStopScript()
    os.execute("TS_BIN='" .. self.ts_bin .. "' sh '" .. self.plugin_dir .. "/bin/stop_tailscale.sh'")
end

function TailscalePlugin:execInstallScript()
    -- Returns io.popen handle so caller can capture output
    return io.popen("TS_BIN='" .. self.ts_bin .. "' TS_ARCH='" .. self.ts_arch .. "' sh '"
        .. self.plugin_dir .. "/bin/install-tailscale.sh' 2>&1")
end

function TailscalePlugin:execUninstallScript()
    os.execute("TS_BIN='" .. self.ts_bin .. "' sh '" .. self.plugin_dir .. "/bin/uninstall-tailscale.sh'")
end

-- ─── HTTP proxy management ────────────────────────────────────────

function TailscalePlugin:getNetworkManager()
    local ok, network_mgr = pcall(require, "ui/network/manager")
    if ok then
        return network_mgr
    end
    logger.warn("Tailscale plugin: failed to load NetworkMgr for HTTP proxy management")
    return nil
end

function TailscalePlugin:saveHTTPProxyBackup()
    if self.settings:readSetting("http_proxy_backup_active") then
        return
    end

    self.settings:saveSetting("http_proxy_backup_enabled", G_reader_settings:readSetting("http_proxy_enabled") and true or false)
    self.settings:saveSetting("http_proxy_backup_value", G_reader_settings:readSetting("http_proxy") or "")
    self.settings:saveSetting("http_proxy_backup_active", true)
    self:flushSettings()
end

function TailscalePlugin:enableHTTPProxyIfNeeded()
    if not self.settings:readSetting("auto_http_proxy") then
        return
    end

    local network_mgr = self:getNetworkManager()
    if not network_mgr or not network_mgr.setHTTPProxy then
        UIManager:show(InfoMessage:new{
            text = _("Tailscale connected, but KOReader HTTP proxy could not be configured."),
            timeout = 5
        })
        return
    end

    self:saveHTTPProxyBackup()
    local ok = pcall(function()
        network_mgr:setHTTPProxy(self.http_proxy_url)
    end)
    if not ok then
        self:restoreHTTPProxyBackup(true)
        UIManager:show(InfoMessage:new{
            text = _("Tailscale connected, but KOReader HTTP proxy could not be configured."),
            timeout = 5
        })
    end
end

function TailscalePlugin:restoreHTTPProxyBackup(silent)
    if not self.settings:readSetting("http_proxy_backup_active") then
        return
    end

    local network_mgr = self:getNetworkManager()
    if not network_mgr or not network_mgr.setHTTPProxy then
        if not silent then
            UIManager:show(InfoMessage:new{
                text = _("Tailscale disconnected, but KOReader HTTP proxy could not be restored."),
                timeout = 5
            })
        end
        return
    end

    local backup_enabled = self.settings:readSetting("http_proxy_backup_enabled")
    local backup_value = self.settings:readSetting("http_proxy_backup_value") or ""
    local ok = pcall(function()
        if backup_enabled and backup_value ~= "" then
            network_mgr:setHTTPProxy(backup_value)
        else
            network_mgr:setHTTPProxy(nil)
        end
    end)

    if ok then
        self.settings:saveSetting("http_proxy_backup_active", false)
        self.settings:delSetting("http_proxy_backup_enabled")
        self.settings:delSetting("http_proxy_backup_value")
        self:flushSettings()
    elseif not silent then
        UIManager:show(InfoMessage:new{
            text = _("Tailscale disconnected, but KOReader HTTP proxy could not be restored."),
            timeout = 5
        })
    end
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

function TailscalePlugin:onFlushSettings()
    self:flushSettings()
end

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
            { text = _("Install/Update Tailscale"), callback = function() self:installTailscale() end },
            {
                text = _("Settings / Config"),
                sub_item_table = {
                    { text = _("Configure Auth Key"), callback = function() self:configureAuthKey() end },
                    { text = _("Headscale URL info"), callback = function() self:configureHeadscale() end },
                    {
                        text = _("Enable exit node"),
                        keep_menu_open = true,
                        checked_func = function()
                            return self.settings and self.settings:readSetting("use_exit_node")
                        end,
                        callback = function(touchmenu_instance)
                            self.settings:saveSetting("use_exit_node", not self.settings:readSetting("use_exit_node"))
                            self:flushSettings()
                            if touchmenu_instance and touchmenu_instance.updateItems then
                                touchmenu_instance:updateItems()
                            end
                        end
                    },
                    {
                        text_func = function()
                            local exit_node = self.settings and self.settings:readSetting("exit_node") or ""
                            if exit_node and exit_node ~= "" then
                                return _("Exit node") .. ": " .. exit_node
                            end
                            return _("Exit node")
                        end,
                        callback = function()
                            self:configureExitNode()
                        end
                    },
                    {
                        text = _("Automatically configure HTTP proxy"),
                        keep_menu_open = true,
                        checked_func = function()
                            return self.settings and self.settings:readSetting("auto_http_proxy")
                        end,
                        callback = function(touchmenu_instance)
                            self.settings:saveSetting("auto_http_proxy", not self.settings:readSetting("auto_http_proxy"))
                            self:flushSettings()
                            if touchmenu_instance and touchmenu_instance.updateItems then
                                touchmenu_instance:updateItems()
                            end
                        end
                    },
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
    local h = self:execInstallScript()
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
            msg = msg .. _("\nTailscale auto-started.")
        else
            msg = msg .. _("\nAdd an auth key, then toggle Tailscale on to connect.")
        end
        UIManager:show(InfoMessage:new{ text = msg, timeout = 6 })
    else
        UIManager:show(InfoMessage:new{ text = _("Installation may have failed. Check logs."), timeout = 6 })
    end
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

    -- Show a persistent message before the blocking call so the user knows
    -- why the UI is unresponsive while Tailscale is coming up.
    local starting_msg = InfoMessage:new{
        text = _("Starting Tailscale...\nThis may take a moment."),
        timeout = 0  -- persistent until dismissed explicitly
    }
    UIManager:show(starting_msg)
    UIManager:forceRePaint()

    local ok = self:execStartScript()

    UIManager:close(starting_msg)
    if ok then
        self:enableHTTPProxyIfNeeded()
        UIManager:show(InfoMessage:new{
            text = _("Tailscale started\nCheck " .. self:getLogPath() .. " for status"),
            timeout = 4,
        })
    else
        UIManager:show(InfoMessage:new{
            text = _("Failed to start Tailscale.\nCheck " .. self:getLogPath() .. " for the error."),
            timeout = 6,
        })
    end
end

function TailscalePlugin:disconnectTailscale()
    self:execStopScript()
    self:restoreHTTPProxyBackup()
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
    table.insert(lines, self:isRunning() and "Tailscale: Running" or "Tailscale: Not running")

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

function TailscalePlugin:configureExitNode()
    local exit_node = self.settings and self.settings:readSetting("exit_node") or ""
    local dialog
    dialog = InputDialog:new{
        title = _("Exit node"),
        input = exit_node or "",
        input_hint = _("Hostname, MagicDNS name, or Tailscale IP"),
        description = _("Route traffic through this Tailscale exit node when enabled."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local value = dialog:getInputText() or ""
                        value = value:gsub("^%s+", ""):gsub("%s+$", "")
                        self.settings:saveSetting("exit_node", value)
                        self:flushSettings()
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new{
                            text = _("Exit node saved. Restart Tailscale to apply."),
                            timeout = 3
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
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
