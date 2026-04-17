#!/bin/bash
# break_node.sh — 면접용 장애 주입 (전체)
# 실행: sudo bash break_node.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] root 권한 필요: sudo bash $0"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "========================================="
echo " 면접 장애 주입 시작 (Storage + Network)"
echo "========================================="

bash "$SCRIPT_DIR/break_storage.sh"
bash "$SCRIPT_DIR/break_network.sh"

echo ""
echo "========================================="
echo " 장애 주입 완료"
echo "========================================="
