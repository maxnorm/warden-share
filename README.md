# warden-share

A [Warden](https://github.com/davidalger/warden) custom command that exposes your
local Magento 2 environment over the internet via a temporary Cloudflare quick
tunnel (`https://*.trycloudflare.com`, no account needed). Handy for testing
changes on a real phone over the network.

## Install

Copy both files into your project's warden commands directory and make the
command executable:

```console
cp share.cmd share.help /path/to/project/.warden/commands/
chmod +x /path/to/project/.warden/commands/share.cmd
```

Requirements on the host: `warden`, `docker`, `curl`. Optional: `qrencode`
(prints a phone-scannable QR code with the URL).

## Usage

```console
warden share up       # share fully working site, test on phone
warden share status   # re-print URL / check rewrite state
warden share url      # print just the tunnel URL (for scripting)
warden share logs     # show cloudflared logs ('-f' to follow)
warden share down     # stop tunnel, restore local base URLs
```

`up` starts a throwaway `cloudflared` container attached to the project docker
network (proxying straight to the `nginx` container, so the real public Host
header reaches Magento), then rewrites the base URLs + cookie domain in
`app/etc/env.php` to the tunnel URL followed by `app:config:import` and a
cache clean. `down` stops the tunnel and restores `env.php` (import + cache
clean included). Rewrite state is kept in `.warden/share.state` inside the
project.

Each `up` mints a new random URL; old URLs stop working on `down`. CMS content
with hardcoded `.test` links is unaffected by the rewrite.
