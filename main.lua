local DataStorage = require("datastorage")
local Device = require("device")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local _ = require("gettext")
local util = require("util")
local json = require("json")

local TailscalePlugin = WidgetContainer:extend{
    name = "tailscale",
    is_doc_only = false,
}

function TailscalePlugin:init()
    logger.info("Tailscale plugin initializing")
    self.plugin_dir = DataStorage:getFullDataDir() .. "/plugins/tailscale.koplugin"
    self.is_running = false
    self.autosync_on_connect = G_reader_settings and G_reader_settings:isTrue("tailscale_autosync_on_connect") or false
    
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function TailscalePlugin:isRunning()
    -- Process check using pgrep if available
    local handle = io.popen("pgrep tailscaled 2>/dev/null")
    if handle then
        local result = handle:read("*a")
        handle:close()
        return result and result ~= ""
    end
    
    -- Fallback to grep if pgrep not available
    local ps_check = io.popen("ps aux | grep tailscaled | grep -v grep")
    local ps_result = ""
    if ps_check then
        ps_result = ps_check:read("*a")
        ps_check:close()
    end
    return ps_result and ps_result ~= ""
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
    -- Load settings if any
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
                text = _("Install/Update Tailscale"),
                callback = function()
                    self:installTailscale()
                end
            },
            {
                text = _("Configure Auth Key"),
                callback = function()
                    self:configureAuthKey()
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
end

function TailscalePlugin:installTailscale()
    -- First check if binaries already exist
    local bin_check = io.popen("test -f /mnt/us/tailscale/bin/tailscale && test -f /mnt/us/tailscale/bin/tailscaled && echo 'exists'")
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
    local cmd = self.plugin_dir .. "/bin/install-tailscale.sh"
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
    local bin_check = io.popen("ls -la /mnt/us/tailscale/bin/tailscale /mnt/us/tailscale/bin/tailscaled 2>/dev/null")
    local bin_result = ""
    if bin_check then
        bin_result = bin_check:read("*a")
        bin_check:close()
    end
    
    if bin_result and bin_result ~= "" then
        -- Check if daemon auto-started
        local ps_check = io.popen("ps aux | grep tailscaled | grep -v grep")
        local ps_result = ""
        if ps_check then
            ps_result = ps_check:read("*a")
            ps_check:close()
        end
        
        local message = _("Installation complete!\nTailscale binaries installed.")
        if ps_result and ps_result ~= "" then
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
    os.execute(self.plugin_dir .. "/bin/start_tailscale.sh")
    UIManager:show(InfoMessage:new{
        text = _("Tailscale daemon started"),
        timeout = 2
    })
end

function TailscalePlugin:connectTailscale()
    -- Quick binary existence check (faster than ls -la)
    local bin_check = io.popen("test -f /mnt/us/tailscale/bin/tailscale && test -f /mnt/us/tailscale/bin/tailscaled && echo 'exists'")
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
    
    os.execute(self.plugin_dir .. "/bin/start_tailscale.sh")
    UIManager:show(InfoMessage:new{
        text = _("Tailscale connection started\nCheck /mnt/us/tailscale/bin/tailscale.log for status"),
        timeout = 4
    })

    if self.autosync_on_connect then
        -- Give the daemon a few seconds to settle, then kick off sync
        UIManager:scheduleIn(5, function()
            self:syncNow()
        end)
    end
end

function TailscalePlugin:disconnectTailscale()
    os.execute(self.plugin_dir .. "/bin/stop_tailscale.sh")
    UIManager:show(InfoMessage:new{
        text = _("Tailscale disconnected"),
        timeout = 2
    })
end

function TailscalePlugin:showStatus()
    -- Quick binary existence check (faster than ls -la)
    local bin_check = io.popen("test -f /mnt/us/tailscale/bin/tailscale && test -f /mnt/us/tailscale/bin/tailscaled && echo 'exists'")
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
    local ps_check = io.popen("ps aux | grep tailscaled | grep -v grep")
    local ps_result = ""
    if ps_check then
        ps_result = ps_check:read("*a")
        ps_check:close()
    end

    local lines = {}
    table.insert(lines, (ps_result and ps_result ~= "") and "Daemon: Running" or "Daemon: Not running")

    -- Prefer JSON status to avoid noisy peers/health lines
    local jraw = nil
    local h = io.popen("/mnt/us/tailscale/bin/tailscale status --json 2>/dev/null")
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
        local ip_h = io.popen("/mnt/us/tailscale/bin/tailscale ip 2>/dev/null")
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
        local s_h = io.popen("/mnt/us/tailscale/bin/tailscale status --peers=false 2>/dev/null")
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
    local auth_check = io.popen("grep '^tskey-' /mnt/us/tailscale/bin/auth.key 2>/dev/null")
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
            text = _("No valid auth key found.\nPlease edit:\n/mnt/us/tailscale/bin/auth.key\nwith your Tailscale auth key\nGet from: login.tailscale.com/admin/settings/keys"),
            timeout = 8
        })
    end
end

function TailscalePlugin:uninstallTailscale()
    UIManager:show(InfoMessage:new{
        text = _("Uninstalling Tailscale...\nThis will remove all files and stop the service."),
        timeout = 3
    })
    
    os.execute(self.plugin_dir .. "/bin/uninstall-tailscale.sh")
    
    UIManager:show(InfoMessage:new{
        text = _("Uninstall complete!\nRestart KOReader to finish cleanup."),
        timeout = 3
    })
end

-- Sync utilities
function TailscalePlugin:syncNow()
    local conf_path = self.plugin_dir .. "/sync.conf"
    local f = io.open(conf_path, "r")
    if not f then
        UIManager:show(InfoMessage:new{ text = _("Sync not configured. Use 'Configure Sync Target' first."), timeout = 4 })
        return
    end
    f:close()

    local start_msg = InfoMessage:new{ text = _("Syncing books..."), timeout = 0 }
    UIManager:show(start_msg)
    UIManager:forceRePaint()

    local cmd = self.plugin_dir .. "/bin/sync_docs.sh"
    local handle = io.popen(cmd .. " 2>&1")
    local out = ""
    if handle then
        out = handle:read("*a") or ""
        handle:close()
    end

    if start_msg then UIManager:close(start_msg) end

    local n = out:match("SYNC_OK%s+(%d+)")
    if n then
        UIManager:show(InfoMessage:new{ text = string.format(_("Sync complete. %s files updated."), n), timeout = 4 })
    else
        UIManager:show(InfoMessage:new{ text = _("Sync completed."), timeout = 3 })
    end
end

function TailscalePlugin:configureSync()
    local conf_path = self.plugin_dir .. "/sync.conf"
    local exists = io.open(conf_path, "r")
    if exists then exists:close() end
    if not exists then
        local tpl = [[# Tailscale sync configuration
# Required
SYNC_HOST=
SYNC_USER=
REMOTE=/srv/books/export

# Optional
SYNC_PORT=22
LOCAL=/mnt/us/documents/Downloads/syncDocs
INCLUDES=*.epub,*.pdf,*.djvu,*.cbz,*.txt
# DELETE=true
# MODE=pull
]]
        local wf = io.open(conf_path, "w")
        if wf then
            wf:write(tpl)
            wf:close()
        end
    end

    UIManager:show(InfoMessage:new{
        text = _("Edit sync.conf with your server, user and paths:\n/mnt/us/koreader/plugins/tailscale.koplugin/sync.conf\nThen run 'Sync Books Now'."),
        timeout = 8
    })
end

return TailscalePlugin