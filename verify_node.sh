#!/bin/bash
# verify_node.sh — 면접 채점
# 실행: sudo bash verify_node.sh

set -uo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "  ${GREEN}[PASS]${NC} $*"; ((PASS++)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; ((FAIL++)); }

if [[ $EUID -ne 0 ]]; then
  echo "root 권한 필요: sudo bash $0"
  exit 1
fi

echo ""
echo -e "${BOLD}═══════════════════════════════════════${NC}"
echo -e "${BOLD}  면접 채점 결과${NC}"
echo -e "${BOLD}═══════════════════════════════════════${NC}"

# ── Storage ──
echo ""
echo -e "${BOLD}[Storage] I/O 지연 / D state${NC}"

# 1. dm-delay 제거됨
if dmsetup ls 2>/dev/null | grep -q "slow-data"; then
  fail "dm-delay 디바이스(slow-data) 아직 존재"
else
  pass "dm-delay 디바이스 제거됨"
fi

# 2. D state 프로세스 없음
D_COUNT=$(ps aux 2>/dev/null | awk '$8 ~ /^D/' | wc -l)
if [[ "$D_COUNT" -eq 0 ]]; then
  pass "D state 프로세스 없음"
else
  fail "D state 프로세스 ${D_COUNT}개 잔존"
fi

# 3. 워크로드 서비스에 I/O 제어 설정
SERVICE_FILE=/etc/systemd/system/compute-worker@.service
if [[ -f "$SERVICE_FILE" ]]; then
  if grep -qiE '(IOWeight|IODeviceWeight|ionice|IOReadBandwidthMax|IOWriteBandwidthMax)' "$SERVICE_FILE" 2>/dev/null; then
    pass "워크로드 서비스에 I/O 제어 설정 존재"
  else
    fail "워크로드 서비스에 I/O 제어 미설정 (IOWeight, ionice 등 없음)"
  fi
else
  fail "워크로드 서비스 파일 없음"
fi

# ── Network ──
echo ""
echo -e "${BOLD}[Network] 잘못 설정된 DNS 포워더${NC}"

# 4. DNS 응답 속도 (캐시 우회를 위해 처음 보는 도메인 사용)
RANDOM_LABEL="test-$(date +%s%N | md5sum | head -c8)"
DNS_START=$(date +%s%3N)
dig +short +timeout=10 "${RANDOM_LABEL}.pypi.org" > /dev/null 2>&1 || true
DNS_END=$(date +%s%3N)
DNS_MS=$(( DNS_END - DNS_START ))

if [[ "$DNS_MS" -lt 2000 ]]; then
  pass "DNS 응답 ${DNS_MS}ms (2초 이내)"
else
  fail "DNS 응답 ${DNS_MS}ms (2초 초과 — 지연 잔존)"
fi

# 5. eda-dns.service 비활성화됨
if systemctl is-active eda-dns.service &>/dev/null; then
  fail "eda-dns.service 아직 실행 중 (5초 지연 포워더 잔존)"
elif systemctl is-enabled eda-dns.service &>/dev/null; then
  fail "eda-dns.service disabled되지 않음 (재부팅 시 재발)"
else
  pass "eda-dns.service 중단 및 disabled 확인"
fi

# 6. resolv.conf immutable 해제 + 정상 DNS 설정
if lsattr /etc/resolv.conf 2>/dev/null | grep -q '\-i-'; then
  fail "resolv.conf 아직 immutable (chattr +i 미해제)"
else
  PRIMARY_DNS=$(grep nameserver /etc/resolv.conf | head -1 | awk '{print $2}')
  if dig +short +timeout=2 google.com "@${PRIMARY_DNS}" > /dev/null 2>&1; then
    pass "resolv.conf 정상 DNS(${PRIMARY_DNS})로 복원됨"
  else
    fail "resolv.conf의 DNS(${PRIMARY_DNS}) 응답 없음"
  fi
fi

# ── 결과 ──
TOTAL=$((PASS + FAIL))
echo ""
echo -e "${BOLD}═══════════════════════════════════════${NC}"
echo -e "${BOLD}  결과: ${PASS} / ${TOTAL}${NC}"
echo -e "${BOLD}═══════════════════════════════════════${NC}"
echo ""

if   [[ "$PASS" -ge 6 ]]; then echo -e "  등급: ${BOLD}S${NC} — 두 장애 모두 근본 수정 + 재발 방지"
elif [[ "$PASS" -ge 5 ]]; then echo -e "  등급: ${BOLD}A${NC} — 대부분 수정, 일부 미흡"
elif [[ "$PASS" -ge 3 ]]; then echo -e "  등급: ${BOLD}B${NC} — 일부 증상 수정 혼재"
else                            echo -e "  등급: ${BOLD}C${NC} — 근본 원인 파악 미흡"
fi

echo ""
echo "  ※ 정성 평가(진단 방법론, AI 활용, 커뮤니케이션)는 화면 공유 녹화 기반 별도 평가"
