#!/bin/bash
# break_node.sh — 면접용 장애 주입
# 실행: sudo bash break_node.sh

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}[ERROR]${NC} root 권한 필요: sudo bash $0"
  exit 1
fi

echo ""
echo "========================================="
echo " 면접 장애 주입 시작"
echo "========================================="
echo ""

# ─────────────────────────────────────
# 시나리오 1: Storage — I/O 지연 / D state
# ─────────────────────────────────────
echo -e "${GREEN}[1/2]${NC} Storage 장애 주입: dm-delay + I/O 워크로드"

# 사전 조건 (OS 감지)
if command -v apt-get &>/dev/null; then
  apt-get install -y -qq sysstat iotop > /dev/null 2>&1 || true
elif command -v dnf &>/dev/null; then
  dnf install -y -q sysstat iotop > /dev/null 2>&1 || true
fi

# dm-delay 모듈 로드
modprobe dm_delay

# 고지연 데이터 볼륨 생성
mkdir -p /opt/eda/{scratch,scripts}
dd if=/dev/zero of=/opt/eda/scratch-data.img bs=1M count=2048 status=none
LOOP=$(losetup --show -f /opt/eda/scratch-data.img)
SECTORS=$(blockdev --getsz "$LOOP")

# 읽기/쓰기 100ms 지연 (느린 NAS/SAN 모사)
echo "0 $SECTORS delay $LOOP 0 100 $LOOP 0 100" | dmsetup create slow-data
mkfs.ext4 -q /dev/mapper/slow-data
mount /dev/mapper/slow-data /opt/eda/scratch

# I/O 워크로드 스크립트
cat > /opt/eda/scripts/io_workload.sh << 'SCRIPT'
#!/bin/bash
while true; do
  for i in $(seq 1 20); do
    dd if=/dev/urandom of=/opt/eda/scratch/job_$$_${i} \
       bs=4k count=50 oflag=direct 2>/dev/null &
  done
  wait
  rm -f /opt/eda/scratch/job_$$_*
done
SCRIPT
chmod +x /opt/eda/scripts/io_workload.sh

# systemd 템플릿 서비스 (I/O 제어 의도적 미설정)
cat > /etc/systemd/system/compute-worker@.service << 'UNIT'
[Unit]
Description=Compute Worker %i

[Service]
Type=simple
ExecStart=/opt/eda/scripts/io_workload.sh
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
UNIT

# 워크로드 4개 인스턴스 시작
systemctl daemon-reload
for i in 1 2 3 4; do
  systemctl enable --now compute-worker@$i 2>/dev/null
done

echo "  - dm-delay 디바이스: /dev/mapper/slow-data (100ms 지연)"
echo "  - 워크로드: compute-worker@{1..4}.service"

# ─────────────────────────────────────
# 시나리오 2: Network — 잘못 설정된 내부 DNS 포워더
# ─────────────────────────────────────
echo -e "${GREEN}[2/2]${NC} Network 장애 주입: 5초 지연 DNS 포워더 서비스 등록"

# 사전 조건 (OS 감지)
if command -v apt-get &>/dev/null; then
  apt-get install -y -qq dnsutils > /dev/null 2>&1 || true
elif command -v dnf &>/dev/null; then
  dnf install -y -q bind-utils > /dev/null 2>&1 || true
fi

# slow DNS 포워더 스크립트 생성
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

# systemd 서비스로 등록 (enabled → 재부팅 후에도 유지)
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

# resolv.conf를 로컬 포워더로 고정
# NetworkManager가 덮어쓰지 못하도록 immutable 설정
CONN=$(nmcli -t -f NAME connection show --active | head -1)
nmcli connection modify "$CONN" ipv4.ignore-auto-dns yes 2>/dev/null || true
echo "nameserver 127.0.0.1" > /etc/resolv.conf
chattr +i /etc/resolv.conf

echo "  - eda-dns.service: 5초 지연 DNS 포워더 (enabled)"
echo "  - resolv.conf: 127.0.0.1 고정 (immutable)"

# ─────────────────────────────────────
# 완료
# ─────────────────────────────────────
echo ""
echo "========================================="
echo " 장애 주입 완료"
echo "========================================="
echo ""
echo "확인 방법:"
echo "  iostat -x 1 3         # %util 100%, await 수백ms"
echo "  ps aux | awk '\$8~/D/' # D state 프로세스 확인"
echo "  time dig google.com   # 5초+ 소요"
echo ""
echo "1~2분 대기 후 피면접자 접속을 허용하세요."
