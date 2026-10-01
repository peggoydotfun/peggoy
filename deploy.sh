#!/usr/bin/env bash
# Deploy the PEGGOY static site to the VPS over SSH (host = ssh alias in .deploy-host or $PEGGOY_HOST).
#
#   ./deploy.sh setup [domain]   once: web root, nginx site, TLS (default domain peggoy.fun)
#   ./deploy.sh                  build dist/ and ship it
#   ./deploy.sh machine 0xMACHINE 0xTIMELOCK   record the mainnet Machine (after script/Deploy.s.sol), testnet stays active
#   ./deploy.sh ca 0xTOKEN|TBA   launch: CA on the site (copy + Buy on Pons), Machine page switches to mainnet;
#                                TBA puts "SOON" back and returns the Machine page to the testnet demo
#   ./deploy.sh status           nginx + https check
#
# macOS ships openrsync: use --stats, not --info=… (it fails silently).
set -euo pipefail
cd "$(dirname "$0")"
HOST=${PEGGOY_HOST:-$(cat .deploy-host 2>/dev/null || true)}
[ -n "$HOST" ] || { echo "set PEGGOY_HOST or put the ssh alias in .deploy-host"; exit 1; }
CMD=${1:-deploy}
DOMAIN=$(cat .deploy-domain 2>/dev/null || echo peggoy.fun)

build() {
  echo "→ dist/ (public files only, cache-busted)"
  rm -rf dist && mkdir -p dist/assets
  cp index.html machine.html docs.html styles.css main.js machine.js docs.js board.js sound.js wallet.js chain.js connect-ui.js deployments.json robots.txt og.png favicon.ico site.webmanifest dist/
  cp -R assets/img assets/models dist/assets/
  V=$(date +%s)
  sed -i '' "s|href=\"styles.css\"|href=\"styles.css?v=$V\"|; s|src=\"main.js\"|src=\"main.js?v=$V\"|" dist/index.html
  sed -i '' "s|href=\"styles.css\"|href=\"styles.css?v=$V\"|; s|src=\"machine.js\"|src=\"machine.js?v=$V\"|" dist/machine.html
  sed -i '' "s|href=\"styles.css\"|href=\"styles.css?v=$V\"|; s|src=\"docs.js\"|src=\"docs.js?v=$V\"|" dist/docs.html
}

ship() {
  build
  echo "→ dist/ → $HOST:/var/www/peggoy"
  rsync -az --delete --stats dist/ "$HOST:/var/www/peggoy/" | grep -E "Number of files transferred|Total transferred" || true
  ssh "$HOST" 'chown -R www-data:www-data /var/www/peggoy'
}

case "$CMD" in
  setup)
    DOMAIN=${2:-$DOMAIN}
    echo "$DOMAIN" > .deploy-domain
    ssh "$HOST" 'mkdir -p /var/www/peggoy /var/cache/nginx/peggoy'
    ship
    sed "s/__DOMAIN__/$DOMAIN/g" deploy/nginx.conf | ssh "$HOST" 'cat > /etc/nginx/sites-available/peggoy'
    ssh "$HOST" DOMAIN="$DOMAIN" 'bash -s' <<'REMOTE'
set -e
ln -sf /etc/nginx/sites-available/peggoy /etc/nginx/sites-enabled/peggoy
nginx -t && systemctl reload nginx
ME=$(curl -s -4 ifconfig.me)
if ! getent ahostsv4 "$DOMAIN" | awk '{print $1}' | grep -qx "$ME"; then
  echo "   $DOMAIN does not resolve to this server ($ME) yet. Point the A record at $ME, then rerun: ./deploy.sh setup"
  exit 0
fi
DOMS=(-d "$DOMAIN")
getent ahostsv4 "www.$DOMAIN" | awk '{print $1}' | grep -qx "$ME" && DOMS+=(-d "www.$DOMAIN")
certbot --nginx "${DOMS[@]}" --non-interactive --agree-tos --register-unsafely-without-email --redirect --expand \
  || echo "   certbot failed: check the A record, then rerun setup"
echo "   https://$DOMAIN"
REMOTE
    ;;
  deploy) ship ;;
  ca)
    V=${2:?usage: ./deploy.sh ca 0xTOKEN|TBA}
    if [ "$V" = "TBA" ]; then NEW=""; else
      [[ $V =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "not an address"; exit 1; }
      NEW=$V
    fi
    sed -i '' "s|^  ca: '[^']*',|  ca: '$NEW',|" main.js
    grep -n "^  ca:" main.js
    python3 - "$NEW" <<'PY'
import json, sys
ca = sys.argv[1]
d = json.load(open('deployments.json'))
d['networks']['mainnet']['token'] = ca
d['active'] = 'mainnet' if ca and d['networks']['mainnet']['machine'] else 'testnet'
json.dump(d, open('deployments.json', 'w'), indent=2); open('deployments.json', 'a').write('\n')
print('   Machine page network:', d['active'], '' if d['active'] == 'mainnet' or not ca else '(run ./deploy.sh machine … first)')
PY
    ship
    echo "   CA on site: ${NEW:-Coming} · Buy → ${NEW:+https://ponsfamily.com/launchpad/$NEW}"
    ;;
  machine)
    M=${2:?usage: ./deploy.sh machine 0xMACHINE 0xTIMELOCK}; T=${3:?usage: ./deploy.sh machine 0xMACHINE 0xTIMELOCK}
    [[ $M =~ ^0x[0-9a-fA-F]{40}$ && $T =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "not addresses"; exit 1; }
    python3 - "$M" "$T" <<'PY'
import json, sys
d = json.load(open('deployments.json'))
d['networks']['mainnet'].update(machine=sys.argv[1], timelock=sys.argv[2])
json.dump(d, open('deployments.json', 'w'), indent=2); open('deployments.json', 'a').write('\n')
PY
    ship
    ;;
  status)
    ssh "$HOST" "nginx -t 2>&1 | tail -1; ls /var/www/peggoy | head"
    curl -s -o /dev/null -w "public https: %{http_code}\n" "https://$DOMAIN/" || true
    ;;
  *) echo "usage: ./deploy.sh [setup [domain]|deploy|machine 0x… 0x…|ca 0x…|TBA|status]"; exit 1 ;;
esac
