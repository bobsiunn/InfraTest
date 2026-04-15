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

# 사전 조건
apt-get install -y -qq sysstat iotop > /dev/null 2>&1 || true

# dm-delay 모듈 로드
modprobe dm_delay

# 고지연 데이터 볼륨 생성
mkdir -p /opt/compute/{data,scripts}
dd if=/dev/zero of=/opt/slow-data.img bs=1M count=2048 status=none
LOOP=$(losetup --show -f /opt/slow-data.img)
SECTORS=$(blockdev --getsz "$LOOP")

# 읽기/쓰기 100ms 지연 (느린 NAS/SAN 모사)
echo "0 $SECTORS delay $LOOP 0 100 $LOOP 0 100" | dmsetup create slow-data
mkfs.ext4 -q /dev/mapper/slow-data
mount /dev/mapper/slow-data /opt/compute/data

# I/O 워크로드 스크립트
cat > /opt/compute/scripts/io_workload.sh << 'SCRIPT'
#!/bin/bash
while true; do
  for i in $(seq 1 20); do
    dd if=/dev/urandom of=/opt/compute/data/job_$$_${i} \
       bs=4k count=50 oflag=direct 2>/dev/null &
  done
  wait
  rm -f /opt/compute/data/job_$$_*
done
SCRIPT
chmod +x /opt/compute/scripts/io_workload.sh

# systemd 템플릿 서비스 (I/O 제어 의도적 미설정)
cat > /etc/systemd/system/compute-worker@.service << 'UNIT'
[Unit]
Description=Compute Worker %i

[Service]
Type=simple
ExecStart=/opt/compute/scripts/io_workload.sh
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
# 시나리오 2: Network — DNS 타임아웃
# ─────────────────────────────────────
echo -e "${GREEN}[2/2]${NC} Network 장애 주입: DNS primary를 죽은 서버로 설정"

# 사전 조건
apt-get install -y -qq dnsutils > /dev/null 2>&1 || true

# 현재 DNS 백업
CONN=$(nmcli -t -f NAME connection show --active | head -1)
CURRENT_DNS=$(grep nameserver /etc/resolv.conf | head -1 | awk '{print $2}')

if [[ -z "$CONN" ]]; then
  echo -e "${RED}[ERROR]${NC} NetworkManager 활성 연결 없음"
  exit 1
fi

# 죽은 DNS(10.0.0.53)를 primary로, 기존 DNS를 secondary로
nmcli connection modify "$CONN" ipv4.dns "10.0.0.53 $CURRENT_DNS"
nmcli connection modify "$CONN" ipv4.ignore-auto-dns yes
nmcli connection up "$CONN" 2>/dev/null

echo "  - Primary DNS: 10.0.0.53 (응답 없음 → 5초 타임아웃)"
echo "  - Secondary DNS: $CURRENT_DNS (폴백)"
echo "  - 원래 DNS 백업: $CURRENT_DNS"

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
