#!/bin/bash
# Update incremental untuk xyzstore/v7old
# Apply: kernel tuning + harden limit/udp-mini/kyt service + slow polling loop
# Tidak menyentuh user/config xray/dropbear yang sudah ada.

set -e

REPO="https://raw.githubusercontent.com/xyzstore/v7old/main/"

GREEN='\e[32m'; YELLOW='\e[33m'; RED='\e[31m'; NC='\e[0m'
ok()   { echo -e " ${GREEN}[OK]${NC}  $1"; }
info() { echo -e " ${YELLOW}[..]${NC}  $1"; }
err()  { echo -e " ${RED}[ERR]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
  err "Harus dijalankan sebagai root."
  exit 1
fi

echo "========================================"
echo "   xyzstore/v7old - Update Optimasi"
echo "========================================"

# -------- 1. Sysctl tuning --------
info "Menulis /etc/sysctl.d/99-vpn-tuning.conf"
cat >/etc/sysctl.d/99-vpn-tuning.conf <<EOSYS
# memori
vm.swappiness=10
vm.vfs_cache_pressure=50
# tcp
net.core.somaxconn=4096
net.core.netdev_max_backlog=5000
net.ipv4.tcp_max_syn_backlog=4096
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
# file descriptors
fs.file-max=1000000
EOSYS
sysctl --system >/dev/null 2>&1 || true
ok "Sysctl tuning aktif (BBR, swappiness=10, file-max=1M)"

# -------- 2. ulimit --------
info "Menulis /etc/security/limits.d/99-vpn.conf"
cat >/etc/security/limits.d/99-vpn.conf <<EOLIM
* soft nofile 1000000
* hard nofile 1000000
* soft nproc 65535
* hard nproc 65535
root soft nofile 1000000
root hard nofile 1000000
EOLIM
ok "Limits naik ke 1M nofile / 65k nproc"

# -------- 3. Tarik ulang script limit (loop sleep 30) --------
info "Update script limit polling (vmess & vless)"
wget -q -O /etc/xray/limit.vmess "${REPO}limit/vmess" && chmod +x /etc/xray/limit.vmess
wget -q -O /etc/xray/limit.vless "${REPO}limit/vless" && chmod +x /etc/xray/limit.vless
wget -q -O /etc/xray/limit.trojan "${REPO}limit/trojan" && chmod +x /etc/xray/limit.trojan
wget -q -O /etc/xray/limit.shadowsocks "${REPO}limit/shadowsocks" && chmod +x /etc/xray/limit.shadowsocks
ok "Script limit polling diperbarui"

# -------- 4. Tarik ulang systemd service --------
info "Update systemd service (limit*, udp-mini*)"
for svc in limitvmess limitvless limittrojan limitshadowsocks; do
  wget -q -O /etc/systemd/system/${svc}.service "${REPO}limit/${svc}.service"
done
for svc in udp-mini-1 udp-mini-2 udp-mini-3; do
  wget -q -O /etc/systemd/system/${svc}.service "${REPO}limit/${svc}.service"
done
ok "Service definition limit & udp-mini diperbarui"

# -------- 5. kyt.service hardening (kalau service kyt ada) --------
if systemctl list-unit-files 2>/dev/null | grep -q '^kyt\.service'; then
  info "Hardening kyt.service"
  cat > /etc/systemd/system/kyt.service <<'EOK'
[Unit]
Description=Simple kyt - @kyt
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
WorkingDirectory=/usr/bin
ExecStart=/usr/bin/kyt/venv/bin/python3 -m kyt
Restart=on-failure
RestartSec=20
Nice=10

[Install]
WantedBy=multi-user.target
EOK
  ok "kyt.service di-harden"
fi

# -------- 6. Reload systemd & restart service --------
info "Reload systemd & restart service"
systemctl daemon-reload

for svc in limitvmess limitvless limittrojan limitshadowsocks; do
  systemctl restart ${svc} 2>/dev/null && ok "restart ${svc}" || err "gagal restart ${svc}"
done

for svc in udp-mini-1 udp-mini-2 udp-mini-3; do
  systemctl restart ${svc} 2>/dev/null && ok "restart ${svc}" || err "gagal restart ${svc}"
done

if systemctl list-unit-files 2>/dev/null | grep -q '^kyt\.service'; then
  systemctl restart kyt 2>/dev/null && ok "restart kyt" || err "gagal restart kyt"
fi

# -------- 7. Verifikasi BBR aktif --------
CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
if [[ "$CC" == "bbr" ]]; then
  ok "TCP congestion control: bbr aktif"
else
  err "TCP congestion control: $CC (BBR mungkin belum tersedia di kernel)"
fi

echo ""
echo "========================================"
echo -e " ${GREEN}Update selesai.${NC}"
echo " Cek beban: ${YELLOW}htop${NC}  |  Service: ${YELLOW}systemctl --failed${NC}"
echo "========================================"
