#!/bin/bash
# break_network.sh — Network 장애 주입 (5초 지연 DNS 포워더)
# 실행: sudo bash break_network.sh

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}[ERROR]${NC} root 권한 필요: sudo bash $0"
  exit 1
fi

echo ""
echo "========================================="
echo " Network 장애 주입"
echo "========================================="
echo ""

# ── 사전 조건 ──
if command -v apt-get &>/dev/null; then
  apt-get install -y -qq dnsutils > /dev/null 2>&1 || true
elif command -v dnf &>/dev/null; then
  dnf install -y -q bind-utils > /dev/null 2>&1 || true
fi

mkdir -p /opt/eda/scripts

# ── slow DNS 포워더 스크립트 ──
cat > /opt/eda/scripts/slow_dns.py << 'EOF'
#!/usr/bin/env python3
"""
내부 DNS 캐싱 포워더 (설정 오류로 인해 5초 지연 발생)
"""
import socket, time, threading

DELAY = 5        # 잘못된 설정값 (의도적 장애)
UPSTREAM = '8.8.8.8'

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(('127.0.0.1', 53))

def handle(data, addr):
    time.sleep(DELAY)
    up = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    up.settimeout(10)
    try:
        up.sendto(data, (UPSTREAM, 53))
        resp, _ = up.recvfrom(4096)
        sock.sendto(resp, addr)
    except Exception:
        pass
    finally:
        up.close()

while True:
    data, addr = sock.recvfrom(4096)
    threading.Thread(target=handle, args=(data, addr), daemon=True).start()
EOF

# ── systemd 서비스 등록 ──
cat > /etc/systemd/system/eda-dns.service << 'UNIT'
[Unit]
Description=EDA Internal DNS Forwarder
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/eda/scripts/slow_dns.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now eda-dns.service

# ── resolv.conf 고정 (immutable) ──
CONN=$(nmcli -t -f NAME connection show --active | head -1)
nmcli connection modify "$CONN" ipv4.ignore-auto-dns yes 2>/dev/null || true
echo "nameserver 127.0.0.1" > /etc/resolv.conf
chattr +i /etc/resolv.conf

echo "  - eda-dns.service: 5초 지연 DNS 포워더 (enabled)"
echo "  - resolv.conf: 127.0.0.1 고정 (immutable)"

# ── 검증 ──
echo ""
echo -e "${YELLOW}[검증] DNS 지연 확인 중...${NC}"
sleep 2

echo ""
echo "--- ping 8.8.8.8 (IP 직접 — 정상이어야 함) ---"
ping -c 2 8.8.8.8 | grep -E "(time=|packet loss)"

echo ""
echo "--- time dig google.com (5초+ 소요되어야 함) ---"
time dig +short google.com > /dev/null

echo ""
echo "--- lsattr /etc/resolv.conf (----i----- 이어야 함) ---"
lsattr /etc/resolv.conf

echo ""
DNS_MS=$( { time dig +short +timeout=10 google.com > /dev/null; } 2>&1 | grep real | awk '{print $2}')
echo -e "${GREEN}[OK]${NC} Network 장애 주입 완료 — DNS 응답 시간: ${DNS_MS}"
