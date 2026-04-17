#!/bin/bash
# break_storage.sh — Storage 장애 주입 (dm-delay + I/O 워크로드)
# 실행: sudo bash break_storage.sh

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
echo " Storage 장애 주입"
echo "========================================="
echo ""

# ── 사전 조건 ──
if command -v apt-get &>/dev/null; then
  apt-get install -y -qq sysstat iotop > /dev/null 2>&1 || true
elif command -v dnf &>/dev/null; then
  dnf install -y -q sysstat iotop > /dev/null 2>&1 || true
fi

modprobe dm_delay

# ── dm-delay 볼륨 생성 ──
mkdir -p /opt/eda/{scratch,scripts}
dd if=/dev/zero of=/opt/eda/scratch-data.img bs=1M count=2048 status=none
LOOP=$(losetup --show -f /opt/eda/scratch-data.img)
SECTORS=$(blockdev --getsz "$LOOP")

echo "0 $SECTORS delay $LOOP 0 100 $LOOP 0 100" | dmsetup create slow-data
mkfs.ext4 -q /dev/mapper/slow-data
mount /dev/mapper/slow-data /opt/eda/scratch

# ── I/O 워크로드 스크립트 ──
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

# ── systemd 서비스 (I/O 제어 의도적 미설정) ──
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

systemctl daemon-reload
for i in 1 2 3 4; do
  systemctl enable --now compute-worker@$i 2>/dev/null
done

echo "  - dm-delay 디바이스: /dev/mapper/slow-data (100ms 지연)"
echo "  - 워크로드: compute-worker@{1..4}.service"

# ── 검증 (30초 대기 후) ──
echo ""
echo -e "${YELLOW}[검증] 30초 대기 중 (워크로드 누적)...${NC}"
sleep 30

echo ""
echo "--- iostat (dm-3 또는 slow-data %util 확인) ---"
iostat -x 1 3 | grep -E "(Device|dm-|sd)" | head -20

echo ""
echo "--- D state 프로세스 ---"
D_COUNT=$(ps aux | awk '$8 ~ /^D/' | wc -l)
echo "D state 프로세스: ${D_COUNT}개"
ps aux | awk '$8 ~ /^D/' | head -10

echo ""
echo "--- dd 응답 시간 (정상 노드: 1초 이내) ---"
time dd if=/dev/zero of=/opt/eda/scratch/test bs=4k count=100 oflag=direct 2>&1
rm -f /opt/eda/scratch/test

echo ""
if [[ "$D_COUNT" -gt 0 ]]; then
  echo -e "${GREEN}[OK]${NC} Storage 장애 주입 완료 — D state 프로세스 ${D_COUNT}개 확인"
else
  echo -e "${YELLOW}[WARN]${NC} D state 프로세스 아직 없음 — 잠시 후 재확인"
fi
echo ""
echo "1~2분 대기 후 피면접자 접속을 허용하세요."
