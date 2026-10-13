# warden-share

Warden custom command. Exposes local Magento 2 env over internet via temporary
Cloudflare quick tunnel (`https://*.trycloudflare.com`, no account needed).
Test changes on real phone over network.

## Requirements

- Warden Magento 2 project, env up, `nginx` container running
- Host: `warden`, `docker`, `curl`
- Optional: `qrencode` (prints phone-scannable QR code)

## Install

```console
cp share.cmd share.help /path/to/project/.warden/commands/
chmod +x /path/to/project/.warden/commands/share.cmd
```

## Usage

```console
warden share up       # start tunnel, rewrite base URLs, print URL + QR
warden share status   # tunnel state, URL, current base-URL host
warden share url      # bare tunnel URL (scripting)
warden share logs     # cloudflared logs ('-f' to follow)
warden share down     # stop tunnel, restore local base URLs
```

`down` also accepts `--keep-base-url` (stop tunnel, skip restore) and `stop`
works as alias for `down`.

## How it works

`up` starts throwaway `cloudflare/cloudflared` container on project docker
network, proxying straight to `nginx` service. Real public Host header reaches
Magento: no canonical-redirect loop, correct cookies, valid edge cert.

Then rewrites 3 locked values in `app/etc/env.php` (secure/unsecure
`base_url`, empty `cookie_domain`), runs `app:config:import -n` (env.php
change 500s site without it) + `cache:clean config full_page`.

`down` stops container, restores original values, re-imports, cleans cache.
Rewrite state (tunnel URL + originals) kept in `.warden/share.state` in
project. `down` restores even when tunnel already gone. Re-running `up`
against same URL skips redundant rewrite.

Each `up` mints new random URL. Old URLs die on `down`. CMS content with
hardcoded `.test` links unaffected by rewrite.

## Warning

Tunnel URL public, no auth. Anyone with URL opens site. Never share
production data. Stop tunnel when done.

## License

MIT. See LICENSE.
