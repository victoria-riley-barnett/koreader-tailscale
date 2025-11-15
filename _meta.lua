local _ = require("gettext")
return {
    name = "tailscale",
    fullname = _("Tailscale VPN"),
    description = _("Secure remote access and file sync via Tailscale"),
    author = "Victoria B.",
    version = "1.0.2",
    dependencies = {},
    can_configure = true,
    has_widget = true,
}