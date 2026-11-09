#!/usr/bin/env bash
set -euo pipefail


[[ "${EUID}" -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

WG_EASY_IMAGE="ghcr.io/wg-easy/wg-easy:15.3.0"
WG_GATEWAY_IP="10.8.0.1"
WG_SUBNET="10.8.0.0/24"
SSH_PORT="22"
ADMIN_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
WAN_IF="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"; WAN_IF="${WAN_IF:-eth0}"
DETECTED_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"

ask() { local p="$1" d="${2:-}" a; if [[ -n "$d" ]]; then read -rp "$p [$d]: " a; echo "${a:-$d}"; else read -rp "$p: " a; echo "$a"; fi; }
ask_secret() {
  local __n="$1" __l="$2" __min="${3:-8}" __v __c
  while :; do
    read -rsp "$__l: " __v; echo
    [[ ${#__v} -ge ${__min} ]] || { echo "  min ${__min} chars"; continue; }
    read -rsp "confirm: " __c; echo
    [[ "$__v" == "$__c" ]] || { echo "  mismatch"; continue; }
    printf -v "$__n" '%s' "$__v"; break
  done
}

preflight() {
  echo "== preflight =="
  local fail=0 p occupant
  if [[ -r /etc/os-release ]]; then . /etc/os-release; [[ "${ID:-}" == "debian" ]] || echo "  [warn] built for debian 12; found ${PRETTY_NAME:-unknown}"; fi
  if timeout 8 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' 2>/dev/null; then echo "  [ok] outbound internet"; else echo "  [fail] no outbound internet (tcp/443) - needed to download components"; fail=1; fi
  for p in 53 80 443 3000 5335 51821; do
    occupant="$(ss -H -tulnp "sport = :${p}" 2>/dev/null | grep -viE 'caddy|adguardhome|unbound|docker|wg-easy|systemd-resolve' | head -n1 || true)"
    [[ -n "${occupant}" ]] && { echo "  [warn] port ${p} already used by a non-obsidian process - free it before deploy:"; echo "         ${occupant}"; }
  done
  echo "  [action] open these INBOUND in your cloud provider firewall / security group:"
  echo "           22/tcp ssh    80/tcp http    443/tcp https panel    443/udp amneziawg vpn"
  echo "           (most clouds block inbound udp by default - 443/udp MUST be allowed or the vpn cannot connect)"
  echo "  [note] the host firewall (ufw) is configured for you; the cloud firewall is not - that one is yours to open."
  [[ ${fail} -eq 0 ]] || { echo "  preflight failed - fix the [fail] item(s) above and re-run." >&2; exit 1; }
  echo "  [ok] preflight passed"
}
preflight

echo "== obsidian =="
PUBLIC_IP="$(ask 'public ip' "${DETECTED_IP}")"
[[ "${PUBLIC_IP}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || { echo "invalid ip" >&2; exit 1; }
DOMAIN="$(ask 'domain for vpn/adguard hostnames' 'example.com')"
VPN_HOST="vpn.${DOMAIN}"
ADGUARD_HOST="adguard.${DOMAIN}"
DASHBOARD_USERNAME="$(ask 'wg-easy dashboard user' 'admin')"
ask_secret DASHBOARD_PASSWORD 'wg-easy dashboard password' 12
ADGUARD_USERNAME="$(ask 'adguard user' 'admin')"
ask_secret ADGUARD_PASSWORD 'adguard password'

echo "deploying to ${PUBLIC_IP} (wan ${WAN_IF})"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg lsb-release ufw fail2ban python3 \
  git make dkms iptables sqlite3 debian-keyring debian-archive-keyring apt-transport-https \
  unattended-upgrades build-essential libssl-dev libexpat1-dev libevent-dev bison flex \
  "linux-headers-$(uname -r)" > /dev/null

cat << 'UPGR_EOF' > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
UPGR_EOF
systemctl enable --now unattended-upgrades > /dev/null 2>&1 || true

cat << 'SYSCTL_EOF' > /etc/sysctl.d/99-edge-performance.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.core.somaxconn = 1024
net.ipv4.tcp_max_syn_backlog = 2048
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.core.netdev_max_backlog = 16384
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
kernel.kptr_restrict = 2
fs.suid_dumpable = 0
vm.swappiness = 10
SYSCTL_EOF
echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
modprobe tcp_bbr 2>/dev/null || true
sysctl --system > /dev/null 2>&1 || true

if grep -q '^#\?PermitRootLogin' /etc/ssh/sshd_config; then
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
else
  echo "PermitRootLogin no" >> /etc/ssh/sshd_config
fi
if grep -q '^#\?X11Forwarding' /etc/ssh/sshd_config; then
  sed -i 's/^#\?X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config
else
  echo "X11Forwarding no" >> /etc/ssh/sshd_config
fi
grep -q '^ClientAliveInterval'    /etc/ssh/sshd_config || echo "ClientAliveInterval 300"      >> /etc/ssh/sshd_config
grep -q '^ClientAliveCountMax'    /etc/ssh/sshd_config || echo "ClientAliveCountMax 2"        >> /etc/ssh/sshd_config
grep -q '^MaxAuthTries'           /etc/ssh/sshd_config || echo "MaxAuthTries 4"               >> /etc/ssh/sshd_config
grep -q '^LoginGraceTime'         /etc/ssh/sshd_config || echo "LoginGraceTime 30"            >> /etc/ssh/sshd_config
grep -q '^PermitEmptyPasswords'   /etc/ssh/sshd_config || echo "PermitEmptyPasswords no"      >> /etc/ssh/sshd_config
grep -q '^PasswordAuthentication' /etc/ssh/sshd_config || echo "PasswordAuthentication yes"   >> /etc/ssh/sshd_config
grep -q '^AllowUsers'             /etc/ssh/sshd_config || echo "AllowUsers ${ADMIN_USER}"     >> /etc/ssh/sshd_config
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

systemctl disable --now systemd-resolved 2>/dev/null || true
rm -f /etc/resolv.conf
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf

apt-get install -y -qq unbound > /dev/null
systemctl stop unbound 2>/dev/null || true
UNBOUND_TAG="$(git ls-remote --tags https://github.com/NLnetLabs/unbound.git 2>/dev/null | awk -F/ '{print $NF}' | grep -E '^release-1\.[0-9]+\.[0-9]+$' | sort -V | tail -1 || true)"
if [[ -n "${UNBOUND_TAG}" ]]; then
  rm -rf /tmp/unbound-build
  if ( set -e
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "${UNBOUND_TAG}" https://github.com/NLnetLabs/unbound.git /tmp/unbound-build
    cd /tmp/unbound-build
    ./configure --prefix=/usr --sysconfdir=/etc --with-pidfile=/run/unbound/unbound.pid > /dev/null 2>&1
    make -j"$(nproc)" > /dev/null 2>&1
    make install > /dev/null 2>&1
  ); then
    ldconfig
    mkdir -p /var/lib/unbound
    chown unbound:unbound /var/lib/unbound
    unbound-anchor -a /var/lib/unbound/root.key || true
    chown unbound:unbound /var/lib/unbound/root.key 2>/dev/null || true
    echo "[i] unbound ${UNBOUND_TAG} from source"
  else
    echo "[!] unbound source build failed, using package"
  fi
  rm -rf /tmp/unbound-build
fi

cat << UNBOUND_EOF > /etc/unbound/unbound.conf.d/high-speed-cache.conf
server:
    verbosity: 1
    interface: 127.0.0.1
    port: 5335
    chroot: ""
    do-ip4: yes
    do-udp: yes
    do-tcp: yes
    do-ip6: no
    msg-cache-size: 16m
    rrset-cache-size: 32m
    cache-min-ttl: 300
    cache-max-ttl: 86400
    infra-cache-numhosts: 50000
    minimal-responses: yes
    private-address: 10.0.0.0/8
    private-address: 172.16.0.0/12
    private-address: 192.168.0.0/16
    private-address: 169.254.0.0/16
    prefetch: yes
    prefetch-key: yes
    serve-expired: yes
    serve-expired-ttl: 86400
    serve-expired-client-timeout: 1800
    num-threads: 1
    outgoing-range: 4096
    num-queries-per-thread: 2048
    so-rcvbuf: 4m
    so-sndbuf: 4m
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: yes
    edns-buffer-size: 1232
    hide-identity: yes
    hide-version: yes
    qname-minimisation: yes
    aggressive-nsec: yes
    local-zone: "${DOMAIN}." static
    local-data: "${VPN_HOST}. IN A ${WG_GATEWAY_IP}"
    local-data: "${ADGUARD_HOST}. IN A ${WG_GATEWAY_IP}"
    local-data: "status.${DOMAIN}. IN A ${WG_GATEWAY_IP}"
UNBOUND_EOF

cat << 'UNBOUND_RC_EOF' > /etc/unbound/unbound.conf.d/remote-control.conf
remote-control:
  control-enable: yes
  control-interface: /run/unbound.ctl
UNBOUND_RC_EOF

mkdir -p /run/unbound
chown unbound:unbound /run/unbound 2>/dev/null || true
mkdir -p /etc/systemd/system/unbound.service.d
printf '[Service]\nType=simple\nRestart=on-failure\nRestartSec=5\n' > /etc/systemd/system/unbound.service.d/override.conf
systemctl daemon-reload
systemctl restart unbound
systemctl enable unbound > /dev/null 2>&1

if [ ! -f "/opt/AdGuardHome/AdGuardHome" ]; then
  ( cd /tmp && curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v > /dev/null )
fi
systemctl enable --now AdGuardHome 2>/dev/null || true
systemctl stop AdGuardHome 2>/dev/null || true
cat << 'AGH_EOF' > /opt/AdGuardHome/AdGuardHome.yaml
schema_version: 29
bind_host: 127.0.0.1
bind_port: 3000
http:
  address: 127.0.0.1:3000
dns:
  bind_hosts:
    - 0.0.0.0
  port: 53
  ratelimit: 0
  cache_size: 4194304
  cache_ttl_min: 300
  cache_ttl_max: 86400
  cache_optimistic: true
  upstream_dns:
    - 127.0.0.1:5335
  bootstrap_dns:
    - 1.1.1.1
    - 8.8.8.8
AGH_EOF
mkdir -p /etc/systemd/system/AdGuardHome.service.d
printf '[Service]\nRestart=on-failure\nRestartSec=5\n' > /etc/systemd/system/AdGuardHome.service.d/override.conf
systemctl daemon-reload
systemctl start AdGuardHome

if ! command -v docker &> /dev/null; then
  curl -fsSL https://get.docker.com | sh > /dev/null
fi
mkdir -p /etc/docker
cat << 'DOCKER_EOF' > /etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
DOCKER_EOF
mkdir -p /etc/systemd/system/docker.service.d
cat > /usr/local/bin/docker-user-vpn-fix.sh << EOF
#!/usr/bin/env bash
iptables -C DOCKER-USER -s ${WG_SUBNET} -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -s ${WG_SUBNET} -j ACCEPT
iptables -C DOCKER-USER -d ${WG_SUBNET} -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -d ${WG_SUBNET} -j ACCEPT
EOF
chmod +x /usr/local/bin/docker-user-vpn-fix.sh
cat > /etc/systemd/system/docker.service.d/vpn-forward.conf << 'EOF'
[Service]
ExecStartPost=/usr/local/bin/docker-user-vpn-fix.sh
EOF
systemctl daemon-reload
systemctl enable --now docker
systemctl restart docker
/usr/local/bin/docker-user-vpn-fix.sh
docker pull -q "${WG_EASY_IMAGE}" > /dev/null

rmmod amneziawg 2>/dev/null || true
while read -r old; do [[ -n "${old}" ]] && dkms remove -m amneziawg -v "${old}" --all > /dev/null 2>&1; true; done \
  < <(dkms status 2>/dev/null | grep '^amneziawg' | sed -E 's#^amneziawg/([^,]+),.*#\1#' | sort -u)
rm -rf /usr/src/amneziawg-* /tmp/amneziawg-build

AWG_ENV=()
AWG_READY="false"
git clone --quiet https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git /tmp/amneziawg-build 2>/dev/null \
  || { echo "[fatal] could not clone the amneziawg kernel-module repo" >&2; exit 1; }
AWG_TAG="$(cd /tmp/amneziawg-build && git tag -l 'v1.0.*' | sort -V | tail -1)"
[[ -n "${AWG_TAG}" ]] || { echo "[fatal] no amneziawg release tag found" >&2; exit 1; }
if ( set -e
    cd /tmp/amneziawg-build
    git -c advice.detachedHead=false checkout --quiet "${AWG_TAG}"
    cd src
    DKMS_VER="$(grep '^PACKAGE_VERSION=' dkms.conf | cut -d'"' -f2)"
    [[ -n "${DKMS_VER}" ]]
    make dkms-install > /dev/null 2>&1
    dkms add -m amneziawg -v "${DKMS_VER}" > /dev/null 2>&1 || true
    dkms build -m amneziawg -v "${DKMS_VER}" > /dev/null 2>&1
    dkms install -m amneziawg -v "${DKMS_VER}" > /dev/null 2>&1
    modprobe amneziawg
  ); then
  AWG_READY="true"
fi
[[ "${AWG_READY}" == "true" ]] || { echo "[fatal] amneziawg kernel module build/load failed - aborting (no plain-wireguard fallback)" >&2; exit 1; }
echo "amneziawg" > /etc/modules-load.d/amneziawg.conf
echo "[i] amneziawg: enabled (${AWG_TAG})"

docker rm -f wg-easy 2>/dev/null || true
mkdir -p /root/.wg-easy
AWG_MOUNT=()
HEALTH_ARGS=()
if [[ "${AWG_READY}" == "true" ]]; then
  AWG_ENV+=(-e EXPERIMENTAL_AWG=true)
  AWG_MOUNT=(-v /lib/modules:/lib/modules:ro)
  HEALTH_ARGS=(--health-cmd '/usr/bin/awg show | grep -q interface || exit 1' \
    --health-interval 15s --health-timeout 5s --health-retries 3 --health-start-period 30s)
fi
docker run -d \
  --name=wg-easy \
  --security-opt=no-new-privileges \
  -e INIT_ENABLED=true \
  -e INIT_USERNAME="${DASHBOARD_USERNAME}" \
  -e INIT_PASSWORD="${DASHBOARD_PASSWORD}" \
  -e INIT_HOST="${PUBLIC_IP}" \
  -e INIT_PORT=443 \
  -e INIT_DNS="${WG_GATEWAY_IP}" \
  -e DISABLE_IPV6=true \
  "${AWG_ENV[@]}" \
  -v /root/.wg-easy:/etc/wireguard \
  "${AWG_MOUNT[@]}" \
  "${HEALTH_ARGS[@]}" \
  -p 443:443/udp \
  -p 127.0.0.1:51821:51821/tcp \
  --cap-add=NET_ADMIN \
  --sysctl="net.ipv4.conf.all.src_valid_mark=1" \
  --sysctl="net.ipv4.ip_forward=1" \
  --restart unless-stopped \
  "${WG_EASY_IMAGE}" > /dev/null

ATTEMPT=0
until [[ "$(docker inspect -f '{{.State.Health.Status}}' wg-easy 2>/dev/null)" == "healthy" ]]; do
  ATTEMPT=$((ATTEMPT+1)); [[ "${ATTEMPT}" -ge 50 ]] && { echo "[fatal] wg-easy did not become healthy - see: docker logs wg-easy" >&2; exit 1; }
  sleep 2
done
docker exec wg-easy awg show wg0 2>/dev/null | grep -qE '^[[:space:]]*jc:' \
  || { echo "[fatal] wg0 is up but amneziawg is not active (no jc: params) - aborting" >&2; exit 1; }
for peer in $(docker exec wg-easy awg show wg0 peers 2>/dev/null); do
  docker exec wg-easy awg set wg0 peer "${peer}" persistent-keepalive 25 2>/dev/null || true
done

DB=/root/.wg-easy/wg-easy.db
GW_HOST=172.17.0.1
DNAT_UP="iptables -t nat -A PREROUTING -d ${WG_GATEWAY_IP} -p udp --dport 53 -j DNAT --to-destination ${GW_HOST}:53; iptables -t nat -A PREROUTING -d ${WG_GATEWAY_IP} -p tcp --dport 53 -j DNAT --to-destination ${GW_HOST}:53; iptables -t nat -A PREROUTING -d ${WG_GATEWAY_IP} -p tcp --dport 80 -j DNAT --to-destination ${GW_HOST}:80; iptables -t nat -A PREROUTING -d ${WG_GATEWAY_IP} -p tcp --dport 443 -j DNAT --to-destination ${GW_HOST}:443;"
DNAT_DOWN="${DNAT_UP//-A PREROUTING/-D PREROUTING}"
CLAMP_UP="iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu;"
CLAMP_DOWN="${CLAMP_UP//-A FORWARD/-D FORWARD}"
if [[ -f "${DB}" ]]; then

  docker stop wg-easy > /dev/null
  sqlite3 "${DB}" "UPDATE hooks_table SET post_up = post_up || ' ${DNAT_UP}' WHERE id='wg0' AND post_up NOT LIKE '%PREROUTING -d ${WG_GATEWAY_IP}%';"
  sqlite3 "${DB}" "UPDATE hooks_table SET post_down = post_down || ' ${DNAT_DOWN}' WHERE id='wg0' AND post_down NOT LIKE '%PREROUTING -d ${WG_GATEWAY_IP}%';"
  sqlite3 "${DB}" "UPDATE hooks_table SET post_up = post_up || ' ${CLAMP_UP}' WHERE id='wg0' AND post_up NOT LIKE '%clamp-mss-to-pmtu%';"
  sqlite3 "${DB}" "UPDATE hooks_table SET post_down = post_down || ' ${CLAMP_DOWN}' WHERE id='wg0' AND post_down NOT LIKE '%clamp-mss-to-pmtu%';"
  sqlite3 "${DB}" "UPDATE interfaces_table SET mtu=1280 WHERE mtu<>1280;"
  sqlite3 "${DB}" "UPDATE user_configs_table SET default_mtu=1280 WHERE default_mtu<>1280;"
  sqlite3 "${DB}" "UPDATE clients_table SET mtu=1280 WHERE mtu<>1280;"
  docker start wg-easy > /dev/null
  for _ in $(seq 1 35); do
    if [[ "$(docker inspect -f '{{.State.Health.Status}}' wg-easy 2>/dev/null)" == "healthy" ]]; then break; fi
    sleep 2
  done
fi

mkdir -p /var/log/caddy
if ! command -v caddy &> /dev/null; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
  apt-get update -qq
  apt-get install -y -qq caddy > /dev/null
fi
chown caddy:caddy /var/log/caddy 2>/dev/null || true

if ! grep -qE '^[[:space:]]*-[[:space:]]*name:' /opt/AdGuardHome/AdGuardHome.yaml 2>/dev/null; then
  AGH_HASH="$(caddy hash-password --plaintext "${ADGUARD_PASSWORD}")"
  systemctl stop AdGuardHome
  if grep -qE '^users:[[:space:]]*\[[[:space:]]*\][[:space:]]*$' /opt/AdGuardHome/AdGuardHome.yaml; then
    sed -i "s#^users:.*#users:\n  - name: ${ADGUARD_USERNAME}\n    password: ${AGH_HASH}#" /opt/AdGuardHome/AdGuardHome.yaml
  elif ! grep -q '^users:' /opt/AdGuardHome/AdGuardHome.yaml; then
    printf 'users:\n  - name: %s\n    password: %s\n' "${ADGUARD_USERNAME}" "${AGH_HASH}" >> /opt/AdGuardHome/AdGuardHome.yaml
  fi
  systemctl start AdGuardHome
fi

cat << CADDY_EOF > /etc/caddy/Caddyfile
{
    default_sni ${PUBLIC_IP}
    servers {
        protocols h1 h2
    }
}

https://${PUBLIC_IP} {
    tls internal
    reverse_proxy 127.0.0.1:51821
    header {
        -Server
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "no-referrer"
    }
    log {
        output file /var/log/caddy/access.log
        format filter {
            wrap json
            fields {
                uri query {
                    delete password
                    delete username
                }
            }
        }
    }
}

https://${ADGUARD_HOST} {
    tls internal
    @public not remote_ip 127.0.0.1/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
    handle @public {
        respond 404
    }
    handle {
        reverse_proxy 127.0.0.1:3000
    }
    header -Server
}

https://${VPN_HOST} {
    tls internal
    @public not remote_ip 127.0.0.1/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
    handle @public {
        respond 404
    }
    handle {
        reverse_proxy 127.0.0.1:51821
    }
    header -Server
}

https://status.${DOMAIN} {
    tls internal
    @public not remote_ip 127.0.0.1/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
    handle @public {
        respond 404
    }
    handle {
        root * /var/www/status
        file_server
        header {
            -Server
            Cache-Control "no-store"
            X-Content-Type-Options "nosniff"
            X-Frame-Options "DENY"
            Referrer-Policy "no-referrer"
        }
    }
}

http://${PUBLIC_IP} {
    redir https://${PUBLIC_IP}{uri}
}

http://${ADGUARD_HOST} {
    redir https://${ADGUARD_HOST}{uri}
}

http://${VPN_HOST} {
    redir https://${VPN_HOST}{uri}
}

http://status.${DOMAIN} {
    redir https://status.${DOMAIN}{uri}
}
CADDY_EOF
mkdir -p /etc/systemd/system/caddy.service.d
printf '[Service]\nRestart=on-failure\nRestartSec=5\n' > /etc/systemd/system/caddy.service.d/override.conf
systemctl daemon-reload
systemctl reload-or-restart caddy

ufw default deny incoming > /dev/null
ufw default allow outgoing > /dev/null
ufw limit "${SSH_PORT}/tcp" comment 'ssh' > /dev/null
ufw allow 80/tcp comment 'http' > /dev/null
ufw allow 443/tcp comment 'https' > /dev/null
ufw allow 443/udp comment 'vpn data' > /dev/null
ufw allow from "${WG_SUBNET}" to any port 53 proto udp comment 'dns' > /dev/null
ufw allow from "${WG_SUBNET}" to any port 53 proto tcp comment 'dns' > /dev/null
ufw allow in on docker0 to any port 53 proto udp comment 'vpn dns via bridge' > /dev/null
ufw allow in on docker0 to any port 53 proto tcp comment 'vpn dns via bridge' > /dev/null
ufw --force enable > /dev/null

if ! grep -q "${WG_SUBNET} -o ${WAN_IF} -j MASQUERADE" /etc/ufw/before.rules 2>/dev/null; then
  cat > /tmp/nat-block.txt << EOF
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s ${WG_SUBNET} -o ${WAN_IF} -j MASQUERADE
COMMIT

EOF
  cat /tmp/nat-block.txt /etc/ufw/before.rules > /tmp/before.rules.new
  mv /tmp/before.rules.new /etc/ufw/before.rules
  rm -f /tmp/nat-block.txt
  ufw reload
fi

cat << 'CADDY_FILTER_EOF' > /etc/fail2ban/filter.d/caddy-auth.conf
[Definition]
failregex = ^.*"remote_ip":"<HOST>".*"status":401.*$
ignoreregex =
CADDY_FILTER_EOF
cat << F2B_EOF > /etc/fail2ban/jail.local
[DEFAULT]
allowipv6 = auto
ignoreip = 127.0.0.1/8 ::1 ${WG_SUBNET}

[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
banaction = %(banaction_allports)s
bantime = 1d
findtime = 1d
maxretry = 5

[caddy-auth]
enabled = true
filter = caddy-auth
logpath = /var/log/caddy/access.log
port = http,https
maxretry = 20
findtime = 10m
bantime = 10m
F2B_EOF
systemctl restart fail2ban
systemctl enable fail2ban > /dev/null 2>&1

mkdir -p /var/www/status

cat << 'STATUS_SH_EOF' > /usr/local/bin/obsidian-status.sh
#!/usr/bin/env python3
import base64
import json
import os
import re
import socket
import subprocess
import time
import urllib.request
from collections import deque

OUT_DIR = "/var/www/status"
DATA = os.path.join(OUT_DIR, "data.json")
TMP = DATA + ".tmp"

ADG_USER = "__ADGUARD_USER__"
ADG_PASS = "__ADGUARD_PASS__"
ADG_STATS_URL = "http://127.0.0.1:3000/control/stats"

FAST_INTERVAL = 1.0
SLOW_EVERY = 30
PEAK_WINDOW = 3600
try:
    PAGE_SIZE = os.sysconf("SC_PAGE_SIZE")
except Exception:
    PAGE_SIZE = 4096

os.makedirs(OUT_DIR, exist_ok=True)


def run(cmd, timeout=5):
    """Run argv, return stdout ('' on any failure/timeout)."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.stdout
    except Exception:
        return ""


def read_file(path):
    try:
        with open(path, "r") as fh:
            return fh.read()
    except Exception:
        return ""


def last_int(line):
    m = re.findall(r"\d+", line)
    return int(m[-1]) if m else 0



st = {
    "cpu_total": None, "cpu_idle": None,
    "net_rx": None, "net_tx": None, "net_t": None,
    "rx_drop": None, "tx_drop": None, "rx_err": None, "tx_err": None,
    "swp_in": None, "swp_out": None, "swp_t": None,
}
peak_hist = deque()

slow = {
    "services": [
        {"name": "VPN", "detail": "wg-easy", "state": "down"},
        {"name": "DNS filter", "detail": "AdGuard", "state": "down"},
        {"name": "Private DNS", "detail": "Unbound", "state": "down"},
        {"name": "Web access", "detail": "Caddy", "state": "down"},
        {"name": "Protection", "detail": "fail2ban", "state": "down"},
    ],
    "dns_response_ms": 0.0, "cache_pct": 0.0, "recursive_median_ms": 0,
    "dns_timeouts": 0, "dns_waiting": 0, "dns_exceeded": 0,
    "cur_bans": 0, "ssh_failures": 0, "dash_failures": 0, "total_bans": 0,
    "firewall": "unknown", "ssh": "unknown", "jails": "none", "bbr": "unknown",
    "oom": 0,
    "wg_pid": None,
}


def cpu_percent():
    total = idle = 0
    for line in read_file("/proc/stat").splitlines():
        if line.startswith("cpu "):
            p = [int(x) for x in line.split()[1:]]
            total = sum(p)
            idle = p[3] + (p[4] if len(p) > 4 else 0)
            break
    pct = 0.0
    if st["cpu_total"] is not None:
        dt = total - st["cpu_total"]
        di = idle - st["cpu_idle"]
        if dt > 0:
            pct = max(0.0, min(100.0, (1 - di / dt) * 100))
    st["cpu_total"], st["cpu_idle"] = total, idle
    return round(pct)


def meminfo():
    m = {}
    for line in read_file("/proc/meminfo").splitlines():
        k, _, rest = line.partition(":")
        rest = rest.strip().split()
        if rest:
            m[k.strip()] = int(rest[0])
    return m


def disk():
    s = os.statvfs("/")
    g = float(1 << 30)
    total = s.f_blocks * s.f_frsize / g
    free = s.f_bavail * s.f_frsize / g
    used = (s.f_blocks - s.f_bfree) * s.f_frsize / g
    return round(total, 1), round(used, 1), round(free, 1)


def vpn_iface():
    tok = run(["docker", "exec", "wg-easy", "awg", "show", "interfaces"], timeout=6).split()
    return tok[0] if tok else "wg0"


def net_stats(iface):
    pid = slow.get("wg_pid")
    if not pid:
        return None
    for l in read_file("/proc/%s/net/dev" % pid).splitlines():
        l = l.strip()
        if l.startswith(iface + ":"):
            f = l.split(":", 1)[1].split()
            if len(f) < 16:
                return None
            try:
                return [int(f[0]), int(f[8]), int(f[3]), int(f[11]), int(f[2]), int(f[10])]
            except Exception:
                return None
    return None


def refresh_services():
    health = run(["docker", "inspect", "-f",
                  "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}",
                  "wg-easy"], timeout=6).strip()
    rc = run(["docker", "inspect", "-f", "{{.RestartCount}}", "wg-easy"], timeout=6).strip()
    rc = rc if rc.isdigit() else "0"
    out = [{
        "name": "VPN",
        "detail": "wg-easy · %s restart%s" % (rc, "" if rc == "1" else "s"),
        "state": "up" if health in ("healthy", "running") else "down",
    }]
    for label, unit, short in (("DNS filter", "AdGuardHome", "AdGuard"),
                               ("Private DNS", "unbound", "Unbound"),
                               ("Web access", "caddy", "Caddy"),
                               ("Protection", "fail2ban", "fail2ban")):
        act = run(["systemctl", "is-active", unit], timeout=4).strip()
        r = run(["systemctl", "show", unit, "-p", "NRestarts", "--value"], timeout=4).strip()
        r = r if r.isdigit() else "0"
        out.append({
            "name": label,
            "detail": "%s · %s restart%s" % (short, r, "" if r == "1" else "s"),
            "state": "up" if act == "active" else "down",
        })
    return out


def unbound_stats():
    d = {}
    for line in run(["unbound-control", "stats_noreset"], timeout=5).splitlines():
        k, sep, v = line.partition("=")
        if sep:
            d[k.strip()] = v.strip()

    def num(k, default=0.0):
        try:
            return float(d[k])
        except Exception:
            return default

    hits, miss = num("total.num.cachehits"), num("total.num.cachemiss")
    tot = hits + miss
    return {
        "cache_pct": round(100.0 * hits / tot, 1) if tot > 0 else 0.0,
        "recursive_median_ms": round(num("total.recursion.time.median") * 1000),
        "timeouts": int(num("total.num.queries_timed_out")),
        "waiting": int(num("total.requestlist.current.user")),
        "exceeded": int(num("total.requestlist.exceeded")),
    }


def adguard_response_ms():
    req = urllib.request.Request(ADG_STATS_URL)
    tok = base64.b64encode(("%s:%s" % (ADG_USER, ADG_PASS)).encode()).decode()
    req.add_header("Authorization", "Basic " + tok)
    with urllib.request.urlopen(req, timeout=3) as r:
        d = json.load(r)
    return round(float(d.get("avg_processing_time", 0.0)) * 1000, 1)


def f2b_jail(jail):
    cur = tf = tb = 0
    for line in run(["fail2ban-client", "status", jail], timeout=5).splitlines():
        if "Currently banned" in line:
            cur = last_int(line)
        elif "Total failed" in line:
            tf = last_int(line)
        elif "Total banned" in line:
            tb = last_int(line)
    return cur, tf, tb


JAIL_LABEL = {"sshd": "SSH", "caddy-auth": "dashboard", "recidive": "repeat offenders"}
JAIL_ORDER = ["sshd", "caddy-auth", "recidive"]


def jails_text():
    active = []
    for line in run(["fail2ban-client", "status"], timeout=5).splitlines():
        if "Jail list" in line:
            _, _, rest = line.partition(":")
            active = [x.strip() for x in rest.replace("\t", " ").split(",") if x.strip()]
            break
    ordered = [j for j in JAIL_ORDER if j in active] + [j for j in active if j not in JAIL_ORDER]
    labels = [JAIL_LABEL.get(j, j) for j in ordered]
    return "%d active: %s" % (len(labels), ", ".join(labels)) if labels else "none active"


def firewall_text():
    out = run(["ufw", "status"], timeout=6)
    if not out.strip():
        conf = read_file("/etc/ufw/ufw.conf")
        return ("Active · only required public ports open"
                if re.search(r"(?mi)^ENABLED=yes", conf) else "Inactive — host firewall is off")
    lines = out.splitlines()
    active = any("active" in l.lower() for l in lines if l.strip().lower().startswith("status:"))
    if not active:
        return "Inactive — host firewall is off"
    expected = {"22/tcp", "80/tcp", "443/tcp", "443/udp"}
    public = set()
    for l in lines:
        if "(v6)" in l:
            continue
        m = re.match(r"^(\S+)\s+(?:ALLOW|LIMIT)\s+IN\s+Anywhere\s*$", l.strip())
        if m:
            public.add(m.group(1))
    if not public:
        return "Active · only required public ports open"
    extra = public - expected
    return ("Active · only required public ports open" if not extra
            else "Active · %d extra public port(s) open" % len(extra))


def ssh_text():
    vals = {}
    for line in run(["sshd", "-T"], timeout=5).splitlines():
        p = line.split(None, 1)
        if len(p) == 2:
            vals[p[0].lower()] = p[1].strip().lower()
    return "Root login disabled" if vals.get("permitrootlogin", "no") == "no" else "Root login ENABLED — review"


def bbr_text():
    v = run(["sysctl", "-n", "net.ipv4.tcp_congestion_control"], timeout=4).strip()
    return "BBR enabled" if v == "bbr" else ("%s (not BBR)" % v if v else "unknown")


def oom_count():
    out = run(["journalctl", "-k", "-q", "--no-pager", "-g",
               "Out of memory|oom-kill:|Killed process"], timeout=8)
    return sum(1 for l in out.splitlines() if l.strip())


def refresh_slow():
    try:
        slow["services"] = refresh_services()
    except Exception:
        pass
    try:
        pid = run(["docker", "inspect", "-f", "{{.State.Pid}}", "wg-easy"], timeout=6).strip()
        slow["wg_pid"] = pid if (pid.isdigit() and pid != "0") else None
    except Exception:
        pass
    try:
        u = unbound_stats()
        slow["cache_pct"] = u["cache_pct"]
        slow["recursive_median_ms"] = u["recursive_median_ms"]
        slow["dns_timeouts"] = u["timeouts"]
        slow["dns_waiting"] = u["waiting"]
        slow["dns_exceeded"] = u["exceeded"]
    except Exception:
        pass
    try:
        slow["dns_response_ms"] = adguard_response_ms()
    except Exception:
        pass
    try:
        s_cur, s_tf, _s_tb = f2b_jail("sshd")
        c_cur, c_tf, _c_tb = f2b_jail("caddy-auth")
        r_cur, _r_tf, _r_tb = f2b_jail("recidive")
        _, _, s_tb = f2b_jail("sshd")
        slow["cur_bans"] = s_cur + c_cur + r_cur
        slow["ssh_failures"] = s_tf
        slow["dash_failures"] = c_tf
        slow["total_bans"] = s_tb + _c_tb + _r_tb
        slow["jails"] = jails_text()
    except Exception:
        pass
    for key, fn in (("firewall", firewall_text), ("ssh", ssh_text),
                    ("bbr", bbr_text), ("oom", oom_count)):
        try:
            slow[key] = fn()
        except Exception:
            pass


def build(iface):
    now = time.monotonic()
    cpu = cpu_percent()
    try:
        load1 = float(read_file("/proc/loadavg").split()[0])
    except Exception:
        load1 = 0.0

    m = meminfo()
    mt, ma = m.get("MemTotal", 0), m.get("MemAvailable", 0)
    mem_pct = round((1 - ma / mt) * 100) if mt else 0
    mem_used, mem_avail = (mt - ma) // 1024, ma // 1024
    swap_used = (m.get("SwapTotal", 0) - m.get("SwapFree", 0)) // 1024

    d_total, d_used, d_free = disk()

    vm = {}
    for line in read_file("/proc/vmstat").splitlines():
        if line.startswith("pswpin ") or line.startswith("pswpout "):
            k, v = line.split()
            vm[k] = int(v)
    swp_act = 0.0
    if st["swp_in"] is not None and st["swp_t"] is not None:
        dtime = now - st["swp_t"]
        if dtime > 0:
            pages = (vm.get("pswpin", 0) - st["swp_in"]) + (vm.get("pswpout", 0) - st["swp_out"])
            swp_act = max(0.0, pages * PAGE_SIZE / dtime / 1e6)
    st["swp_in"], st["swp_out"], st["swp_t"] = vm.get("pswpin", 0), vm.get("pswpout", 0), now

    try:
        uptime = int(float(read_file("/proc/uptime").split()[0]))
    except Exception:
        uptime = 0

    down_mbps = up_mbps = 0.0
    drops = errors = 0
    ns = net_stats(iface)
    if ns:
        rx, tx, rxd, txd, rxe, txe = ns
        if st["net_rx"] is not None and st["net_t"] is not None:
            dtime = now - st["net_t"]
            if dtime > 0:
                down_mbps = max(0.0, (rx - st["net_rx"]) * 8 / dtime / 1e6)
                up_mbps = max(0.0, (tx - st["net_tx"]) * 8 / dtime / 1e6)
            if st["rx_drop"] is not None:
                drops = max(0, (rxd - st["rx_drop"]) + (txd - st["tx_drop"]))
                errors = max(0, (rxe - st["rx_err"]) + (txe - st["tx_err"]))
        st["net_rx"], st["net_tx"], st["net_t"] = rx, tx, now
        st["rx_drop"], st["tx_drop"], st["rx_err"], st["tx_err"] = rxd, txd, rxe, txe
    down_mbps, up_mbps = round(down_mbps, 1), round(up_mbps, 1)

    peak_hist.append((now, max(down_mbps, up_mbps)))
    while peak_hist and now - peak_hist[0][0] > PEAK_WINDOW:
        peak_hist.popleft()
    peak = round(max((x[1] for x in peak_hist), default=0.0), 1)

    return {
        "system": {
            "cpu": cpu, "memoryPct": mem_pct,
            "memoryUsedMiB": int(mem_used), "memoryAvailableMiB": int(mem_avail),
            "diskUsedGiB": d_used, "diskTotalGiB": d_total, "diskFreeGiB": d_free,
            "swapUsedMiB": int(swap_used), "oomKills": slow["oom"],
            "swapActivityMBps": round(swp_act, 1), "load1": round(load1, 2),
            "uptimeSec": uptime,
        },
        "vpn": {
            "downloadMbps": down_mbps, "uploadMbps": up_mbps, "peakMbps": peak,
            "drops": drops, "errors": errors, "iface": iface,
        },
        "dns": {
            "responseMs": slow["dns_response_ms"], "cacheHitPct": slow["cache_pct"],
            "recursiveMedianMs": slow["recursive_median_ms"], "timeouts": slow["dns_timeouts"],
            "waiting": slow["dns_waiting"], "requestlistExceeded": slow["dns_exceeded"],
        },
        "security": {
            "currentBans": slow["cur_bans"], "sshFailures": slow["ssh_failures"],
            "dashboardFailures": slow["dash_failures"], "totalBans": slow["total_bans"],
            "firewall": slow["firewall"], "ssh": slow["ssh"],
            "jails": slow["jails"], "bbr": slow["bbr"],
        },
        "services": slow["services"],
        "allOk": all(s["state"] == "up" for s in slow["services"]),
        "generatedEpoch": int(time.time()),
        "hostname": socket.gethostname(),
    }


def write(data):
    try:
        with open(TMP, "w") as fh:
            json.dump(data, fh, separators=(",", ":"))
        os.replace(TMP, DATA)
        os.chmod(DATA, 0o644)
    except Exception:
        try:
            os.remove(TMP)
        except Exception:
            pass


def main():
    iface = "wg0"
    try:
        iface = vpn_iface()
    except Exception:
        pass
    refresh_slow()
    loop = 0
    while True:
        t0 = time.monotonic()
        if loop % SLOW_EVERY == 0:
            try:
                iface = vpn_iface() or iface
            except Exception:
                pass
            refresh_slow()
        try:
            write(build(iface))
        except Exception:
            pass
        loop += 1
        time.sleep(max(0.5, FAST_INTERVAL - (time.monotonic() - t0)))


if __name__ == "__main__":
    main()
STATUS_SH_EOF
ADGUARD_USERNAME="$ADGUARD_USERNAME" ADGUARD_PASSWORD="$ADGUARD_PASSWORD" python3 - <<'PYEOF'
import os
p="/usr/local/bin/obsidian-status.sh"
s=open(p).read().replace("__ADGUARD_USER__",os.environ["ADGUARD_USERNAME"]).replace("__ADGUARD_PASS__",os.environ["ADGUARD_PASSWORD"])
open(p,"w").write(s)
PYEOF
chown root:root /usr/local/bin/obsidian-status.sh
chmod 700 /usr/local/bin/obsidian-status.sh

cat << 'STATUS_UNIT_EOF' > /etc/systemd/system/obsidian-status.service
[Unit]
Description=Obsidian status dashboard collector
Documentation=https://github.com/obsidian
After=docker.service caddy.service network-online.target
Wants=docker.service

[Service]
Type=simple
ExecStart=/usr/local/bin/obsidian-status.sh
Restart=always
RestartSec=5
Nice=10
IOSchedulingClass=idle
NoNewPrivileges=true
ProtectHome=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=/var/www/status
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
STATUS_UNIT_EOF

cat << 'STATUS_HTML_EOF' > /var/www/status/index.html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Obsidian Gateway</title>
<style>
:root{
  --bg:#f5f7fb;--panel:#ffffff;--soft:#f8fafc;--text:#101828;--muted:#667085;--line:#e5eaf1;
  --accent:#635bff;--accent2:#8a82ff;--cyan:#17a7c7;--green:#16a36f;--amber:#ca8211;--red:#d64d64;
  --shadow:0 10px 30px rgba(16,24,40,.055);--radius:18px
}
:root[data-theme="dark"]{
  --bg:#090c12;--panel:#111720;--soft:#151b24;--text:#eef2f7;--muted:#8f9bac;--line:#252e3a;
  --shadow:0 14px 38px rgba(0,0,0,.26)
}
*{box-sizing:border-box}
html,body{margin:0;min-height:100%;background:var(--bg);color:var(--text);font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
button{font:inherit}
.app{max-width:1460px;margin:auto;padding:22px 24px 40px}
.header{display:flex;justify-content:space-between;align-items:center;gap:16px;margin-bottom:15px}
.brand{display:flex;align-items:center;gap:11px}
.logo{width:41px;height:41px;border-radius:13px;display:grid;place-items:center;background:linear-gradient(145deg,#6159ff,#8a82ff);box-shadow:0 9px 24px rgba(99,91,255,.22)}
.logo svg{width:21px}
.brand h1{margin:0 0 4px;font-size:16px;font-weight:790;letter-spacing:-.03em}
.brand p{margin:0;font-size:10px;color:var(--muted)}
.actions{display:flex;align-items:center;gap:8px}
.gateway-state{height:36px;padding:0 11px;border:1px solid var(--line);border-radius:999px;background:var(--panel);display:flex;align-items:center;gap:7px;font-size:9px;font-weight:780}
.gateway-state i{width:7px;height:7px;border-radius:50%;background:var(--green);box-shadow:0 0 0 4px rgba(22,163,111,.10)}
.icon-btn{width:36px;height:36px;display:grid;place-items:center;border:1px solid var(--line);background:var(--panel);color:var(--text);border-radius:11px;cursor:pointer;transition:all .15s ease}
.icon-btn:hover{background:var(--soft);border-color:var(--accent)}
.icon-btn svg{width:16px}

.sponsor-pill-btn{height:36px;padding:0 13px;border:1px solid rgba(225,29,72,.28);border-radius:999px;background:rgba(225,29,72,.07);color:#e11d48;display:flex;align-items:center;gap:6px;font-size:10px;font-weight:780;cursor:pointer;transition:all .18s cubic-bezier(.4,0,.2,1);outline:none}
.sponsor-pill-btn svg{width:13px;height:13px;fill:currentColor}
.sponsor-pill-btn:hover{background:rgba(225,29,72,.15);border-color:rgba(225,29,72,.45);transform:translateY(-1px);box-shadow:0 4px 12px rgba(225,29,72,.12)}
:root[data-theme="dark"] .sponsor-pill-btn{background:rgba(244,63,94,.12);color:#fb7185;border-color:rgba(244,63,94,.32)}
:root[data-theme="dark"] .sponsor-pill-btn:hover{background:rgba(244,63,94,.22);border-color:rgba(244,63,94,.55);box-shadow:0 4px 14px rgba(244,63,94,.18)}

.service-strip{display:grid;grid-template-columns:repeat(5,1fr);gap:8px;margin-bottom:14px}
.service{display:flex;justify-content:space-between;align-items:center;gap:8px;padding:10px 11px;border:1px solid var(--line);background:var(--panel);border-radius:13px;box-shadow:0 5px 18px rgba(16,24,40,.025)}
.service-left{display:flex;align-items:center;gap:8px;min-width:0}
.service-dot{width:7px;height:7px;border-radius:50%;background:var(--green);flex:0 0 auto}
.service-name{font-size:9px;font-weight:730;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.service-sub{font-size:7px;color:var(--muted);margin-top:2px}
.status{font-size:7px;font-weight:800;padding:4px 6px;border-radius:999px;background:rgba(22,163,111,.10);color:var(--green);white-space:nowrap}

.grid{display:grid;grid-template-columns:repeat(12,1fr);gap:14px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:var(--radius);box-shadow:var(--shadow);padding:17px}
.s5{grid-column:span 5}.s7{grid-column:span 7}.s6{grid-column:span 6}
.head{display:flex;justify-content:space-between;align-items:flex-start;gap:10px}
.title{font-size:11px;font-weight:780;letter-spacing:-.01em}
.desc{font-size:8px;color:var(--muted);line-height:1.45;margin-top:3px}
.tag{font-size:7px;color:var(--muted);padding:4px 7px;border:1px solid var(--line);background:var(--soft);border-radius:999px;white-space:nowrap}

.resource-grid{display:grid;grid-template-columns:repeat(2,1fr);gap:9px;margin-top:12px}
.resource{padding:12px;border:1px solid var(--line);background:var(--soft);border-radius:14px;min-height:103px}
.resource-label{font-size:8px;color:var(--muted)}
.resource-value{font-size:25px;font-weight:810;letter-spacing:-.045em;margin-top:7px}
.resource-value small{font-size:10px;color:var(--muted);font-weight:700;margin-left:2px}
.resource-detail{font-size:8px;color:var(--muted);margin-top:5px;line-height:1.4}
.spark{height:24px;width:100%;margin-top:7px}
.spark polyline{fill:none;stroke:var(--accent);stroke-width:2.1;stroke-linecap:round;stroke-linejoin:round}
.secondary-row{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-top:9px}
.small-metric{padding:9px 10px;border:1px solid var(--line);background:var(--soft);border-radius:12px}
.small-metric b{display:block;font-size:12px}
.small-metric span{display:block;font-size:7px;color:var(--muted);margin-top:3px}

.chart{height:190px;border:1px solid var(--line);background:var(--soft);border-radius:14px;padding:9px;margin-top:11px}
.chart svg{width:100%;height:100%}
.g{stroke:var(--line);stroke-width:1}
.area{fill:rgba(99,91,255,.09)}
.download{fill:none;stroke:var(--accent);stroke-width:2.4}
.upload{fill:none;stroke:var(--cyan);stroke-width:2}
.legend{display:flex;gap:14px;flex-wrap:wrap;font-size:8px;color:var(--muted);margin-top:8px}
.legend i{display:inline-block;width:6px;height:6px;border-radius:50%;background:var(--accent);margin-right:5px}
.legend i.upload-dot{background:var(--cyan)}
.kpis{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-top:10px}
.kpi{padding:10px;border:1px solid var(--line);background:var(--soft);border-radius:12px}
.kpi b{display:block;font-size:14px;letter-spacing:-.02em}
.kpi span{display:block;font-size:8px;color:var(--muted);margin-top:3px}
.kpi.good b{color:var(--green)}

.dns-highlight{display:grid;grid-template-columns:1.05fr .95fr;gap:10px;margin-top:12px}
.big-dns{padding:14px;border:1px solid var(--line);background:var(--soft);border-radius:14px}
.big-dns .eyebrow{font-size:8px;color:var(--muted)}
.big-dns b{font-size:29px;display:block;letter-spacing:-.045em;margin-top:5px}
.big-dns p{font-size:8px;color:var(--muted);margin:4px 0 0;line-height:1.4}
.cachebar{height:7px;border:1px solid var(--line);background:var(--panel);border-radius:999px;overflow:hidden;margin-top:12px}
.cachebar div{height:100%;background:linear-gradient(90deg,var(--accent),var(--accent2));transition:width .6s cubic-bezier(.4,0,.2,1)}
.dns-side{display:grid;grid-template-columns:1fr 1fr;gap:8px}

.security-hero{display:flex;justify-content:space-between;align-items:flex-end;gap:12px;padding:14px;border:1px solid var(--line);background:var(--soft);border-radius:14px;margin-top:12px}
.security-number b{font-size:30px;letter-spacing:-.05em}
.security-number span{font-size:9px;color:var(--muted);margin-left:4px}
.security-copy{font-size:8px;color:var(--muted);line-height:1.45;text-align:right;max-width:170px}
.checks{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-top:9px}
.check{padding:10px;border:1px solid var(--line);background:var(--soft);border-radius:12px}
.check strong{font-size:9px;display:flex;align-items:center;gap:6px}
.check strong i{width:7px;height:7px;border-radius:50%;background:var(--green)}
.check p{margin:4px 0 0;font-size:8px;color:var(--muted);line-height:1.4}

.note-row{display:flex;justify-content:space-between;align-items:center;gap:10px;color:var(--muted);font-size:8px;margin-top:18px;padding:0 2px}
.toast{position:fixed;right:16px;bottom:16px;background:var(--text);color:var(--bg);padding:8px 12px;border-radius:10px;font-size:9px;font-weight:600;opacity:0;transform:translateY(6px);transition:all .2s cubic-bezier(.4,0,.2,1);pointer-events:none;z-index:99999}
.toast.show{opacity:1;transform:none}


.modal-backdrop{position:fixed;inset:0;background:rgba(8,12,20,.65);backdrop-filter:blur(10px);-webkit-backdrop-filter:blur(10px);z-index:99990;display:grid;place-items:center;padding:16px;opacity:0;visibility:hidden;transition:all .2s cubic-bezier(.4,0,.2,1)}
.modal-backdrop.active{opacity:1;visibility:visible}
.modal-card{width:min(540px,100%);max-height:calc(100vh - 32px);overflow-y:auto;-webkit-overflow-scrolling:touch;box-sizing:border-box;background:var(--panel);border:1px solid var(--line);border-radius:22px;box-shadow:0 24px 60px rgba(0,0,0,.35);padding:24px;transform:scale(0.96) translateY(8px);transition:all .22s cubic-bezier(.34,1.56,.64,1);color:var(--text)}
.modal-backdrop.active .modal-card{transform:scale(1) translateY(0)}
.modal-head{display:flex;justify-content:space-between;align-items:center;margin-bottom:14px}
.modal-badge{display:inline-flex;align-items:center;gap:6px;font-size:10px;font-weight:780;color:#e11d48;padding:4px 9px;border-radius:999px;background:rgba(225,29,72,.10);border:1px solid rgba(225,29,72,.22)}
:root[data-theme="dark"] .modal-badge{color:#fb7185;background:rgba(244,63,94,.12);border-color:rgba(244,63,94,.28)}
.modal-close{width:32px;height:32px;display:grid;place-items:center;border-radius:10px;border:1px solid var(--line);background:var(--soft);color:var(--text);font-size:18px;cursor:pointer;line-height:1;transition:all .15s ease}
.modal-close:hover{background:var(--line)}
.modal-title{margin:0 0 6px;font-size:17px;font-weight:800;letter-spacing:-.03em}
.modal-sub{margin:0 0 12px;font-size:10px;color:var(--muted);line-height:1.4}
.modal-desc{font-size:10.5px;color:var(--text);line-height:1.55;padding:12px;border-radius:12px;background:var(--soft);border:1px solid var(--line);margin-bottom:16px}
.upi-card{padding:14px;border-radius:14px;background:linear-gradient(145deg,rgba(99,91,255,.05),rgba(23,167,199,.05));border:1px solid rgba(99,91,255,.2);margin-bottom:12px}
.upi-card-head{display:flex;justify-content:space-between;align-items:center;margin-bottom:8px}
.upi-title{font-size:11px;font-weight:780;color:var(--text);display:flex;align-items:center;gap:6px}
.upi-fee-tag{font-size:8px;font-weight:750;padding:2px 7px;border-radius:999px;background:rgba(22,163,111,.12);color:var(--green);border:1px solid rgba(22,163,111,.25)}
.upi-copy-row{display:flex;align-items:center;gap:8px;background:var(--panel);border:1px solid var(--line);padding:7px 10px;border-radius:10px;margin-bottom:10px}
.upi-val{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;font-size:11px;font-weight:700;color:var(--accent);flex:1;letter-spacing:.02em}
.copy-btn-action{padding:5px 11px;border-radius:7px;border:1px solid var(--line);background:var(--soft);color:var(--text);font-size:9.5px;font-weight:700;cursor:pointer;display:inline-flex;align-items:center;gap:5px;transition:all .15s ease}
.copy-btn-action:hover{background:var(--accent);color:#fff;border-color:var(--accent)}
.upi-open-btn{width:100%;height:36px;display:flex;align-items:center;justify-content:center;gap:7px;border-radius:10px;background:linear-gradient(135deg,#6159ff,#8a82ff);color:#fff;text-decoration:none;font-size:11px;font-weight:780;box-shadow:0 6px 18px rgba(99,91,255,.25);transition:all .16s ease}
.upi-open-btn:hover{transform:translateY(-1px);box-shadow:0 8px 22px rgba(99,91,255,.35)}
.platforms-grid{display:grid;grid-template-columns:1fr 1fr;gap:9px}
.platform-btn{display:flex;align-items:center;justify-content:space-between;padding:10px 12px;border:1px solid var(--line);background:var(--soft);border-radius:12px;color:var(--text);text-decoration:none;transition:all .16s ease}
.platform-btn:hover{border-color:var(--accent);transform:translateY(-1px);background:var(--panel)}
.platform-btn-left{display:flex;align-items:center;gap:8px}
.platform-icon{width:22px;height:22px;border-radius:7px;display:grid;place-items:center;background:var(--panel);border:1px solid var(--line);font-size:12px}
.platform-name{font-size:10px;font-weight:780}
.platform-sub{font-size:7.5px;color:var(--muted);margin-top:1px}
.platform-arrow{font-size:11px;color:var(--muted);font-weight:700}
.modal-footer{margin-top:14px;padding-top:10px;border-top:1px solid var(--line);font-size:8px;color:var(--muted);line-height:1.4;text-align:center}

@media(max-width:1080px){
  .service-strip{grid-template-columns:repeat(3,1fr)}
  .s5,.s7,.s6{grid-column:span 12}
}
@media(max-width:720px){
  .app{padding:14px 12px 28px}
  .brand p{max-width:220px}
  .gateway-state span{display:none}
  .service-strip{grid-template-columns:1fr 1fr}
  .grid{gap:10px}
  .dns-highlight{grid-template-columns:1fr}
  .platforms-grid{grid-template-columns:1fr}
}
@media(max-width:470px){
  .brand p{display:none}
  .service-strip{grid-template-columns:1fr}
  .resource-grid{grid-template-columns:1fr}
  .secondary-row,.kpis{grid-template-columns:1fr 1fr}
  .secondary-row>*:last-child,.kpis>*:last-child{grid-column:span 2}
  .checks{grid-template-columns:1fr}
  .note-row{display:block;line-height:1.8}
}
</style>
</head>
<body>
<div class="app">
<header class="header">
  <div class="brand">
    <div class="logo">
      <svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8">
        <path d="M12 3l7 3v5c0 4.4-2.5 7.9-7 10-4.5-2.1-7-5.6-7-10V6l7-3Z"/>
        <path d="m9.3 12.2 1.8 1.8 3.7-4.1"/>
      </svg>
    </div>
    <div>
      <h1>Obsidian Gateway</h1>
      <p>Private VPN gateway</p>
    </div>
  </div>
  <div class="actions">
    <button class="sponsor-pill-btn" id="sponsorOpen" aria-label="Sponsor project" title="Support developer">
      <svg viewBox="0 0 24 24"><path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/></svg>
      <span>Support</span>
    </button>
    <div class="gateway-state" id="gatewayState"><i></i><span>GATEWAY ONLINE</span></div>
    <button class="icon-btn" id="refresh" aria-label="Refresh">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
        <path d="M20 11a8 8 0 0 0-15.2-3.9"/><path d="M4 4v4h4"/>
        <path d="M4 13a8 8 0 0 0 15.2 3.9"/><path d="M20 20v-4h-4"/>
      </svg>
    </button>
    <button class="icon-btn" id="theme" aria-label="Theme">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
        <circle cx="12" cy="12" r="4"/>
        <path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>
      </svg>
    </button>
  </div>
</header>

<section class="service-strip" id="serviceStrip"></section>

<main class="grid">
  <section class="card s5">
    <div class="head">
      <div>
        <div class="title">Server</div>
        <div class="desc">Only the resources that can actually stop this 1 GB VM from working.</div>
      </div>
      <span class="tag" id="uptime">Uptime 18d 07h</span>
    </div>

    <div class="resource-grid">
      <div class="resource">
        <div class="resource-label">CPU usage</div>
        <div class="resource-value" id="cpu">21<small>%</small></div>
        <div class="resource-detail" id="cpuDetail">1-minute load: 0.22</div>
        <svg class="spark" viewBox="0 0 240 24" preserveAspectRatio="none"><polyline id="cpuSpark" points="0,19 22,17 44,19 66,13 88,16 110,10 132,12 154,6 176,11 198,8 220,10 240,5"/></svg>
      </div>

      <div class="resource">
        <div class="resource-label">Memory usage</div>
        <div class="resource-value" id="memory">68<small>%</small></div>
        <div class="resource-detail" id="memoryDetail">688 MB used · 336 MB available</div>
        <svg class="spark" viewBox="0 0 240 24" preserveAspectRatio="none"><polyline id="memSpark" points="0,13 22,12 44,13 66,12 88,12 110,10 132,11 154,10 176,9 198,10 220,8 240,9"/></svg>
      </div>

      <div class="resource">
        <div class="resource-label">Server disk</div>
        <div class="resource-value" id="diskUsed">5.2<small>GB used</small></div>
        <div class="resource-detail" id="diskDetail">of 30 GB · 24.8 GB free</div>
        <svg class="spark" viewBox="0 0 240 24" preserveAspectRatio="none"><polyline points="0,17 30,17 60,16 90,16 120,15 150,14 180,13 210,13 240,12"/></svg>
      </div>

      <div class="resource">
        <div class="resource-label">Memory pressure</div>
        <div class="resource-value" id="swapUsed">112<small>MB swap</small></div>
        <div class="resource-detail" id="pressureDetail">0 OOM kills · no active swapping</div>
        <svg class="spark" viewBox="0 0 240 24" preserveAspectRatio="none"><polyline points="0,18 25,18 50,18 75,18 100,17 125,17 150,17 175,17 200,17 225,17 240,17"/></svg>
      </div>
    </div>
  </section>

  <section class="card s7">
    <div class="head">
      <div>
        <div class="title">VPN traffic</div>
        <div class="desc">Traffic through the tunnel as a whole. Device details remain in wg-easy.</div>
      </div>
      <span class="tag" id="trafficTag">Live</span>
    </div>

    <div class="chart">
      <svg viewBox="0 0 720 160" preserveAspectRatio="none">
        <line class="g" x1="0" y1="30" x2="720" y2="30"/>
        <line class="g" x1="0" y1="80" x2="720" y2="80"/>
        <line class="g" x1="0" y1="130" x2="720" y2="130"/>
        <path id="areaPath" class="area" d="M0 135L40 124L80 130L120 108L160 121L200 90L240 99L280 75L320 93L360 69L400 85L440 53L480 73L520 63L560 79L600 54L640 58L680 44L720 52L720 160H0Z"/>
        <path id="dlPath" class="download" d="M0 135L40 124L80 130L120 108L160 121L200 90L240 99L280 75L320 93L360 69L400 85L440 53L480 73L520 63L560 79L600 54L640 58L680 44L720 52"/>
        <path id="ulPath" class="upload" d="M0 145L40 138L80 141L120 132L160 136L200 117L240 124L280 108L320 117L360 103L400 113L440 92L480 106L520 98L560 110L600 94L640 99L680 87L720 92"/>
      </svg>
    </div>

    <div class="legend">
      <span><i></i>Download</span>
      <span><i class="upload-dot"></i>Upload</span>
      <span>Measured from the AmneziaWG interface</span>
    </div>

    <div class="kpis">
      <div class="kpi"><b id="downloadNow">8.7 Mbps</b><span>Download now</span></div>
      <div class="kpi"><b id="uploadNow">9.9 Mbps</b><span>Upload now</span></div>
      <div class="kpi"><b id="peakSpeed">26.4 Mbps</b><span>Peak speed / 1 hour</span></div>
    </div>
    <div class="kpis">
      <div class="kpi good"><b id="packetDrops">0</b><span>Packets dropped</span></div>
      <div class="kpi good"><b id="packetErrors">0</b><span>Packet errors</span></div>
      <div class="kpi"><b id="vpnInterface">awg0</b><span>VPN interface</span></div>
    </div>
  </section>

  <section class="card s6">
    <div class="head">
      <div>
        <div class="title">DNS</div>
        <div class="desc">The numbers that tell you whether private DNS is fast or struggling.</div>
      </div>
      <span class="tag">AdGuard → Unbound</span>
    </div>

    <div class="dns-highlight">
      <div class="big-dns">
        <div class="eyebrow">Average DNS response</div>
        <b id="dnsResponse">1.8 ms</b>
        <p>What a device typically waits for a DNS answer.</p>
        <div class="cachebar"><div id="cacheFill" style="width:91.4%"></div></div>
        <p><strong id="cachePct">91.4%</strong> answered from Unbound cache</p>
      </div>

      <div class="dns-side">
        <div class="small-metric"><b id="freshLookup">18 ms</b><span>Typical fresh internet lookup</span></div>
        <div class="small-metric"><b id="dnsTimeouts">0</b><span>DNS requests timed out</span></div>
        <div class="small-metric"><b id="dnsWaiting">0</b><span>DNS requests waiting now</span></div>
        <div class="small-metric"><b id="dnsDropped">0</b><span>Dropped because resolver was full</span></div>
      </div>
    </div>
  </section>

  <section class="card s6">
    <div class="head">
      <div>
        <div class="title">Protection</div>
        <div class="desc">Concrete security numbers instead of a generic “secure” badge.</div>
      </div>
      <span class="tag">fail2ban + UFW + SSH</span>
    </div>

    <div class="security-hero">
      <div class="security-number">
        <b id="blockedNow">1</b><span>IP blocked now</span>
      </div>
      <div class="security-copy">An IP is shown here only while fail2ban is actively banning it.</div>
    </div>

    <div class="kpis">
      <div class="kpi"><b id="sshFailures">14</b><span>Failed SSH attempts since protection started</span></div>
      <div class="kpi"><b id="dashboardFailures">3</b><span>Failed dashboard logins since protection started</span></div>
      <div class="kpi"><b id="totalBans">3</b><span>IP bans since protection started</span></div>
    </div>

    <div class="checks">
      <div class="check"><strong><i></i>Firewall</strong><p id="firewallState">Active · only required public ports open</p></div>
      <div class="check"><strong><i></i>SSH</strong><p id="sshState">Root login disabled</p></div>
      <div class="check"><strong><i></i>Protection rules</strong><p id="jailState">3 active: SSH, dashboard, repeat offenders</p></div>
      <div class="check"><strong><i></i>Network tuning</strong><p id="bbrState">BBR enabled</p></div>
    </div>
  </section>
</main>

<div class="note-row">
  <span>Obsidian Gateway · Crafted by <a href="https://github.com/meel-ayush" target="_blank" rel="noopener noreferrer" style="color:var(--accent);text-decoration:none;font-weight:700">Ayush Meel</a> · <button id="noteSponsorBtn" style="background:none;border:none;color:var(--accent);cursor:pointer;padding:0;margin:0;font:inherit;font-size:inherit;line-height:inherit;display:inline;vertical-align:baseline"><span style="text-decoration:underline">Support this project</span> <span style="text-decoration:none;display:inline-block">❤️</span></button> · infrastructure only</span>
  <span id="updated">Updated just now</span>
</div>
</div>


<div class="modal-backdrop" id="sponsorModal" role="dialog" aria-modal="true" aria-labelledby="sponsorTitle">
  <div class="modal-card">
    <div class="modal-head">
      <div class="modal-badge">
        <svg viewBox="0 0 24 24" width="12" height="12" fill="currentColor"><path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/></svg>
        <span>Support the Creator</span>
      </div>
      <button class="modal-close" id="sponsorClose" aria-label="Close dialog">&times;</button>
    </div>

    <h2 class="modal-title" id="sponsorTitle">Support the Engineering • Keep it 100% Independent</h2>
    <p class="modal-sub">Engineered by <strong>Ayush Meel</strong> • Zero venture funding • Zero corporate telemetry • 100% transparent shell craft</p>

    <div class="modal-desc">
      <div style="font-size:11px;font-weight:780;color:#f1f5f9;margin-bottom:6px">"Why pay $120/year for commercial VPNs that sell your browsing data?"</div>
      If Obsidian saved your weekend from configuration hell, MTU blackholes, or handshake drops on restrictive networks — consider dropping a small tip to back the developer. There are no corporate paywalls or venture capital here. Every contribution directly funds VPS test nodes, upstream AmneziaWG kernel tracking, and keeping this private gateway free and unblockable for everyone.
    </div>

    <div class="upi-card">
      <div class="upi-card-head">
        <div class="upi-title">
          <span>⚡ Instant UPI Transfer</span>
          <span class="upi-fee-tag">0% Fee • Instant</span>
        </div>
      </div>
      <p style="font-size:8.5px;color:var(--muted);margin:0 0 8px;line-height:1.4">Direct support from any Indian UPI app — Google Pay, PhonePe, Paytm, BHIM, Cred, or bank apps.</p>
      <div class="upi-copy-row">
        <span class="upi-val" id="upiText">ayushmeel@ptyes</span>
        <button class="copy-btn-action" id="copyUpiBtn">
          <svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg>
          <span id="copyUpiLabel">Copy UPI</span>
        </button>
      </div>
      <a href="upi://pay?pa=ayushmeel@ptyes&pn=Ayush%20Meel&cu=INR&tn=Support%20Obsidian%20Gateway%20by%20Ayush%20Meel" class="upi-open-btn" id="upiIntentBtn">
        <span>Open in any UPI App ↗</span>
      </a>
    </div>

    <div class="platforms-grid">
      <a href="https://github.com/sponsors/meel-ayush" target="_blank" rel="noopener noreferrer" class="platform-btn">
        <div class="platform-btn-left">
          <div class="platform-icon">🐙</div>
          <div>
            <div class="platform-name">GitHub Sponsors</div>
            <div class="platform-sub">Support Ayush Meel on GitHub</div>
          </div>
        </div>
        <div class="platform-arrow">↗</div>
      </a>

      <a href="https://patreon.com/meel_ayush" target="_blank" rel="noopener noreferrer" class="platform-btn">
        <div class="platform-btn-left">
          <div class="platform-icon">🎨</div>
          <div>
            <div class="platform-name">Patreon</div>
            <div class="platform-sub">Support Ayush Meel on Patreon</div>
          </div>
        </div>
        <div class="platform-arrow">↗</div>
      </a>
    </div>

    <div class="modal-footer">
      Every contribution directly covers VPS lab expenses, domain maintenance, and independent open-source engineering. Thank you for making open source sustainable!
    </div>
  </div>
</div>

<div class="toast" id="toast"></div>

<script>
const SAMPLE={
  system:{cpu:21,memoryPct:68,memoryUsedMiB:688,memoryAvailableMiB:336,diskUsedGiB:5.2,diskTotalGiB:30,diskFreeGiB:24.8,swapUsedMiB:112,oomKills:0,swapActivityMBps:0,load1:.22,uptimeSec:1577220},
  vpn:{downloadMbps:8.7,uploadMbps:9.9,peakMbps:26.4,drops:0,errors:0,iface:"awg0"},
  dns:{responseMs:1.8,cacheHitPct:91.4,recursiveMedianMs:18,timeouts:0,waiting:0,requestlistExceeded:0},
  security:{currentBans:1,sshFailures:14,dashboardFailures:3,totalBans:3,firewall:"Active · only required public ports open",ssh:"Root login disabled",jails:"3 active: SSH, dashboard, repeat offenders",bbr:"BBR enabled"},
  services:[
    {name:"VPN",detail:"wg-easy · 0 restarts",state:"up"},
    {name:"DNS filter",detail:"AdGuard · 0 restarts",state:"up"},
    {name:"Private DNS",detail:"Unbound · 0 restarts",state:"up"},
    {name:"Web access",detail:"Caddy · 0 restarts",state:"up"},
    {name:"Protection",detail:"fail2ban · 0 restarts",state:"up"}
  ]
};

const $=id=>document.getElementById(id);

function showToast(msg){
  const t=$("toast");
  if(!t)return;
  t.textContent=msg;
  t.classList.add("show");
  setTimeout(()=>t.classList.remove("show"),1600);
}

function animateNum(id,to,fmt){
  const el=$(id);
  if(!el)return;
  if(typeof to!=="number"||isNaN(to)){el.innerHTML=fmt(to||0);return;}
  const from=(el._cur==null)?to:el._cur,start=performance.now(),dur=850;
  if(el._raf)cancelAnimationFrame(el._raf);
  el._raf=requestAnimationFrame(function step(now){
    const t=Math.min(1,(now-start)/dur),e=1-Math.pow(1-t,3);
    el._cur=from+(to-from)*e;el.innerHTML=fmt(el._cur);
    if(t<1){el._raf=requestAnimationFrame(step);}else{el._cur=to;}
  });
}
const HIST=90,SP=30;let histD=[],histU=[],histCpu=[],histMem=[];
function chartPath(arr,scale,close){
  const L=arr.length;if(L<1)return"";
  const X=i=>(L<=1?0:(i/(L-1))*720),Y=v=>150-Math.max(0,Math.min(1,v/scale))*140;
  let d="M"+X(0).toFixed(1)+" "+Y(arr[0]).toFixed(1);
  for(let i=1;i<L;i++)d+="L"+X(i).toFixed(1)+" "+Y(arr[i]).toFixed(1);
  if(close)d+="L"+X(L-1).toFixed(1)+" 150L"+X(0).toFixed(1)+" 150Z";
  return d;
}
function drawChart(){
  if(!histD.length)return;
  const scale=Math.max(1,Math.max.apply(null,histD),Math.max.apply(null,histU))*1.15;
  const a=$("areaPath"),dl=$("dlPath"),ul=$("ulPath");
  if(dl)dl.setAttribute("d",chartPath(histD,scale,false));
  if(ul)ul.setAttribute("d",chartPath(histU,scale,false));
  if(a)a.setAttribute("d",chartPath(histD,scale,true));
}
function drawSpark(id,arr,scale){
  const el=$(id);if(!el||arr.length<2)return;
  const L=arr.length,X=i=>(i/(L-1))*240,Y=v=>23-Math.max(0,Math.min(1,v/scale))*21;
  let p="";for(let i=0;i<L;i++)p+=(i?" ":"")+X(i).toFixed(1)+","+Y(arr[i]).toFixed(1);
  el.setAttribute("points",p);
}
function pushHist(v,cpu,mem){
  histD.push(v.downloadMbps);histU.push(v.uploadMbps);histCpu.push(cpu);histMem.push(mem);
  if(histD.length>HIST){histD.shift();histU.shift();}
  if(histCpu.length>SP){histCpu.shift();histMem.shift();}
  drawChart();drawSpark("cpuSpark",histCpu,100);drawSpark("memSpark",histMem,100);
}
function uptime(sec){const d=Math.floor(sec/86400);sec%=86400;const h=Math.floor(sec/3600);return d+"d "+String(h).padStart(2,"0")+"h"}
function esc(s){return String(s).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]))}
function agoText(epoch){
  if(!epoch)return"Updated just now";
  const age=Math.max(0,Math.floor(Date.now()/1000)-epoch);
  if(age<5)return"Updated just now";
  if(age<60)return"Updated "+age+"s ago";
  if(age<3600)return"Updated "+Math.floor(age/60)+"m ago";
  return"Updated "+Math.floor(age/3600)+"h ago";
}
function render(d,fromSample){
  const s=d.system,v=d.vpn,n=d.dns,x=d.security;

  $("uptime").textContent="Uptime "+uptime(s.uptimeSec);
  animateNum("cpu",s.cpu,v=>Math.round(v)+"<small>%</small>");
  $("cpuDetail").textContent="1-minute load: "+s.load1.toFixed(2);
  animateNum("memory",s.memoryPct,v=>Math.round(v)+"<small>%</small>");
  $("memoryDetail").textContent=s.memoryUsedMiB+" MB used · "+s.memoryAvailableMiB+" MB available";
  animateNum("diskUsed",s.diskUsedGiB,v=>v.toFixed(1)+"<small>GB used</small>");
  $("diskDetail").textContent="of "+s.diskTotalGiB+" GB · "+s.diskFreeGiB.toFixed(1)+" GB free";
  animateNum("swapUsed",s.swapUsedMiB,v=>Math.round(v)+"<small>MB swap</small>");
  $("pressureDetail").textContent=s.oomKills+" OOM kills · "+(s.swapActivityMBps===0?"no active swapping":s.swapActivityMBps+" MB/s swap activity");

  animateNum("downloadNow",v.downloadMbps,x=>x.toFixed(1)+" Mbps");
  animateNum("uploadNow",v.uploadMbps,x=>x.toFixed(1)+" Mbps");
  animateNum("peakSpeed",v.peakMbps,x=>x.toFixed(1)+" Mbps");
  $("packetDrops").textContent=v.drops;
  $("packetErrors").textContent=v.errors;
  $("vpnInterface").textContent=v.iface;

  animateNum("dnsResponse",n.responseMs,v=>v.toFixed(1)+" ms");
  animateNum("cachePct",n.cacheHitPct,v=>v.toFixed(1)+"%");
  $("cacheFill").style.width=Math.min(100,Math.max(0,n.cacheHitPct))+"%";
  animateNum("freshLookup",n.recursiveMedianMs,v=>Math.round(v)+" ms");
  $("dnsTimeouts").textContent=n.timeouts;
  $("dnsWaiting").textContent=n.waiting;
  $("dnsDropped").textContent=n.requestlistExceeded;

  $("blockedNow").textContent=x.currentBans;
  $("sshFailures").textContent=x.sshFailures;
  $("dashboardFailures").textContent=x.dashboardFailures;
  $("totalBans").textContent=x.totalBans;
  $("firewallState").textContent=x.firewall;
  $("sshState").textContent=x.ssh;
  $("jailState").textContent=x.jails;
  $("bbrState").textContent=x.bbr;

  const strip=$("serviceStrip");strip.innerHTML="";
  let allUp=true;
  d.services.forEach(svc=>{
    const up=svc.state==="up";if(!up)allUp=false;
    const el=document.createElement("div");el.className="service";
    const dot=up?"var(--green)":"var(--red)";
    const badge=up?"":"background:rgba(214,77,100,.12);color:var(--red)";
    el.innerHTML=`<div class="service-left"><i class="service-dot" style="background:${dot}"></i><div><div class="service-name">${esc(svc.name)}</div><div class="service-sub">${esc(svc.detail)}</div></div></div><span class="status" style="${badge}">${up?"RUNNING":"DOWN"}</span>`;
    strip.appendChild(el);
  });

  const ok=(d.allOk!==undefined)?d.allOk:allUp;
  const pill=$("gatewayState"),pdot=pill.querySelector("i"),plabel=pill.querySelector("span");
  plabel.textContent=ok?"GATEWAY ONLINE":"DEGRADED";
  pdot.style.background=ok?"var(--green)":"var(--red)";
  pdot.style.boxShadow=ok?"0 0 0 4px rgba(22,163,111,.10)":"0 0 0 4px rgba(214,77,100,.12)";

  $("updated").textContent=agoText(d.generatedEpoch);

  if(!fromSample)pushHist(v,s.cpu,s.memoryPct);
}

let inFlight=false,hasReal=false,lastEpoch=-1;
async function refresh(){
  if(inFlight)return;
  inFlight=true;
  try{
    const r=await fetch("data.json",{cache:"no-store",headers:{Accept:"application/json"}});
    if(!r.ok)throw new Error();
    const d=await r.json();
    hasReal=true;
    if(d.generatedEpoch!==lastEpoch){lastEpoch=d.generatedEpoch;render(d);}
    else{$("updated").textContent=agoText(d.generatedEpoch);}
  }catch(e){
    if(!hasReal)render(SAMPLE,true);   
  }finally{inFlight=false}
}

$("refresh").onclick=()=>{
  refresh();
  showToast("Updated");
};
$("theme").onclick=()=>{
  const root=document.documentElement,next=root.dataset.theme==="dark"?"light":"dark";
  root.dataset.theme=next;localStorage.setItem("obsidian-theme",next)
};
document.documentElement.dataset.theme=localStorage.getItem("obsidian-theme")||(matchMedia("(prefers-color-scheme:dark)").matches?"dark":"light");


const sModal=$("sponsorModal");
function openSponsorModal(){
  if(sModal)sModal.classList.add("active");
}
function closeSponsorModal(){
  if(sModal)sModal.classList.remove("active");
}
$("sponsorOpen").onclick=openSponsorModal;
if($("noteSponsorBtn"))$("noteSponsorBtn").onclick=openSponsorModal;
$("sponsorClose").onclick=closeSponsorModal;
sModal.onclick=e=>{if(e.target===sModal)closeSponsorModal();};
document.addEventListener("keydown",e=>{if(e.key==="Escape"&&sModal.classList.contains("active"))closeSponsorModal();});

$("copyUpiBtn").onclick=()=>{
  const upiId="ayushmeel@ptyes";
  if(navigator.clipboard&&navigator.clipboard.writeText){
    navigator.clipboard.writeText(upiId).then(()=>{
      $("copyUpiLabel").textContent="Copied! ✨";
      showToast("UPI ID copied: ayushmeel@ptyes");
      setTimeout(()=>{$("copyUpiLabel").textContent="Copy UPI";},2000);
    }).catch(()=>{
      prompt("Copy UPI ID:",upiId);
    });
  }else{
    prompt("Copy UPI ID:",upiId);
  }
};

render(SAMPLE,true);refresh();setInterval(refresh,1000);
</script>
</body>
</html>

STATUS_HTML_EOF
chmod 755 /var/www/status
chmod 644 /var/www/status/index.html

systemctl daemon-reload
if systemctl enable --now obsidian-status > /dev/null 2>&1; then
  echo "[OK] health dashboard live (vpn-only status site)"
else
  echo "[!] obsidian-status failed to start - check: journalctl -u obsidian-status"
fi

cat << UNINSTALL_EOF > /usr/local/bin/uninstall-server
#!/usr/bin/env bash
set -uo pipefail
[[ "\${EUID}" -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
docker rm -f wg-easy >/dev/null 2>&1
docker rmi ${WG_EASY_IMAGE} >/dev/null 2>&1
rm -rf /root/.wg-easy
rmmod amneziawg 2>/dev/null
while read -r v; do [[ -n "\${v}" ]] && dkms remove -m amneziawg -v "\${v}" --all >/dev/null 2>&1; true; done < <(dkms status 2>/dev/null | grep '^amneziawg' | sed -E 's#^amneziawg/([^,]+),.*#\1#' | sort -u)
rm -rf /usr/src/amneziawg-* /tmp/amneziawg-build /tmp/unbound-build
rm -f /usr/local/bin/docker-user-vpn-fix.sh
systemctl stop docker >/dev/null 2>&1
apt-get purge -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-ce-rootless-extras docker-buildx-plugin docker-model-plugin >/dev/null 2>&1
rm -rf /var/lib/docker /etc/docker /etc/systemd/system/docker.service.d
rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
systemctl disable --now caddy >/dev/null 2>&1
apt-get purge -y -qq caddy >/dev/null 2>&1
rm -rf /etc/caddy /var/lib/caddy /var/log/caddy /etc/systemd/system/caddy.service.d
rm -f /etc/apt/sources.list.d/caddy-stable.list /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/fail2ban/filter.d/caddy-auth.conf
systemctl disable --now obsidian-status >/dev/null 2>&1
rm -f /etc/systemd/system/obsidian-status.service /usr/local/bin/obsidian-status.sh
rm -rf /var/www/status
[ -x /opt/AdGuardHome/AdGuardHome ] && /opt/AdGuardHome/AdGuardHome -s uninstall >/dev/null 2>&1
systemctl disable AdGuardHome >/dev/null 2>&1
rm -rf /opt/AdGuardHome /etc/systemd/system/AdGuardHome.service.d
systemctl disable --now unbound >/dev/null 2>&1
apt-get purge -y -qq unbound >/dev/null 2>&1
rm -f /usr/sbin/unbound /usr/sbin/unbound-checkconf /usr/sbin/unbound-control /usr/sbin/unbound-control-setup /usr/sbin/unbound-anchor
rm -rf /etc/unbound /run/unbound /etc/systemd/system/unbound.service.d
rm -f /etc/resolv.conf
systemctl enable --now systemd-resolved >/dev/null 2>&1
sleep 1
[ -e /etc/resolv.conf ] || printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
ufw --force reset >/dev/null 2>&1
ufw --force disable >/dev/null 2>&1
rm -f /etc/fail2ban/jail.local
systemctl restart fail2ban >/dev/null 2>&1
rm -f /etc/sysctl.d/99-edge-performance.conf /etc/modules-load.d/bbr.conf /etc/modules-load.d/amneziawg.conf /etc/apt/apt.conf.d/20auto-upgrades
sysctl --system >/dev/null 2>&1
sed -i 's/^PermitRootLogin no/#PermitRootLogin prohibit-password/' /etc/ssh/sshd_config 2>/dev/null
sed -i '/^ClientAliveInterval 300\$/d;/^ClientAliveCountMax 2\$/d;/^MaxAuthTries 4\$/d;/^LoginGraceTime 30\$/d;/^PermitEmptyPasswords no\$/d;/^PasswordAuthentication yes\$/d;/^AllowUsers /d' /etc/ssh/sshd_config 2>/dev/null
systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1
systemctl daemon-reload >/dev/null 2>&1
apt-get update -qq >/dev/null 2>&1
echo "restored to pre-deployment state"
rm -- "\$0"
UNINSTALL_EOF
chmod +x /usr/local/bin/uninstall-server

printf '#!/usr/bin/env bash\nWG_GATEWAY_IP=%s\nGW_HOST=172.17.0.1\n' "${WG_GATEWAY_IP}" > /usr/local/bin/reset-server
cat << 'RESET_EOF' >> /usr/local/bin/reset-server
set -uo pipefail
WG_DATA=/root/.wg-easy
DB="${WG_DATA}/wg-easy.db"

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "reset-server: run as root (sudo reset-server)" >&2; exit 1; }
[[ -d "${WG_DATA}" ]] || { echo "reset-server: ${WG_DATA} not found - is this the gateway?" >&2; exit 1; }

if [[ "${1:-}" != "-y" ]]; then
  echo "This WIPES all VPN device configs, DNS history, ban history, and logs."
  echo "Service configs and admin logins are kept. This cannot be undone."
  read -r -p "Type RESET to continue: " ans
  [[ "${ans:-}" == "RESET" ]] || { echo "aborted."; exit 1; }
fi
log(){ echo "[reset-server] $*"; }

log "wg-easy: wiping device configs + reinit fresh..."
docker stop wg-easy >/dev/null 2>&1
rm -f "${WG_DATA}"/*
docker start wg-easy >/dev/null 2>&1
for i in $(seq 1 30); do [[ "$(docker inspect --format '{{.State.Health.Status}}' wg-easy 2>/dev/null)" == "healthy" ]] && break; sleep 2; done
sleep 2

command -v sqlite3 >/dev/null 2>&1 || apt-get install -y sqlite3 >/dev/null 2>&1
DNAT_UP="iptables -t nat -A PREROUTING -d ${WG_GATEWAY_IP} -p udp --dport 53 -j DNAT --to-destination ${GW_HOST}:53; iptables -t nat -A PREROUTING -d ${WG_GATEWAY_IP} -p tcp --dport 53 -j DNAT --to-destination ${GW_HOST}:53; iptables -t nat -A PREROUTING -d ${WG_GATEWAY_IP} -p tcp --dport 80 -j DNAT --to-destination ${GW_HOST}:80; iptables -t nat -A PREROUTING -d ${WG_GATEWAY_IP} -p tcp --dport 443 -j DNAT --to-destination ${GW_HOST}:443;"
DNAT_DOWN="${DNAT_UP//-A PREROUTING/-D PREROUTING}"
CLAMP_UP="iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu;"
CLAMP_DOWN="${CLAMP_UP//-A FORWARD/-D FORWARD}"
if [[ -f "${DB}" ]]; then
  docker stop wg-easy >/dev/null 2>&1
  sqlite3 "${DB}" "UPDATE hooks_table SET post_up = post_up || ' ${DNAT_UP}' WHERE id='wg0' AND post_up NOT LIKE '%PREROUTING -d ${WG_GATEWAY_IP}%';"
  sqlite3 "${DB}" "UPDATE hooks_table SET post_down = post_down || ' ${DNAT_DOWN}' WHERE id='wg0' AND post_down NOT LIKE '%PREROUTING -d ${WG_GATEWAY_IP}%';"
  sqlite3 "${DB}" "UPDATE hooks_table SET post_up = post_up || ' ${CLAMP_UP}' WHERE id='wg0' AND post_up NOT LIKE '%clamp-mss-to-pmtu%';"
  sqlite3 "${DB}" "UPDATE hooks_table SET post_down = post_down || ' ${CLAMP_DOWN}' WHERE id='wg0' AND post_down NOT LIKE '%clamp-mss-to-pmtu%';"
  sqlite3 "${DB}" "UPDATE interfaces_table SET mtu=1280 WHERE mtu<>1280;"
  sqlite3 "${DB}" "UPDATE user_configs_table SET default_mtu=1280 WHERE default_mtu<>1280;"
  sqlite3 "${DB}" "UPDATE clients_table SET mtu=1280 WHERE mtu<>1280;"
  docker start wg-easy >/dev/null 2>&1
  for i in $(seq 1 30); do [[ "$(docker inspect --format '{{.State.Health.Status}}' wg-easy 2>/dev/null)" == "healthy" ]] && break; sleep 2; done
  sleep 2
fi
dnat_n=$(docker exec wg-easy iptables -t nat -S PREROUTING 2>/dev/null | grep -c "${WG_GATEWAY_IP}")
log "wg-easy healthy; peers=$(docker exec wg-easy sh -lc 'awg show wg0 peers 2>/dev/null | wc -l'); DNAT=${dnat_n}/4"

log "AdGuard: wiping query log + stats (config kept)..."
systemctl stop AdGuardHome
rm -f /opt/AdGuardHome/data/querylog*.json* /opt/AdGuardHome/data/stats.db
systemctl start AdGuardHome

log "logs: truncating + vacuuming journal..."
for f in /var/log/caddy/access.log /var/log/fail2ban.log /var/log/auth.log /var/log/syslog; do [[ -e "$f" ]] && : > "$f"; done
journalctl --rotate >/dev/null 2>&1
journalctl --vacuum-time=1s >/dev/null 2>&1

log "fail2ban: resetting ban history..."
systemctl stop fail2ban
rm -f /var/lib/fail2ban/fail2ban.sqlite3
systemctl start fail2ban

unbound-control reload >/dev/null 2>&1 && log "unbound: cache flushed"

log "removing leftovers..."
rm -f /etc/caddy/Caddyfile.bak.*

log "status dashboard: regenerating data.json..."
rm -f /var/www/status/data.json
systemctl restart obsidian-status
sleep 8

python3 - <<'PYV'
import json
try:
    d=json.load(open("/var/www/status/data.json"))
    x=d["security"]
    print("[reset-server] services: "+", ".join("%s=%s"%(c["name"],c["state"]) for c in d["services"]))
    print("[reset-server] bans current=%s total=%s | allOk=%s"%(x["currentBans"],x["totalBans"],d["allOk"]))
except Exception as e:
    print("[reset-server] data.json not ready yet:",e)
PYV
echo "[reset-server] Done - gateway reset to a freshly-deployed state. Log in to wg-easy + AdGuard to create configs."
RESET_EOF
chmod 0755 /usr/local/bin/reset-server

rm -rf /tmp/amneziawg-build /tmp/unbound-build /tmp/AdGuardHome_*.tar.gz
apt-get clean

echo ""
echo "done."
echo "vpn panel : https://${PUBLIC_IP}  (wg-easy login: ${DASHBOARD_USERNAME})"
echo "vpn admin : ${DASHBOARD_USERNAME}  (wg-easy)"
echo "adguard   : ${ADGUARD_USERNAME}  (${ADGUARD_HOST}, over vpn)"
echo "health    : http(s)://status.${DOMAIN}  (vpn-only, no login)"
echo "uninstall : sudo uninstall-server"
echo "reset     : sudo reset-server   (wipe device configs + logs -> fresh, keeps logins)"
