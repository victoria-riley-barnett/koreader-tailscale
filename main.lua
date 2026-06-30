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

local TailscalePlugin = WidgetContainer:extend{
    name = "tailscale",
    is_doc_only = false,
    http_proxy_url = "http://127.0.0.1:1056",
}

--- Detect CPU architecture for Tailscale binary download.
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
    -- Default to 32-bit ARM (covers armv7l, armv6l, etc.)
    return "arm"
end

--- Detect device platform and return base tailscale directory and arch.
function TailscalePlugin:detectPlatform()
    local arch = self:detectArch()
    if Device:isPocketBook() then
        -- PocketBook: external storage (plugin directory may be read-only)
        return "/mnt/ext1/tailscale", arch
    end
    -- Default: plugin directory (writable for Kindle/Kobo)
    return self.plugin_dir, arch
end

function TailscalePlugin:init()
    logger.info("Tailscale plugin initializing")
    self.plugin_dir = DataStorage:getFullDataDir() .. "/plugins/tailscale.koplugin"
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/tailscale.lua")
    self.settings:readSetting("use_exit_node", false)
    self.settings:readSetting("exit_node", "")
    self.settings:readSetting("auto_http_proxy", false)
    self.settings:readSetting("http_proxy_backup_active", false)
    
    -- Detect platform-specific paths
    self.ts_dir, self.ts_arch = self:detectPlatform()
    self.ts_bin = self.ts_dir .. "/bin"
    logger.info("Tailscale plugin: device dir=" .. self.ts_dir .. " arch=" .. self.ts_arch)
    
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function TailscalePlugin:flushSettings()
    if self.settings then
        self.settings:flush()
    end
end

function TailscalePlugin:shellQuote(value)
    value = tostring(value or "")
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

function TailscalePlugin:getStartEnvironment()
    local env = "TS_DIR=" .. self:shellQuote(self.ts_dir)
    if self.settings and self.settings:readSetting("use_exit_node") then
        local exit_node = self.settings:readSetting("exit_node") or ""
        exit_node = exit_node:gsub("^%s+", ""):gsub("%s+$", "")
        if exit_node ~= "" then
            env = env .. " USE_EXIT_NODE=1 EXIT_NODE=" .. self:shellQuote(exit_node)
        end
    end
    return env
end

function TailscalePlugin:commandSucceeded(ok, reason, code)
    if ok == true then
        return true
    end
    if ok == 0 then
        return true
    end
    if reason == "exit" and code == 0 then
        return true
    end
    return false
end

function TailscalePlugin:runStartScript(script)
    local ok, reason, code = os.execute(self:getStartEnvironment() .. " " .. self:shellQuote(script))
    return self:commandSucceeded(ok, reason, code)
end

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

function TailscalePlugin:getDaemonLogPath()
    return self:getBinDir() .. "/tailscaled.log"
end

function TailscalePlugin:isRunning()
    -- Use pgrep for a simple, fast check. Return boolean.
    local handle = io.popen("pgrep tailscaled 2>/dev/null")
    if not handle then
        return false
    end
    local result = handle:read("*a")
    handle:close()
    return result and result ~= ""
end

function TailscalePlugin:onToggleTailscale(callback)
    if self:isRunning() then
        self:disconnectTailscale()
    else
        self:connectTailscale()
    end
    if callback then
        callback()
    end
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
                checked_func = function() 
                    return self:isRunning() 
                end,
                callback = function(touchmenu_instance)
                    self:onToggleTailscale(function()
                        if touchmenu_instance and touchmenu_instance.updateItems then
                            touchmenu_instance:updateItems()
                        end
                    end)
                end,
            },
            {
                text = _("Status"),
                callback = function()
                    self:showStatus()
                end
            },
            {
                text = _("Start/Stop Daemon"),
                callback = function()
                    self:toggleDaemon()
                end
            },
            {
                text = _("Install/Update Tailscale"),
                callback = function()
                    self:installTailscale()
                end
            },
            {
                text = _("Settings / Config"),
                sub_item_table = {
                    {
                        text = _("Configure Auth Key"),
                        callback = function()
                            self:configureAuthKey()
                        end
                    },
                    {
                        text = _("Headscale URL info"),
                        callback = function()
                            self:configureHeadscale()
                        end
                    },
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
                    {
                        text = _("Start with Headscale"),
                        callback = function()
                            -- Ensure a Headscale URL is configured before attempting to start
                            local cfg_path = self.plugin_dir .. "/headscale.url"
                            local system_path = self:getHeadscaleUrlPath()
                            local val = nil
                            local f = io.open(cfg_path, "r")
                            if not f then f = io.open(system_path, "r") end
                            if f then
                                val = f:read("*a") or ""
                                f:close()
                                val = val:gsub("%s+$", "")
                            end

                            if not val or val == "" then
                                UIManager:show(InfoMessage:new{
                                    text = _("No Headscale URL configured. Open 'Headscale URL info' to add one before starting."),
                                    timeout = 6
                                })
                                return
                            end

                            local script = self.plugin_dir .. "/bin/start_tailscale_headscale.sh"
                            local s = io.open(script, "r")
                            if s then
                                s:close()
                                if self:runStartScript(script) then
                                    self:enableHTTPProxyIfNeeded()
                                end
                                UIManager:show(InfoMessage:new{
                                    text = _("Started Tailscale (Headscale)"),
                                    timeout = 3
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("Headscale start script not found. Place start_tailscale_headscale.sh in plugin bin/"),
                                    timeout = 6
                                })
                            end
                        end
                    },
                    {
                        text = _("Uninstall Tailscale"),
                        callback = function()
                            self:uninstallTailscale()
                        end
                    }
                }
            }
        }
    }
end

function TailscalePlugin:installTailscale()
    -- First check if binaries already exist
    local bin_dir = self:getBinDir()
    local bin_check = io.popen("test -f '" .. bin_dir .. "/tailscale' && test -f '" .. bin_dir .. "/tailscaled' && echo 'exists'")
    local bin_result = ""
    if bin_check then
        bin_result = bin_check:read("*a")
        bin_check:close()
    end
    
    if bin_result and bin_result ~= "" then
        -- Binaries exist, ask if user wants to update
        UIManager:show(InfoMessage:new{
            text = _("Tailscale already installed.\nWould you like to check for updates?\nThis will download 57MB if update needed."),
            timeout = 5
        })
        
        -- Small delay to let user read the message
        local function proceedWithUpdate()
            -- Show persistent warning about long operation
            self.install_warning_msg = InfoMessage:new{
                text = _("Checking for updates...\nDownloading binaries (24MB+33MB)\nThis may take 5-10 minutes on slow WiFi.\nDO NOT CLOSE KOReader during installation."),
                timeout = 0  -- 0 means persistent until dismissed
            }
            UIManager:show(self.install_warning_msg)
            
            -- Force UI update to ensure message is visible
            UIManager:forceRePaint()
            
            -- Run installation/update
            self:runInstallation()
        end
        
        -- Use a timer to proceed after message is displayed
        UIManager:scheduleIn(3, proceedWithUpdate)
        return
    else
        -- No binaries exist, proceed with fresh installation
        -- Show persistent warning about long operation
        self.install_warning_msg = InfoMessage:new{
            text = _("Installing Tailscale...\nDownloading binaries (24MB+33MB)\nThis may take 5-10 minutes on slow WiFi.\nDO NOT CLOSE KOReader during installation."),
            timeout = 0  -- 0 means persistent until dismissed
        }
        UIManager:show(self.install_warning_msg)
        
        -- Force UI update to ensure message is visible
        UIManager:forceRePaint()
        
        -- Run installation
        self:runInstallation()
    end
end

function TailscalePlugin:runInstallation()
    -- Run installation and capture output with timeout
    local result = ""
    local success = false
    
    -- Use a more robust execution method with timeout
    local cmd = "TS_DIR=" .. self.ts_dir .. " " .. self.plugin_dir .. "/bin/install-tailscale.sh"
    local handle = io.popen(cmd .. " 2>&1")
    if handle then
        result = handle:read("*a")
        handle:close()
        success = true
    end
    
    -- Check if installation was interrupted
    if not success or result:match("Failed") or result:match("ERROR") then
        -- Dismiss the persistent warning and show error message
        if self.install_warning_msg then
            UIManager:close(self.install_warning_msg)
        end
        UIManager:show(InfoMessage:new{
            text = _("Installation failed or interrupted.\nCheck SSH logs or try manual download.\nError: " .. (result:sub(1, 100) or "unknown")),
            timeout = 6
        })
        return
    end
    
    -- Check if binaries were actually installed
    local bin_check = io.popen("ls -la '" .. self:getBinDir() .. "/tailscale' '" .. self:getBinDir() .. "/tailscaled' 2>/dev/null")
    local bin_result = ""
    if bin_check then
        bin_result = bin_check:read("*a")
        bin_check:close()
    end
    
    if bin_result and bin_result ~= "" then
        -- Check if daemon auto-started
        local daemon_running = self:isRunning()

        local message = _("Installation complete!\nTailscale binaries installed.")
        if daemon_running then
            message = message .. _("\nDaemon auto-started.")
        else
            message = message .. _("\nAdd Auth Key + Start daemon to connect.")
        end
        
        -- Dismiss the persistent warning and show completion message
        if self.install_warning_msg then
            UIManager:close(self.install_warning_msg)
        end
        UIManager:show(InfoMessage:new{
            text = message,
            timeout = 6
        })
    else
        -- Dismiss the persistent warning and show error message
        if self.install_warning_msg then
            UIManager:close(self.install_warning_msg)
        end
        UIManager:show(InfoMessage:new{
            text = _("Installation may have failed.\nCheck SSH for details or try manual download."),
            timeout = 6
        })
    end
end

function TailscalePlugin:startDaemon()
    -- Start full Tailscale (daemon + CLI connect) quietly
    if self:runStartScript(self.plugin_dir .. "/bin/start_tailscale.sh") then
        self:enableHTTPProxyIfNeeded()
    end
    UIManager:show(InfoMessage:new{
        text = _("Tailscale daemon started"),
        timeout = 2
    })
end


function TailscalePlugin:stopDaemon()
    -- Stop full Tailscale (daemon + CLI connect) quietly
    os.execute("TS_DIR=" .. self.ts_dir .. " " .. self.plugin_dir .. "/bin/stop_tailscale.sh")
    UIManager:show(InfoMessage:new{
        text = _("Tailscale daemon stopped"),
        timeout = 2
    })
end

function TailscalePlugin:toggleDaemon()
    -- Convenience method to toggle full Tailscale (daemon + CLI connect) status --
    if self:isRunning() then
        self:stopDaemon()
    else
        self:startDaemon()
    end
end

function TailscalePlugin:connectTailscale()
    -- Quick binary existence check (faster than ls -la)
    local bin_check = io.popen("test -f '" .. self:getBinDir() .. "/tailscale' && test -f '" .. self:getBinDir() .. "/tailscaled' && echo 'exists'")
    local bin_result = ""
    if bin_check then
        bin_result = bin_check:read("*a")
        bin_check:close()
    end
    
    if not bin_result or bin_result == "" then
        UIManager:show(InfoMessage:new{
            text = _("Tailscale not installed.\nPlease run Install Tailscale first."),
            timeout = 3
        })
        return
    end
    
    if self:runStartScript(self.plugin_dir .. "/bin/start_tailscale.sh") then
        self:enableHTTPProxyIfNeeded()
    end
    UIManager:show(InfoMessage:new{
        text = _("Tailscale connection started\nCheck " .. self:getLogPath() .. " for status"),
        timeout = 4
    })

    -- autosync-on-connect removed: sync must be triggered manually if desired
end

function TailscalePlugin:disconnectTailscale()
    os.execute("TS_DIR=" .. self:shellQuote(self.ts_dir) .. " " .. self:shellQuote(self.plugin_dir .. "/bin/stop_tailscale.sh"))
    self:restoreHTTPProxyBackup()
    UIManager:show(InfoMessage:new{
        text = _("Tailscale disconnected"),
        timeout = 2
    })
end

function TailscalePlugin:showStatus()
    -- Quick binary existence check (faster than ls -la)
    local bin_check = io.popen("test -f '" .. self:getBinDir() .. "/tailscale' && test -f '" .. self:getBinDir() .. "/tailscaled' && echo 'exists'")
    local bin_result = ""
    if bin_check then
        bin_result = bin_check:read("*a")
        bin_check:close()
    end

    if not bin_result or bin_result == "" then
        UIManager:show(InfoMessage:new{
            text = _("Tailscale not installed.\nPlease run Install Tailscale first."),
            timeout = 3
        })
        return
    end

    -- Check if daemon is running
    local daemon_running = self:isRunning()

    local lines = {}
    table.insert(lines, daemon_running and "Daemon: Running" or "Daemon: Not running")

    -- Prefer JSON status to avoid noisy peers/health lines
    local jraw = nil
    local h = io.popen("'" .. self:getBinDir() .. "/tailscale' status --json 2>/dev/null")
    if h then
        jraw = h:read("*a")
        h:close()
    end

    local function join(tbl, sep)
        local s = ""
        for i, v in ipairs(tbl) do
            s = s .. (i > 1 and sep or "") .. tostring(v)
        end
        return s
    end

    local parsed
    if jraw and jraw ~= "" then
        local ok, obj = pcall(function() return json.decode(jraw) end)
        if ok and type(obj) == "table" then
            parsed = obj
        end
    end

    if parsed and type(parsed) == "table" then
        local backend = parsed.BackendState or "Unknown"
        table.insert(lines, "State: " .. backend)
        if parsed.Self and type(parsed.Self) == "table" then
            local ips = parsed.Self.TailscaleIPs or {}
            if #ips > 0 then
                table.insert(lines, "IPs: " .. join(ips, ", "))
            end
            if parsed.Self.HostName then
                table.insert(lines, "Device: " .. tostring(parsed.Self.HostName))
            end
        end
    else
        -- Fallback: use terse commands without peers
        local ip_h = io.popen("'" .. self:getBinDir() .. "/tailscale' ip 2>/dev/null")
        if ip_h then
            local ips = ip_h:read("*a") or ""
            ip_h:close()
            ips = ips:gsub("%s+$", "")
            if ips ~= "" then
                ips = ips:gsub("\n+", ", ")
                table.insert(lines, "IPs: " .. ips)
            end
        end
        -- Try to get a simple state without peers/health
        local s_h = io.popen("'" .. self:getBinDir() .. "/tailscale' status --peers=false 2>/dev/null")
        if s_h then
            local s = s_h:read("*a") or ""
            s_h:close()
            -- Remove known noisy lines if any slipped through
            local filtered = {}
            for line in s:gmatch("[^\r\n]+") do
                if not line:match("health") and not line:match("logtail") and not line:match("control:") then
                    table.insert(filtered, line)
                end
            end
            if #filtered > 0 then
                table.insert(lines, table.concat(filtered, "\n"))
            end
        end
    end

    UIManager:show(InfoMessage:new{
        text = _("Tailscale Status:\n") .. table.concat(lines, "\n"),
        timeout = 8
    })
end

function TailscalePlugin:configureAuthKey()
    -- Check current auth key status
    local auth_check = io.popen("grep '^tskey-' '" .. self:getAuthKeyPath() .. "' 2>/dev/null")
    local auth_result = ""
    if auth_check then
        auth_result = auth_check:read("*a")
        auth_check:close()
    end
    
    if auth_result and auth_result ~= "" then
        UIManager:show(InfoMessage:new{
            text = _("Auth key configured!\nRestart Tailscale to apply."),
            timeout = 4
        })
    else
        UIManager:show(InfoMessage:new{
            text = _("No valid auth key found.\nPlease edit:\n" .. self:getAuthKeyPath() .. "\nwith your Tailscale auth key\nGet from: login.tailscale.com/admin/settings/keys"),
            timeout = 8
        })
    end
end

function TailscalePlugin:configureHeadscale()
    local cfg_path = self.plugin_dir .. "/headscale.url"
    local system_path = self:getHeadscaleUrlPath()

    -- Try to read existing value
    local f = io.open(cfg_path, "r")
    local val = nil
    if not f then
        -- try system location
        f = io.open(system_path, "r")
    end
    if f then
        val = f:read("*a") or ""
        f:close()
        val = val:gsub("%s+$", "")
    end

    if val and val ~= "" then
        UIManager:show(InfoMessage:new{
            text = string.format(_("Headscale URL is set to:\n%s\n\nTo change it, edit:\n%s\nor\n%s (scp/ssh)"), val, cfg_path, system_path),
            timeout = 6
        })
        return
    end

    UIManager:show(InfoMessage:new{
        text = _("No Headscale URL configured.\nTo set one, create the file:\n" .. self:getHeadscaleUrlPath() .. "\ncontaining the full URL (eg. https://headscale.example.com)\nYou can SCP the file into place from your workstation."),
        timeout = 8
    })
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
        text = _("Uninstalling Tailscale...\nThis will remove all files and stop the service."),
        timeout = 3
    })
    
    os.execute("TS_DIR=" .. self.ts_dir .. " " .. self.plugin_dir .. "/bin/uninstall-tailscale.sh")
    
    UIManager:show(InfoMessage:new{
        text = _("Uninstall complete!\nRestart KOReader to finish cleanup."),
        timeout = 3
    })
end

return TailscalePlugin
