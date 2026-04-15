# IDC 인프라 엔지니어 면접 — 트러블슈팅 과제

## 설계 철학

EC2 싱글 노드에서 **실제 현장에서 빈번하게 발생하는 장애 2개**를 재현한다.
각 장애는 잘못된 설계에서 비롯되며, 증상만 수정(프로세스 kill, 파일 편집)하면 반드시 재발한다.

---

## 장애 목록

| # | 영역 | 장애 | 핵심 |
|---|------|------|------|
| 1 | Storage | I/O 지연으로 D state 프로세스 누적 | load는 높은데 CPU는 놀고 있다 → iowait |
| 2 | Network | DNS 타임아웃으로 전역 지연 | 모든 게 느리지만 되긴 된다 → 5초 폴백 |

---

## 시나리오 1: Storage — I/O 지연 / D state 누적

### 배경

컴퓨트 노드의 데이터 볼륨이 워크로드의 IOPS를 감당하지 못한다.
볼륨 설계 시 용량(GB)만 고려하고 IOPS를 고려하지 않았다.
워크로드가 작은 파일을 대량으로 random write하면서
I/O 대기가 쌓이고, 프로세스들이 D state(uninterruptible sleep)로 적체된다.

### 구현

- `dm-delay`로 100ms 지연 데이터 볼륨 생성 (느린 NAS/SAN 모사)
- `compute-worker@{1..4}.service`가 해당 볼륨에 direct I/O 워크로드 실행
- `Restart=always` + `enabled` → kill/stop/reboot로 멈추지 않음
- `ionice`, `IOWeight` 등 I/O 제어 미설정 (설계 결함)

### 증상

```
$ top
load average: 12.3, 10.1, 8.7
%Cpu(s):  2.1 us,  3.4 sy,  0.0 ni,  5.2 id, 89.1 wa, ...

$ ps aux | awk '$8 ~ /D/'
(D state 프로세스 다수)

$ iostat -x 1
Device      %util   await
dm-0        100.00  450.32
```

### 기대하는 진단 순서

1. `top` → load high, CPU idle, **iowait 높음** → "I/O 문제"
2. `iostat -x 1` → 어떤 디바이스가 병목인지 식별
3. `iotop` → 어떤 프로세스가 I/O를 소비하는지
4. `lsblk` / `dmsetup ls` → dm-delay 디바이스 발견
5. `dmsetup table slow-data` → 100ms 지연 확인 → 원인: **스토리지 성능 부족**

### 잘못된 수정 (재발)

| 시도 | 결과 |
|------|------|
| `kill` / `systemctl stop` | `Restart=always`로 즉시 재시작 |
| `reboot` | 서비스 enabled → 재부팅 후 재발 |

### 올바른 수정

**즉각:** dm-delay 제거 후 정상 마운트
```bash
systemctl stop compute-worker@{1,2,3,4}
umount /opt/compute/data
dmsetup remove slow-data
mount -o loop /opt/slow-data.img /opt/compute/data
systemctl start compute-worker@{1,2,3,4}
```
(실무에서는 볼륨 타입 업그레이드: gp2 → gp3/io2, provisioned IOPS)

**재발 방지:** systemd unit에 I/O 제어 추가
```ini
IOWeight=50
# 또는 ExecStart=ionice -c2 -n7 /opt/compute/scripts/io_workload.sh
```

---

## 시나리오 2: Network — DNS 타임아웃

### 배경

내부 DNS 서버(10.0.0.53)가 폐기되었으나 컴퓨트 노드의 DNS 설정이 갱신되지 않았다.
모든 DNS 쿼리가 죽은 primary에서 5초 타임아웃 후 secondary로 폴백.
NetworkManager가 DNS를 관리하므로 `/etc/resolv.conf` 직접 수정은 덮어씌워짐.

### 증상

```
$ time curl -s http://example.com > /dev/null
real    0m5.3s       # 5초 지연!

$ ping 8.8.8.8
64 bytes from 8.8.8.8: time=1.2ms   # IP 직접은 빠름

$ cat /etc/resolv.conf
nameserver 10.0.0.53     # ← 죽은 서버
nameserver 169.254.169.253
```

### 기대하는 진단 순서

1. "네트워크는 되는데 느리다" → IP vs 도메인 비교 → **DNS 문제**
2. `time dig google.com` → 5초+ 소요
3. `dig @10.0.0.53 google.com` → timeout 확인
4. `/etc/resolv.conf` 확인 → 죽은 primary 발견
5. `nmcli connection show` → NetworkManager 관리 확인

### 잘못된 수정 (재발)

| 시도 | 결과 |
|------|------|
| `echo "nameserver 169.254.169.253" > /etc/resolv.conf` | NetworkManager 재시작 시 덮어씌워짐 |

### 올바른 수정

```bash
CONN=$(nmcli -t -f NAME connection show --active | head -1)
nmcli connection modify "$CONN" ipv4.dns "169.254.169.253"
nmcli connection modify "$CONN" ipv4.ignore-auto-dns no
nmcli connection up "$CONN"
```

---

## 면접 진행

### 사전 준비

```bash
# EC2에 파일 복사
scp -r InfraTest/ ubuntu@<IP>:~/

# 장애 주입 (피면접자 접속 2분 전)
sudo bash ~/InfraTest/break_node.sh

# 확인
iostat -x 1 3          # %util 100%, await 수백ms
time dig google.com    # 5초+
```

### 피면접자 안내

`candidate_brief.md` 제공. 원인 개수/종류는 알려주지 않음.

### 채점

```bash
sudo bash ~/InfraTest/verify_node.sh
```

---

## 평가

### 정량 (verify_node.sh)

| 등급 | 점수 |
|------|------|
| S | 6/6 |
| A | 5/6 |
| B | 3~4/6 |
| C | 2 이하 |

### 정성 (화면 관찰)

| 포인트 | 기대 |
|--------|------|
| iowait 인지 | load high + CPU idle → "I/O 문제"로 전환하는 순간 |
| 도구 선택 | `iostat`, `iotop`, `dmsetup`, `dig` 등 적절한 진단 도구 |
| 재발 방지 | 증상만 고치지 않고 설계 결함까지 수정 |
| AI 활용 | 명령어 복붙 vs 출력을 읽고 판단 |

### 구두 회고 (10분)

> "실무에서 이 상황이면 인프라를 어떻게 재설계하겠는가?"

---

## EC2 스펙

| 항목 | 권장값 |
|------|--------|
| AMI | Ubuntu 22.04 LTS |
| Type | t3.medium (2 vCPU, 4GB) |
| Volume | 20GB gp3 |
| 설치 | python3, NetworkManager, dnsutils, sysstat, iotop |
