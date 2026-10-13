#!/usr/bin/env bash
[[ ! ${WARDEN_DIR} ]] && >&2 echo -e "\033[31mThis script is not intended to be run directly!\033[0m" && exit 1

WARDEN_ENV_PATH="$(locateEnvPath)" || exit $?
loadEnvConfig "${WARDEN_ENV_PATH}" || exit $?
assertDockerRunning

## allow return codes from sub-process to bubble up normally
trap '' ERR

## Warden stops collecting WARDEN_PARAMS at the first flag (custom commands are
## in ANYARGS), leaving flags in $@. Merge both: first non-flag, non-help
## token is SUB, everything else is EXTRA (sub-commands parse their own flags).
SUB=""
SUB_GIVEN=0
EXTRA=()
for __token in "${WARDEN_PARAMS[@]}" "$@"; do
  if [[ "${SUB_GIVEN}" == "0" && "${__token}" != -* && "${__token}" != "help" ]]; then
    SUB="${__token}"
    SUB_GIVEN=1
  else
    EXTRA+=("${__token}")
  fi
done
[[ -n "${SUB}" ]] || SUB="status"
unset __token

SHARE_CONTAINER="${WARDEN_ENV_NAME}-share"
SHARE_IMAGE="${SHARE_IMAGE:-cloudflare/cloudflared:latest}"
SHARE_STATE_FILE="${WARDEN_ENV_PATH}/.warden/share.state"
SHARE_ENV_PHP="${WARDEN_ENV_PATH}/app/etc/env.php"
SHARE_LOCAL_HOST="${TRAEFIK_SUBDOMAIN}.${TRAEFIK_DOMAIN}"
SHARE_MODE=""
SHARE_NET=""

shareUsage() {
  "${WARDEN_BIN}" share --help
}

## Pick how cloudflared reaches Magento. Preferred: straight to the nginx
## container over the project docker network, so the real public Host header
## reaches Magento (no canonical-redirect loops, correct cookies). Fallback:
## via host-network Traefik with a Host override (page loads, but Magento
## base-URL rewrite is unsupported there because the origin Host won't match).
shareDetectOrigin() {
  local nginx_cid net
  nginx_cid="$(docker ps -q \
    --filter "label=com.docker.compose.project=${WARDEN_ENV_NAME}" \
    --filter "label=com.docker.compose.service=nginx" 2>/dev/null | head -n 1 || true)"
  if [[ -n "${nginx_cid}" ]]; then
    net="$(docker inspect -f '{{index .Config.Labels "traefik.docker.network"}}' "${nginx_cid}" 2>/dev/null || true)"
    [[ -n "${net}" ]] || net="${WARDEN_ENV_NAME}_default"
    if docker network inspect "${net}" >/dev/null 2>&1; then
      SHARE_MODE="direct"
      SHARE_NET="${net}"
      return 0
    fi
  fi
  SHARE_MODE="traefik"
  SHARE_NET=""
  return 0
}

shareOriginDesc() {
  if [[ "${SHARE_MODE}" == "direct" ]]; then
    echo "http://nginx via docker network ${SHARE_NET} (real Host header)"
  else
    echo "https://127.0.0.1:443 via host network (Host: ${SHARE_LOCAL_HOST})"
  fi
}

shareContainerRunning() {
  [[ "$(docker inspect -f '{{.State.Running}}' "${SHARE_CONTAINER}" 2>/dev/null)" == "true" ]]
}

shareContainerExists() {
  docker inspect "${SHARE_CONTAINER}" >/dev/null 2>&1
}

shareTunnelUrl() {
  docker logs "${SHARE_CONTAINER}" 2>&1 | grep -oE 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' | head -n 1
  return 0
}

shareLoadState() {
  TUNNEL_URL=""; TUNNEL_HOST=""; ORIG_UNSECURE=""; ORIG_SECURE=""
  ORIG_COOKIE_DOMAIN=""; BASE_URL_REWRITTEN="0"
  [[ -f "${SHARE_STATE_FILE}" ]] && source "${SHARE_STATE_FILE}"
  return 0
}

shareSaveState() {
  cat > "${SHARE_STATE_FILE}" <<EOF
TUNNEL_URL='${TUNNEL_URL}'
TUNNEL_HOST='${TUNNEL_HOST}'
ORIG_UNSECURE='${ORIG_UNSECURE}'
ORIG_SECURE='${ORIG_SECURE}'
ORIG_COOKIE_DOMAIN='${ORIG_COOKIE_DOMAIN}'
BASE_URL_REWRITTEN='${BASE_URL_REWRITTEN}'
EOF
}

## Prints the host currently configured as Magento base_url in app/etc/env.php
shareEnvBaseHost() {
  grep "'base_url'" "${SHARE_ENV_PHP}" 2>/dev/null | head -n 1 \
    | sed -E "s|.*'base_url' => 'https?://([^/']+).*|\1|"
}

shareCaptureOriginals() {
  [[ -n "${ORIG_UNSECURE}" ]] && return 0
  ORIG_UNSECURE="$(sed -n "/'unsecure' => \[/,/\],/p" "${SHARE_ENV_PHP}" \
    | grep "'base_url'" | head -n 1 | sed -E "s/.*'base_url' => '([^']+)'.*/\1/" || true)"
  ORIG_SECURE="$(sed -n "/'secure' => \[/,/\],/p" "${SHARE_ENV_PHP}" \
    | grep "'base_url'" | head -n 1 | sed -E "s/.*'base_url' => '([^']+)'.*/\1/" || true)"
  ORIG_COOKIE_DOMAIN="$(sed -n "/'cookie' => \[/,/\],/p" "${SHARE_ENV_PHP}" \
    | grep "'cookie_domain'" | head -n 1 | sed -E "s/.*'cookie_domain' => '([^']*)'.*/\1/" || true)"
  [[ -n "${ORIG_UNSECURE}" && -n "${ORIG_SECURE}" ]] || {
    error "Could not read current base URLs from app/etc/env.php; aborting rewrite."
    return 1
  }
}

shareRewriteOn() {
  shareCaptureOriginals || return $?
  echo "==> Pointing Magento base URLs to tunnel (was ${ORIG_UNSECURE})..."
  sed -i "/'unsecure' => \[/,/\],/ s|'base_url' => '[^']*'|'base_url' => '${TUNNEL_URL}/'|" "${SHARE_ENV_PHP}"
  sed -i "/'secure' => \[/,/\],/ s|'base_url' => '[^']*'|'base_url' => '${TUNNEL_URL}/'|" "${SHARE_ENV_PHP}"
  sed -i "/'cookie' => \[/,/\],/ s|'cookie_domain' => '[^']*'|'cookie_domain' => ''|" "${SHARE_ENV_PHP}"
  echo "==> Importing configuration (env.php changed)..."
  "${WARDEN_BIN}" env exec php-fpm bin/magento app:config:import -n || return $?
  echo "==> Cleaning config + full_page cache..."
  "${WARDEN_BIN}" env exec php-fpm bin/magento cache:clean config full_page || return $?
  BASE_URL_REWRITTEN="1"
  echo "==> Base URLs now served from ${TUNNEL_URL}/ (restored on 'warden share down')."
}

shareRewriteOff() {
  [[ "${BASE_URL_REWRITTEN}" == "1" ]] || return 0
  echo "==> Restoring Magento base URLs (${ORIG_UNSECURE}, cookie_domain '${ORIG_COOKIE_DOMAIN}')..."
  sed -i "/'unsecure' => \[/,/\],/ s|'base_url' => '[^']*'|'base_url' => '${ORIG_UNSECURE}'|" "${SHARE_ENV_PHP}"
  sed -i "/'secure' => \[/,/\],/ s|'base_url' => '[^']*'|'base_url' => '${ORIG_SECURE}'|" "${SHARE_ENV_PHP}"
  sed -i "/'cookie' => \[/,/\],/ s|'cookie_domain' => '[^']*'|'cookie_domain' => '${ORIG_COOKIE_DOMAIN}'|" "${SHARE_ENV_PHP}"
  echo "==> Importing configuration (env.php changed)..."
  "${WARDEN_BIN}" env exec php-fpm bin/magento app:config:import -n || return $?
  echo "==> Cleaning config + full_page cache..."
  "${WARDEN_BIN}" env exec php-fpm bin/magento cache:clean config full_page || return $?
  BASE_URL_REWRITTEN="0"
}

sharePrintUrl() {
  echo "==> Share URL: ${TUNNEL_URL}/"
  if command -v qrencode >/dev/null 2>&1; then
    echo "==> Scan with your phone:"
    qrencode -t ANSIUTF8 "${TUNNEL_URL}/"
  fi
}

shareUp() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      -h|--help|help) shareUsage; return 0 ;;
      *) error "Unknown option \"${arg}\" for 'share up'."; shareUsage; return 1 ;;
    esac
  done

  [[ -n "${TRAEFIK_SUBDOMAIN}" && -n "${TRAEFIK_DOMAIN}" ]] || {
    error "TRAEFIK_SUBDOMAIN/TRAEFIK_DOMAIN are not set in .env; cannot determine local hostname."
    return 1
  }
  [[ -f "${SHARE_ENV_PHP}" ]] || {
    error "app/etc/env.php not found; is Magento installed?"
    return 1
  }

  if shareContainerRunning; then
    echo "==> Share tunnel already running."
  else
    echo "==> Checking local site https://${SHARE_LOCAL_HOST}/ ..."
    local CODE
    CODE=$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 10 "https://${SHARE_LOCAL_HOST}/" || echo "000")
    if [[ "${CODE}" == "000" || "${CODE}" == "502" || "${CODE}" == "503" ]]; then
      echo "==> Local site not responding (${CODE}), bringing env up first..."
      "${WARDEN_BIN}" env up -d || return $?
    fi
    if ! docker image inspect "${SHARE_IMAGE}" >/dev/null 2>&1; then
      echo "==> Pulling ${SHARE_IMAGE} (first run only)..."
      docker pull "${SHARE_IMAGE}" || return $?
    fi
    docker rm -f "${SHARE_CONTAINER}" >/dev/null 2>&1 || true
    shareDetectOrigin
    if [[ "${SHARE_MODE}" != "direct" ]]; then
      error "Nginx container not found; run 'warden local up' first, then retry."
      return 1
    fi
    echo "==> Starting Cloudflare quick tunnel (temp public URL, no account needed)..."
    echo "    Origin: $(shareOriginDesc)"
    if [[ "${SHARE_MODE}" == "direct" ]]; then
      docker run -d --rm --name "${SHARE_CONTAINER}" --network "${SHARE_NET}" "${SHARE_IMAGE}" \
        tunnel --url http://nginx --no-autoupdate || return $?
    else
      docker run -d --rm --name "${SHARE_CONTAINER}" --network host "${SHARE_IMAGE}" \
        tunnel --url https://127.0.0.1:443 \
        --http-host-header "${SHARE_LOCAL_HOST}" \
        --origin-server-name "${SHARE_LOCAL_HOST}" \
        --no-tls-verify --no-autoupdate || return $?
    fi
  fi

  echo "==> Waiting for tunnel URL (up to 90s)..."
  shareLoadState
  local i
  for i in $(seq 1 45); do
    TUNNEL_URL="$(shareTunnelUrl || true)"
    [[ -n "${TUNNEL_URL}" ]] && break
    if ! shareContainerRunning; then
      error "Tunnel container stopped unexpectedly. Logs:"
      docker logs "${SHARE_CONTAINER}" 2>&1 | tail -n 20
      return 1
    fi
    sleep 2
  done
  [[ -n "${TUNNEL_URL}" ]] || {
    error "Timed out waiting for tunnel URL."
    docker logs "${SHARE_CONTAINER}" 2>&1 | tail -n 20
    return 1
  }
  TUNNEL_HOST="${TUNNEL_URL#https://}"

  shareRewriteOn || return $?

  shareSaveState
  sharePrintUrl
  echo "==> Stop with 'warden share down' (also restores base URLs)."
}

shareDown() {
  local KEEP_BASE_URL=0
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --keep-base-url) KEEP_BASE_URL=1 ;;
      -h|--help|help) shareUsage; return 0 ;;
      *) error "Unknown option \"${arg}\" for 'share down'."; shareUsage; return 1 ;;
    esac
  done

  shareLoadState
  if shareContainerExists; then
    echo "==> Stopping share tunnel..."
    docker rm -f "${SHARE_CONTAINER}" >/dev/null || return $?
  else
    echo "==> No share tunnel running."
  fi

  if [[ "${BASE_URL_REWRITTEN}" == "1" && "${KEEP_BASE_URL}" == "1" ]]; then
    shareSaveState
    echo "==> Kept rewritten base URLs (${TUNNEL_URL}/) per --keep-base-url."
    echo "    Run 'warden share down' without flags to restore them."
    return 0
  fi

  if [[ "${BASE_URL_REWRITTEN}" == "1" ]]; then
    shareRewriteOff || {
      echo "==> WARNING: base-URL restore may have failed; state kept at ${SHARE_STATE_FILE}."
      shareSaveState
      return 1
    }
  fi
  rm -f "${SHARE_STATE_FILE}"
  echo "==> Share tunnel stopped."
}

shareStatus() {
  shareLoadState
  if shareContainerRunning; then
    local URL
    URL="$(shareTunnelUrl || true)"
    [[ -n "${TUNNEL_URL}" ]] || TUNNEL_URL="${URL}"
    echo "==> Share tunnel: RUNNING (${SHARE_CONTAINER})"
    [[ -n "${TUNNEL_URL}" ]] && echo "    URL: ${TUNNEL_URL}/"
    shareDetectOrigin
    echo "    Origin: $(shareOriginDesc)"
  else
    echo "==> Share tunnel: STOPPED"
  fi
  local CUR_HOST
  CUR_HOST="$(shareEnvBaseHost)"
  if [[ "${CUR_HOST}" == "${SHARE_LOCAL_HOST}" ]]; then
    echo "    Magento base URL: local (https://${SHARE_LOCAL_HOST}/)"
  else
    echo "    Magento base URL: ${CUR_HOST:-unknown} (rewritten: ${BASE_URL_REWRITTEN})"
  fi
}

## bare `warden share --help` / `-h` (no sub-command given): show usage
if [[ "${SUB_GIVEN}" == "0" ]]; then
  for __extra in "${EXTRA[@]}"; do
    case "${__extra}" in
      -h|--help|help) shareUsage; exit 0 ;;
    esac
  done
  unset __extra
fi

case "${SUB}" in
  up)
    shareUp "${EXTRA[@]}"
    ;;
  down|stop)
    shareDown "${EXTRA[@]}"
    ;;
  status)
    shareStatus
    ;;
  url)
    if shareContainerRunning; then
      URL="$(shareTunnelUrl || true)"
      if [[ -n "${URL}" ]]; then
        echo "${URL}"
      else
        error "Tunnel starting, URL not available yet (see 'warden share logs')."
        exit 1
      fi
    else
      error "No share tunnel running (see 'warden share up')."
      exit 1
    fi
    ;;
  logs)
    if shareContainerExists; then
      docker logs --tail=100 "${EXTRA[@]}" "${SHARE_CONTAINER}"
    else
      error "No share tunnel container found (see 'warden share up')."
      exit 1
    fi
    ;;
  -h|--help|help)
    "${WARDEN_BIN}" share --help
    ;;
  *)
    error "Unknown sub-command \"${SUB}\"."
    >&2 echo "Run 'warden share --help' for usage."
    exit 1
    ;;
esac
