local _ = require("gettext")
return {
    name = "tailscale",
    fullname = _("Tailscale VPN"),
    description = _("Secure remote access and file sync via Tailscale"),
    author = "Kindle Tailscale Plugin",
    version = "1.0",
    dependencies = {},
    can_configure = true,
    has_widget = true,
}