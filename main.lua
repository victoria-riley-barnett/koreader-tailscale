local DataStorage = require("datastorage")
local Device = require("device")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
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

-- Login handshake: the daemon answers `tailscale status --json` immediately
-- while it waits for a login, so we poll instead of blocking on `tailscale up`.
local LOGIN_POLL_INTERVAL = 2
local LOGIN_POLL_TIMEOUT = 300

-- The menu asks for the connection state every time it redraws, and each ask
-- costs a subprocess on a slow CPU. Cache briefly so one menu open pays for one
-- call; any action invalidates it.
local STATE_CACHE_TTL = 2

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
    self.settings:readSetting("force_userspace", false)

    -- Sign-in UI is opt-in: set when the user asks for a QR code, cleared by
    -- the login poll once it has handed the code over.
    self._want_qr = false

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- Register a Dispatcher action so the toggle appears under "System action..."
    Dispatcher:registerAction("toggle_tailscale_vpn",
      { category = "none", event = "ToggleTailscale", title = _("Toggle Tailscale VPN"), general = true })

    self:installUSBMSHook()
    if not self:resumeAfterUSBMS() then
        self:autoStartTailscale()
    end
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
-- Returns true when a restart was scheduled, so autostart does not stack a second one.
function TailscalePlugin:resumeAfterUSBMS()
    local marker = self:getRestartMarkerPath()
    local mf = io.open(marker, "r")
    if not mf then
        return false
    end
    mf:close()
    os.remove(marker)
    logger.info("Tailscale plugin: restarting Tailscale after USB storage session")
    -- Deferred so we don't block UI startup (start_tailscale.sh sleeps ~2s).
    UIManager:scheduleIn(2, function()
        self:connectTailscale()
    end)
    return true
end

--- Start the daemon on launch and let it resume whatever the user last set.
-- The node's up/down state lives in tailscaled's own state file, so a device
-- that was connected reconnects by itself and one the user turned off stays
-- off. That is why there is no "start automatically" setting to disagree with
-- the connection state — and why this must not call `tailscale up`, which would
-- force WantRunning=true and silently undo the user's "off".
--
-- KOReader instantiates the plugin once for FileManager and once for ReaderUI;
-- the flag keeps those two from racing.
--
-- There is no matching resume hook on purpose: on suspend the kernel freezes
-- tailscaled rather than killing it, so the daemon survives with the same PID
-- and reconnects on its own. Leaving Tailscale on therefore costs nothing while
-- the device sleeps, which is what makes "always on" the sane default.
function TailscalePlugin:autoStartTailscale()
    if UIManager._tailscale_autostart_done then
        return
    end
    if not self:binariesExist() or self:isRunning() then
        return
    end
    UIManager._tailscale_autostart_done = true
    UIManager:scheduleIn(3, function()
        if not self:isRunning() then
            self:startDaemon()
        end
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

--- Userspace networking is a persisted setting rather than a marker file, so
-- it can be flipped from the menu. Takes effect on the next start.
function TailscalePlugin:isUserspaceForced()
    if not self.settings then return false end
    return self.settings:readSetting("force_userspace") and true or false
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
    --
    -- The two modes are not interchangeable, so it is worth being precise about
    -- what userspace networking does. tailscaled still accepts inbound TCP, but
    -- it terminates the connection inside its own userspace netstack and then
    -- re-dials 127.0.0.1:<the same port> as an ordinary local client. Two
    -- consequences follow, and both are load-bearing here:
    --   * inbound peers look like they came from localhost, which is why the
    --     daemon sees 127.0.0.1 rather than the tailnet address;
    --   * routing an exit node is never transparent — it only works for traffic
    --     sent through the SOCKS5/HTTP proxy on 1055/1056, which is the whole
    --     reason this plugin configures KOReader's proxy at all.
    -- Kernel TUN has neither limitation, hence the preference for it.
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
    -- Lua decides every flag and credential here; the executor only assembles
    -- the command line from the TS_* env vars it is handed.
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

--- Run the start script. With `opts.daemon_only` the daemon comes up without a
-- following `tailscale up`, so it adopts the up/down state in its own state file
-- instead of having one forced on it. That is the launch path; the connect path
-- passes nothing and gets a full `up`.
function TailscalePlugin:execStartScript(opts)
    -- Shell script is a dumb executor — all decisions are already made.
    local state_dir = self:resolveStateDir()
    self:ensureLoopback()
    self:resolveTunFlag()
    self:buildUpCommand()

    local env = self:getStartEnvironment(state_dir)
    if opts and opts.daemon_only then
        env = env .. " TS_DAEMON_ONLY=1"
    end
    local ok, _, code = os.execute(env .. " sh '" .. self.plugin_dir .. "/bin/start_tailscale.sh'")
    return ok == true and code == 0
end

--- Launch path: bring the daemon up, touch nothing else.
function TailscalePlugin:startDaemon()
    return self:execStartScript{ daemon_only = true }
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

-- ─── login (non-blocking) ─────────────────────────────────────────

--- Read BackendState and AuthURL straight out of `tailscale status --json`.
-- The daemon answers this even while it waits for a login, so it is a plain
-- read that never blocks. string.match rather than the JSON library: we only
-- need these two scalars, and the daemon is not ours to trust with a parse.
function TailscalePlugin:getBackendState()
    local h = io.popen("'" .. self.ts_bin .. "/tailscale' status --json 2>/dev/null")
    if not h then return nil, nil end
    local raw = h:read("*a") or ""
    h:close()
    return raw:match('"BackendState"%s*:%s*"([^"]*)"'),
        raw:match('"AuthURL"%s*:%s*"([^"]*)"')
end

--- Poll the backend state while a login is pending, instead of blocking the
-- UI on `tailscale up`. The scheduled function is stored on self because
-- UIManager:unschedule keys on the function reference — an anonymous closure
-- could never be cancelled (KOReader #9124).
function TailscalePlugin:startLoginPolling()
    if self._poll_fn then
        return -- already polling; never stack overlapping timers
    end
    self._poll_deadline = os.time() + LOGIN_POLL_TIMEOUT
    self._sign_in_offered = false
    self._poll_fn = function()
        local state, auth_url = self:getBackendState()
        self:invalidateBackendState()
        if state == "Running" then
            self:stopLoginPolling()
            self:onLoginComplete()
        elseif os.time() >= self._poll_deadline then
            self:stopLoginPolling()
            self:onLoginTimeout()
        else
            -- Hand over the QR only when the user asked for one. This used to
            -- fire on its own, which read as a glitch: you toggled something and
            -- a dialog appeared two seconds later with no warning.
            if state == "NeedsLogin" and self._want_qr and auth_url and auth_url ~= "" then
                self._want_qr = false
                self._sign_in_offered = true
                self:showSignInQRCode(auth_url)
            end
            UIManager:scheduleIn(LOGIN_POLL_INTERVAL, self._poll_fn)
        end
    end
    UIManager:scheduleIn(LOGIN_POLL_INTERVAL, self._poll_fn)
end

--- Stop polling. Safe to call from inside the poll function and safe to call
-- when nothing is scheduled.
function TailscalePlugin:stopLoginPolling()
    local fn = self._poll_fn
    self._poll_fn = nil
    if fn then
        UIManager:unschedule(fn)
    end
end

--- The backend reached Running: take down any sign-in UI still on screen and
-- finish the connection the way a plain successful start would have.
function TailscalePlugin:onLoginComplete()
    local signed_in_interactively = self._sign_in_offered
    if self._sign_in_qr then
        UIManager:close(self._sign_in_qr)
        self._sign_in_qr = nil
        signed_in_interactively = true
    end
    self:enableHTTPProxyIfNeeded()
    if signed_in_interactively then
        UIManager:show(InfoMessage:new{
            text = _("Tailscale connected."),
            timeout = 3,
        })
    end
end

function TailscalePlugin:onLoginTimeout()
    UIManager:show(InfoMessage:new{
        text = _("Timed out waiting for a Tailscale sign-in.\nUse Status to check the connection."),
        timeout = 8,
    })
end

--- Explicit QR entry point, reached from Network setup and from the state row. The
-- auth URL only exists once tailscaled has asked the control plane for one, so
-- a cold device connects first and the poll hands the code over when it lands.
function TailscalePlugin:startQRLogin()
    if not self:binariesExist() then
        UIManager:show(InfoMessage:new{
            text = _("Tailscale not installed.\nUse 'Install/Update Tailscale' first."),
            timeout = 4,
        })
        return
    end
    local state, auth_url = self:getBackendState()
    self:invalidateBackendState()
    if state == "Running" then
        UIManager:show(InfoMessage:new{
            text = _("Tailscale is already connected."),
            timeout = 3,
        })
        return
    end
    if state == "NeedsLogin" and auth_url and auth_url ~= "" then
        self._sign_in_offered = true
        self:showSignInQRCode(auth_url)
        return
    end
    -- Daemon down, or up but not yet waiting on a login. Start it and let the
    -- poll hand the code over the moment the backend has one.
    self._want_qr = true
    self:connectTailscale()
end

--- QR path: encode the URL for a phone camera. QRMessage (and the qrencode
-- encoder behind it) can be missing from a build, so the require is protected
-- and a failure falls back to plain text instead of erroring.
function TailscalePlugin:showSignInQRCode(auth_url)
    local ok, QRMessage = pcall(require, "ui/widget/qrmessage")
    if ok and QRMessage then
        local screen = Device.screen
        local built, qr = pcall(function()
            return QRMessage:new{
                text = auth_url,
                width = screen and screen:getWidth() * 2 / 3 or nil,
                height = screen and screen:getHeight() * 2 / 3 or nil,
                dismiss_callback = function() self._sign_in_qr = nil end,
            }
        end)
        if built and qr then
            self._sign_in_qr = qr
            UIManager:show(qr)
            return
        end
    end
    logger.warn("Tailscale plugin: QR widget unavailable, showing the auth URL as text")
    self:showAuthUrlText(auth_url)
end

--- Fallback when QR support is missing: the URL still has to be readable and
-- selectable, never an error.
function TailscalePlugin:showAuthUrlText(auth_url)
    local ok, TextViewer = pcall(require, "ui/widget/textviewer")
    if ok and TextViewer then
        UIManager:show(TextViewer:new{
            title = _("Tailscale sign-in URL"),
            text = auth_url,
            justified = false,
            add_default_buttons = true,
        })
        return
    end
    UIManager:show(InfoMessage:new{
        text = _("Open this URL to sign in:\n" .. auth_url),
        timeout = 30,
    })
end

--- Auth key path: the key is read from a file next to the binaries, so say
-- exactly where it goes and offer to re-check without a restart.
function TailscalePlugin:showAuthKeyHelp()
    local msg = InfoMessage:new{
        text = _("Save your Tailscale auth key in:\n") .. self:getAuthKeyPath()
            .. _("\n\nThe file must contain the key alone (tskey-... or hskey-auth-...)."),
    }
    UIManager:show(msg)
    local dialog
    dialog = ButtonDialog:new{
        title = _("Auth key"),
        buttons = {
            {
                {
                    text = _("Check again"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:close(msg)
                        self:checkAuthKeyAgain()
                    end,
                },
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:close(msg)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

--- Re-read the key file after the user has dropped a key in place; a valid key
-- now means Tailscale can be restarted with it.
function TailscalePlugin:checkAuthKeyAgain()
    if not self:readAuthKey() then
        UIManager:show(InfoMessage:new{
            text = _("No valid auth key found in:\n") .. self:getAuthKeyPath(),
            timeout = 6,
        })
        return
    end
    UIManager:show(InfoMessage:new{
        text = _("Auth key found. Restarting Tailscale..."),
        timeout = 3,
    })
    self:connectTailscale() -- the start script stops any old daemon first
end

-- ─── user-facing actions ──────────────────────────────────────────

--- Backend state, cached for a moment. The menu asks on every redraw and each
-- ask is a subprocess; actions invalidate the cache so the next redraw is live.
function TailscalePlugin:getCachedBackendState()
    local now = os.time()
    local cached = self._state_cache
    if cached and (now - cached.at) < STATE_CACHE_TTL then
        return cached.state, cached.url
    end
    local state, url = self:getBackendState()
    self._state_cache = { at = now, state = state, url = url }
    return state, url
end

function TailscalePlugin:invalidateBackendState()
    self._state_cache = nil
end

--- What the top-level row says. It reports the connection, not the process: a
-- daemon that is up but signed out is not connected, and the checkbox this
-- replaced said it was, which was the most misleading thing in the menu.
function TailscalePlugin:connectionLabel()
    if not self:binariesExist() then
        return _("Not installed")
    end
    if not self:isRunning() then
        return _("Off")
    end
    local state = self:getCachedBackendState()
    if state == "Running" then
        return _("Connected")
    end
    if state == "NeedsLogin" then
        return _("Not connected") .. " — " .. _("tap to sign in")
    end
    if state == "Stopped" then
        return _("Off")
    end
    return _("Starting…")
end

--- One control for connect, disconnect and sign-in. The label above says which
-- of the three this tap will do, so the row never surprises you.
function TailscalePlugin:onConnectionRowTap(after)
    local done = function() if after then after() end end
    if not self:binariesExist() then
        UIManager:show(InfoMessage:new{
            text = _("Tailscale not installed.\nUse 'Install/Update Tailscale' first."),
            timeout = 4,
        })
        return done()
    end
    -- The user just asked, so read live rather than trusting the menu's cache.
    local state, auth_url = self:getBackendState()
    self:invalidateBackendState()
    if state == "Running" then
        self:disconnectTailscale()
    elseif state == "NeedsLogin" and auth_url and auth_url ~= "" then
        self._sign_in_offered = true
        self:showSignInQRCode(auth_url)
    else
        self:connectTailscale()
    end
    done()
end

--- Names the control plane the device is joined to. Almost everyone is on
-- Tailscale's own, so the label says "(default)" outright and the row can be
-- read and skipped rather than opened to find out.
function TailscalePlugin:controlPlaneLabel()
    local url = self:readHeadscaleUrl()
    if url and url ~= "" then
        return _("Control plane") .. ": " .. url
    end
    return _("Control plane") .. ": " .. _("Tailscale (default)")
end

--- One label for the one exit-node decision. Reads as a state, not a prompt.
function TailscalePlugin:exitNodeLabel()
    local node = self.settings and self.settings:readSetting("exit_node") or ""
    if self.settings and self.settings:readSetting("use_exit_node") and node ~= "" then
        return _("Exit node") .. ": " .. node
    end
    return _("Exit node") .. ": " .. _("none")
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
                -- Not a checkbox. It reports the connection rather than the
                -- process, and tapping it does whatever the label says: sign
                -- in, connect, or drop off.
                text_func = function() return self:connectionLabel() end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:onConnectionRowTap(function()
                        if touchmenu_instance and touchmenu_instance.updateItems then
                            touchmenu_instance:updateItems()
                        end
                    end)
                end,
            },
            {
                text = _("Network setup"),
                sub_item_table = {
                    {
                        text = _("Scan QR code"),
                        callback = function() self:startQRLogin() end,
                    },
                    {
                        -- A procedure, not an action: the key is created in the
                        -- admin console and dropped in a file, so this opens the
                        -- instructions and offers to re-check.
                        text = _("Use an auth key"),
                        callback = function() self:showAuthKeyHelp() end,
                    },
                    {
                        -- Reads "Tailscale (default)" for almost everyone, so
                        -- the row answers the question instead of asking it.
                        text_func = function() return self:controlPlaneLabel() end,
                        callback = function() self:configureHeadscale() end,
                    },
                },
            },
            { text = _("Status"), callback = function() self:showStatus() end },
            { text = _("Install/Update Tailscale"), callback = function() self:installTailscale() end },
            {
                text = _("Plugin config"),
                sub_item_table = {
                    {
                        -- One row, one decision. The pair this replaces let you
                        -- reach "enabled but no node chosen", where the start
                        -- script checks both and quietly does nothing.
                        text_func = function() return self:exitNodeLabel() end,
                        callback = function() self:configureExitNode() end,
                    },
                    {
                        text = _("Automatically configure HTTP proxy"),
                        keep_menu_open = true,
                        checked_func = function()
                            return self.settings and self.settings:readSetting("auto_http_proxy")
                        end,
                        callback = function(touchmenu_instance)
                            self.settings:saveSetting("auto_http_proxy",
                                not self.settings:readSetting("auto_http_proxy"))
                            self:flushSettings()
                            if touchmenu_instance and touchmenu_instance.updateItems then
                                touchmenu_instance:updateItems()
                            end
                        end
                    },
                    {
                        text = _("Force userspace mode"),
                        keep_menu_open = true,
                        checked_func = function()
                            return self.settings and self.settings:readSetting("force_userspace")
                        end,
                        callback = function(touchmenu_instance)
                            self.settings:saveSetting("force_userspace",
                                not self.settings:readSetting("force_userspace"))
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
        local msg = _("Installation complete!")
        msg = msg .. _("\nOpen Network setup to scan a QR code with your phone, or to use an auth key.")
        UIManager:show(InfoMessage:new{ text = msg, timeout = 8 })
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
    self:invalidateBackendState()

    UIManager:close(starting_msg)
    if ok then
        -- The daemon may be waiting on an interactive login; watch for it
        -- rather than blocking, and hand the user a real sign-in UI if so.
        self:stopLoginPolling()
        self:startLoginPolling()
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
    self:invalidateBackendState()
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

--- The Headscale login server is just a URL in a file next to the binaries.
-- Set or clear it here; it takes effect on the next start.
function TailscalePlugin:configureHeadscale()
    local path = self:getHeadscaleUrlPath()
    local dialog
    dialog = InputDialog:new{
        title = _("Headscale URL"),
        input = self:readHeadscaleUrl() or "",
        input_hint = _("https://headscale.example.com"),
        description = _("Only needed if you run your own Headscale server.\nEveryone else leaves this empty."),
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
                        local saved = true
                        if value == "" then
                            os.remove(path)
                        else
                            local f = io.open(path, "w")
                            if f then
                                f:write(value .. "\n")
                                f:close()
                            else
                                saved = false
                            end
                        end
                        UIManager:close(dialog)
                        if saved then
                            UIManager:show(InfoMessage:new{
                                text = _("Headscale URL saved. Restart Tailscale to apply."),
                                timeout = 3
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Could not write ") .. path,
                                timeout = 6
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Ask the daemon which exit nodes the tailnet offers. Best effort: if the
-- daemon is down, signed out, or the binary predates `exit-node list`, this
-- returns nothing and the menu still offers None and manual entry.
function TailscalePlugin:listExitNodes()
    local nodes = {}
    if not self:isRunning() then return nodes end
    local h = io.popen("'" .. self.ts_bin .. "/tailscale' exit-node list 2>/dev/null")
    if not h then return nodes end
    local raw = h:read("*a") or ""
    h:close()
    for line in raw:gmatch("[^\r\n]+") do
        local ip, host, rest = line:match("^(%d+%.%d+%.%d+%.%d+)%s+(%S+)%s*(.*)$")
        if ip and host then
            nodes[#nodes + 1] = { host = host, detail = (rest or ""):gsub("%s+$", "") }
        end
    end
    return nodes
end

--- Selecting a node sets both halves of the decision; None clears both. That
-- is the whole point of collapsing the old checkbox + hostname pair: the
-- "enabled but no node chosen" state no longer exists to get stuck in.
function TailscalePlugin:applyExitNode(host)
    if host and host ~= "" then
        self.settings:saveSetting("exit_node", host)
        self.settings:saveSetting("use_exit_node", true)
    else
        self.settings:saveSetting("exit_node", "")
        self.settings:saveSetting("use_exit_node", false)
    end
    self:flushSettings()
    UIManager:show(InfoMessage:new{
        text = host ~= "" and (_("Exit node set to ") .. host .. _(".\nRestart Tailscale to apply."))
            or _("Exit node cleared.\nRestart Tailscale to apply."),
        timeout = 4,
    })
end

function TailscalePlugin:configureExitNode()
    local buttons = {
        {{
            text = _("None"),
            callback = function()
                UIManager:close(self._exit_node_dialog)
                self:applyExitNode("")
            end,
        }},
    }

    for _, node in ipairs(self:listExitNodes()) do
        local label = node.host
        if node.detail ~= "" then
            label = label .. "  (" .. node.detail .. ")"
        end
        buttons[#buttons + 1] = {{
            text = label,
            callback = function()
                UIManager:close(self._exit_node_dialog)
                self:applyExitNode(node.host)
            end,
        }}
    end

    buttons[#buttons + 1] = {{
        text = _("Enter manually…"),
        callback = function()
            UIManager:close(self._exit_node_dialog)
            self:enterExitNodeManually()
        end,
    }}

    self._exit_node_dialog = ButtonDialog:new{
        title = _("Exit node"),
        buttons = buttons,
    }
    UIManager:show(self._exit_node_dialog)
end

--- Fallback for a node the daemon did not list — one that is offline, or a
-- daemon that is not up yet.
function TailscalePlugin:enterExitNodeManually()
    local dialog
    dialog = InputDialog:new{
        title = _("Exit node"),
        input = (self.settings and self.settings:readSetting("exit_node")) or "",
        input_hint = _("Hostname, MagicDNS name, or Tailscale IP"),
        description = _("Route traffic through this Tailscale exit node."),
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
                        UIManager:close(dialog)
                        self:applyExitNode(value)
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
