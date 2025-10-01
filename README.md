# Blue-Green Deployment Study

Docker 컨테이너 기반 블루-그린 배포 전략 실습 프로젝트

## 📚 목차

- [블루-그린 배포란?](#-블루-그린-배포란)
- [아키텍처](#️-아키텍처)
- [빠른 시작](#-빠른-시작)
- [배포 흐름](#-배포-흐름)
- [롤백 흐름](#-롤백-흐름)
- [주요 기능](#️-주요-기능)
- [스키마 마이그레이션](#️-스키마-마이그레이션-전략)
- [트러블슈팅](#-트러블슈팅)

---

## 📖 블루-그린 배포란?

### 개념

블루-그린 배포(Blue-Green Deployment)는 **두 개의 동일한 운영 환경**을 유지하면서 무중단 배포를 실현하는 배포 전략입니다.

- **Blue 환경**: 현재 운영 중인 안정적인 버전
- **Green 환경**: 새로운 버전을 배포할 대기 환경

### 핵심 원리

```
1. Blue 환경에서 서비스 운영 중
2. Green 환경에 새 버전 배포 및 테스트
3. 검증 완료 후 트래픽을 Green으로 전환
4. 문제 발생 시 즉시 Blue로 롤백
```

### 장점과 단점

| 장점 | 단점 |
|------|------|
| ✅ **무중단 배포** - 사용자 경험 손실 없음 | ⚠️ **리소스 2배** - 동시에 두 환경 유지 |
| ✅ **즉시 롤백** - 문제 발생 시 빠른 복구 (초 단위) | ⚠️ **데이터베이스 복잡성** - 스키마 변경 시 주의 필요 |
| ✅ **리스크 최소화** - 프로덕션과 동일한 환경에서 사전 테스트 | ⚠️ **세션/상태 관리** - Stateful 앱 전환 시 고려 필요 |
| ✅ **배포 검증** - 실제 트래픽 전환 전 충분한 검증 가능 | |

### 적용 시나리오

**✅ 권장하는 경우**
- 프로덕션 환경 배포
- 중요한 기능 업데이트
- 데이터베이스 마이그레이션이 포함된 배포
- 높은 가용성이 요구되는 서비스

**⚠️ 고려가 필요한 경우**
- 개발/스테이징 환경 (리소스 비용 대비 효과)
- 매우 작은 패치 (간단한 핫픽스)
- 제한된 인프라 리소스

---

## 🏗️ 아키텍처

### 시스템 구성도

```
                    ┌────────────────────┐
                    │    사용자 트래픽    │
                    └──────────┬─────────┘
                               │
                               ▼
                    ┌──────────────────────┐
                    │  Nginx Load Balancer │
                    │    (Port 3030)       │
                    └──────────┬───────────┘
                               │
              ┌────────────────┴────────────────┐
              ▼                                 ▼
    ┌──────────────────┐              ┌──────────────────┐
    │ Blue Environment │              │ Green Environment│
    │                  │              │                  │
    │ Spring Boot App  │◄────────────►│ Spring Boot App  │
    │   (Port 8080)    │ Replication  │   (Port 8080)    │
    └────────┬─────────┘              └────────┬─────────┘
             │                                 │
             ▼                                 ▼
    ┌──────────────────┐               ┌──────────────────┐
    │  MySQL Master    │◄─────────────►│  MySQL Master    │
    │   (Port 3306)    │ Bi-directional│   (Port 3306)    │
    └──────────────────┘  Replication  └──────────────────┘
```

### 구성 요소

| 컴포넌트 | 역할 | 기술 스택 |
|---------|------|----------|
| **Nginx** | 로드밸런서 및 트래픽 라우팅 | Nginx Alpine |
| **Spring Boot App** | 비즈니스 로직 처리 | Java 21 + Spring Boot 3.x |
| **MySQL** | 데이터 저장 및 복제 | MySQL 8.0 (Master-Master) |
| **Docker Compose** | 컨테이너 오케스트레이션 | Docker Compose |
| **GitHub Actions** | CI/CD 자동화 | GitHub Workflows |

---

## 🚀 빠른 시작

### 사전 요구사항

- Docker 20.10+
- Docker Compose 2.0+
- Java 21 (로컬 빌드 시)
- Gradle 8.x (로컬 빌드 시)

### 1단계: 저장소 클론 및 빌드

```bash
# 저장소 클론
git clone <repository-url>
cd blue-green-study

# 애플리케이션 빌드
./gradlew build
cd ..
```

### 2단계: Blue 환경 시작 (초기 배포)

```bash
# Blue 환경 컨테이너 시작
docker-compose up -d app_blue mysql_blue nginx

# 컨테이너 상태 확인 (healthy 될 때까지 대기)
docker-compose ps

# 헬스체크 확인
curl http://localhost:3030/health
# 예상 출력: OK - blue

curl http://localhost:3030/version
# 예상 출력: Version: 1 - Env: blue
```

### 3단계: Green 환경 배포

```bash
# Green 환경 시작
docker-compose --profile green up -d

# Master-Master 복제 설정
./scripts/setup_replication.sh

# 복제 상태 확인
docker exec mysql_green mysql -u root -prootpass -e "SHOW SLAVE STATUS\G" | grep "Seconds_Behind_Master"
# 예상 출력: Seconds_Behind_Master: 0
```

### 4단계: 트래픽 전환 (Blue → Green)

```bash
# Green으로 트래픽 전환
./scripts/switch_to_green.sh

# 전환 확인
curl http://localhost:3030/health
# 예상 출력: OK - green
```

### 5단계: 롤백 테스트 (Green → Blue)

```bash
# Blue로 즉시 롤백
./scripts/switch_to_blue.sh

# 롤백 확인
curl http://localhost:3030/health
# 예상 출력: OK - blue
```

### 전체 데모 실행

대화형 데모를 통해 전체 프로세스를 체험할 수 있습니다:

```bash
./scripts/demo.sh
```

---

## 🔄 배포 흐름

### Blue → Green 무중단 배포

#### 전체 프로세스

```
[1. 현재 상태 확인]
         ↓
[2. Green 환경 준비]
         ↓
[3. 데이터베이스 복제 설정]
         ↓
[4. Green 애플리케이션 배포]
         ↓
[5. 헬스체크 및 검증]
         ↓
[6. 트래픽 전환]
         ↓
[7. 모니터링 및 검증]
         ↓
[8. Blue 환경 정리 (선택)]
```

#### 단계별 상세 가이드

##### 1단계: 현재 상태 확인

```bash
# 현재 활성 환경 확인
curl http://localhost:3030/health
# 출력: OK - blue

# 컨테이너 상태 확인
docker-compose ps
```

**확인 사항:**
- ✓ Blue 환경이 정상 작동 중
- ✓ 모든 컨테이너가 healthy 상태
- ✓ 데이터베이스 연결 정상

---

##### 2단계: Green 환경 준비

```bash
# Green MySQL 시작
docker-compose --profile green up -d mysql_green

# MySQL 준비 대기 (약 10초)
sleep 10

# MySQL 상태 확인
docker exec mysql_green mysqladmin ping -h localhost -u root -prootpass
```

**중요 포인트:**
- ⚠️ Blue 환경은 계속 트래픽 처리 (다운타임 0초)
- Green MySQL이 완전히 시작될 때까지 대기

---

##### 3단계: 데이터베이스 복제 설정

```bash
# Master-Master 복제 설정
./scripts/setup_replication.sh
```

**복제 설정 내부 동작:**

```sql
-- Blue MySQL (현재 Master)
CREATE USER 'repl'@'%' IDENTIFIED BY 'repl_password';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
FLUSH PRIVILEGES;
SHOW MASTER STATUS; -- Position 기록

-- Green MySQL (복제 시작)
CHANGE MASTER TO
  MASTER_HOST='mysql_blue',
  MASTER_USER='repl',
  MASTER_PASSWORD='repl_password',
  MASTER_LOG_FILE='<binary_log_file>',
  MASTER_LOG_POS=<position>;
START SLAVE;

-- 복제 상태 확인
SHOW SLAVE STATUS\G
-- Slave_IO_Running: Yes
-- Slave_SQL_Running: Yes
-- Seconds_Behind_Master: 0
```

**복제 흐름:**

```
Blue MySQL (Master)
    │
    ├─► Binary Log 생성
    │   (모든 데이터 변경 기록)
    │
    ├─► Green MySQL로 전송
    │
    ▼
Green MySQL (Slave → Master)
    │
    ├─► Relay Log 저장
    │
    ├─► SQL 실행 (데이터 동기화)
    │
    └─► Seconds_Behind_Master: 0 확인
```

---

##### 4단계: Green 애플리케이션 배포

```bash
# Green 애플리케이션 이미지 빌드 (새 버전)
docker build -t myapp:green .

# Green 앱 시작
docker-compose --profile green up -d app_green
```

**배포 중 상태:**

```
사용자
  │
  ▼
Nginx ────────► Blue App (트래픽 100%)
                    │
                    ▼
               Blue MySQL ──(복제)──► Green MySQL
                                           │
                                           ▼
                                      Green App (준비 중)
```

---

##### 5단계: 헬스체크 및 검증

```bash
# 자동 헬스체크 (Docker Compose)
# - interval: 30s
# - timeout: 10s
# - retries: 5

# 수동 헬스체크
for i in {1..10}; do
  if docker exec app_green curl -sf http://localhost:8080/health; then
    echo "✓ Green is healthy"
    break
  fi
  echo "Waiting for Green... ($i/10)"
  sleep 5
done

# 데이터베이스 연결 확인
docker exec app_green curl -sf http://localhost:8080/db-check

# 복제 지연 확인
docker exec mysql_green mysql -u root -prootpass -e \
  "SHOW SLAVE STATUS\G" | grep "Seconds_Behind_Master"
```

**검증 체크리스트:**

```bash
☐ Green 애플리케이션 헬스체크 통과
☐ Green 데이터베이스 연결 정상
☐ 복제 지연 시간 0초
☐ Green 애플리케이션 로그 정상
☐ Green 주요 API 엔드포인트 응답 정상
```

---

##### 6단계: 트래픽 전환

```bash
./scripts/switch_to_green.sh
```

**스크립트 내부 동작:**

```bash
#!/bin/bash
set -e

echo "🔄 Switching traffic to Green environment..."

# 1. Green 환경 최종 헬스체크
if ! docker exec app_green curl -sf http://localhost:8080/health; then
  echo "❌ Green is not healthy. Aborting."
  exit 1
fi

# 2. 복제 지연 확인
SECONDS_BEHIND=$(docker exec mysql_green mysql -u root -prootpass -N -e \
  "SHOW SLAVE STATUS\G" | grep "Seconds_Behind_Master" | awk '{print $2}')

if [ "$SECONDS_BEHIND" != "0" ] && [ "$SECONDS_BEHIND" != "NULL" ]; then
  echo "⚠️ Replication lag detected: ${SECONDS_BEHIND}s"
  read -p "Continue anyway? (y/n) " -n 1 -r
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

# 3. Green MySQL 쓰기 활성화
docker exec mysql_green mysql -u root -prootpass -e \
  "SET GLOBAL read_only = OFF;"

# 4. Nginx 업스트림 변경
docker cp ./nginx/upstream-green.conf nginx_lb:/etc/nginx/upstream.conf

# 5. Nginx 설정 리로드
docker exec nginx_lb nginx -s reload

# 6. 트래픽 전환 검증
sleep 2
RESPONSE=$(curl -s http://localhost:3030/health)
if [[ $RESPONSE == *"green"* ]]; then
  echo "✅ Traffic switched to Green successfully!"
else
  echo "❌ Traffic switch failed. Current: $RESPONSE"
  exit 1
fi
```

**트래픽 전환 타임라인:**

```
T=0s   Blue: 100% │ Green: 0%    [전환 명령 실행]
T=1s   Blue: 80%  │ Green: 20%   [Nginx 설정 변경]
T=2s   Blue: 20%  │ Green: 80%   [Nginx reload 진행 중]
T=3s   Blue: 0%   │ Green: 100%  [전환 완료]
```

---

##### 7단계: 모니터링 및 검증

```bash
# 여러 요청으로 전환 확인
for i in {1..20}; do
  curl -s http://localhost:3030/health
  sleep 0.5
done
# 모든 출력: OK - green

# 로그 모니터링
docker logs -f app_green

# 에러 로그 확인
docker logs app_green 2>&1 | grep -i error

# 성능 메트릭 확인
curl http://localhost:3030/actuator/metrics
```

**모니터링 체크리스트:**

```bash
☐ 모든 요청이 Green으로 라우팅됨
☐ HTTP 5xx 에러 없음
☐ 응답 시간 정상 범위 내
☐ 데이터베이스 쿼리 정상 실행
☐ 메모리/CPU 사용량 정상
```

---

##### 8단계: Blue 환경 정리 (선택적)

```bash
# 즉시 정리 (권장하지 않음)
docker-compose stop app_blue mysql_blue

# 또는 일정 시간 대기 후 정리 (권장)
# 1-2시간 모니터링 후 문제 없으면 정리
sleep 7200  # 2시간 대기
docker-compose stop app_blue mysql_blue
```

**⚠️ 주의사항:**
- Green 안정화 확인 전까지 Blue 환경 유지 권장
- 롤백이 필요할 수 있으므로 최소 1-2시간 대기
- 중요 서비스는 24시간 대기 후 정리

---

### 배포 메트릭

| 항목 | 값 |
|------|-----|
| **다운타임** | 0초 |
| **트래픽 전환 시간** | 2-3초 |
| **롤백 소요 시간** | ~6초 |
| **복제 설정 시간** | 10-15초 |
| **전체 배포 시간** | 3-5분 |

---

## ⏪ 롤백 흐름

### Green → Blue 즉시 롤백

#### 롤백이 필요한 상황

```bash
☑ 헬스체크 실패 (연속 3회 이상)
☑ HTTP 5xx 에러 급증 (임계값 초과)
☑ 응답 시간 급격히 증가 (평균 > 5초)
☑ 데이터베이스 연결 실패
☑ 치명적인 버그 발견
☑ 비즈니스 로직 오류
```

#### 롤백 프로세스

```
[1. 문제 감지 및 판단]
         ↓
[2. Blue 환경 상태 확인]
         ↓
[3. Blue 재시작 (필요시)]
         ↓
[4. 트래픽 즉시 전환]
         ↓
[5. 롤백 검증]
         ↓
[6. Green 환경 정리]
         ↓
[7. 사후 분석]
```

#### 단계별 상세 가이드

##### 1단계: 문제 감지 및 판단

```bash
# Green 환경 헬스체크
curl http://localhost:3030/health
# 출력: 500 Internal Server Error (문제 감지!)

# 로그 확인
docker logs app_green --tail 100 | grep -i error
# ERROR: NullPointerException at UserService.findUser()

# 에러율 확인
curl http://localhost:3030/actuator/metrics/http.server.requests
# 5xx errors: 45% (임계값 5% 초과)

# 의사결정
echo "🚨 롤백 필요: 5xx 에러율 45% (임계값 5% 초과)"
```

---

##### 2단계: Blue 환경 상태 확인

```bash
# Blue 컨테이너 실행 여부 확인
if docker ps | grep -q "app_blue"; then
  echo "✓ Blue is running"
  docker exec app_blue curl -sf http://localhost:8080/health
else
  echo "⚠️ Blue is stopped. Need to restart."
fi

# Blue MySQL 상태 확인
docker exec mysql_blue mysqladmin ping -h localhost -u root -prootpass
```

---

##### 3단계: Blue 재시작 (필요시)

```bash
# Blue가 정지된 경우
if ! docker ps | grep -q "app_blue"; then
  echo "🔄 Restarting Blue environment..."

  # Blue 컨테이너 시작
  docker-compose up -d app_blue mysql_blue

  # 헬스체크 대기 (최대 60초)
  for i in {1..12}; do
    if docker exec app_blue curl -sf http://localhost:8080/health; then
      echo "✓ Blue is ready"
      break
    fi
    echo "Waiting for Blue... ($i/12)"
    sleep 5
  done
fi
```

---

##### 4단계: 트래픽 즉시 전환

```bash
./scripts/switch_to_blue.sh
```

**스크립트 동작:**

```bash
#!/bin/bash
set -e

echo "⏪ Rolling back to Blue environment..."

# 1. Blue 헬스체크
if ! docker exec app_blue curl -sf http://localhost:8080/health; then
  echo "❌ Blue is not healthy. Cannot rollback."
  exit 1
fi

# 2. Blue MySQL 쓰기 활성화
docker exec mysql_blue mysql -u root -prootpass -e \
  "SET GLOBAL read_only = OFF;"

# 3. Nginx 업스트림 변경
docker cp ./nginx/upstream-blue.conf nginx_lb:/etc/nginx/upstream.conf

# 4. Nginx 리로드
docker exec nginx_lb nginx -s reload

# 5. 롤백 검증
sleep 2
RESPONSE=$(curl -s http://localhost:3030/health)
if [[ $RESPONSE == *"blue"* ]]; then
  echo "✅ Rolled back to Blue successfully!"
else
  echo "❌ Rollback failed. Current: $RESPONSE"
  exit 1
fi
```

**롤백 타임라인:**

```
T=0s   Green: 100% (에러 발생!)  [롤백 명령 실행]
T=2s   Blue 상태 확인              [헬스체크]
T=4s   Nginx 설정 변경              [업스트림 교체]
T=6s   Blue: 100%                  [롤백 완료]
```

---

##### 5단계: 롤백 검증

```bash
# 연속 요청 테스트
for i in {1..50}; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3030/health)
  if [ "$STATUS" != "200" ]; then
    echo "❌ Request $i failed: $STATUS"
  fi
  sleep 0.1
done

# 에러율 확인
curl http://localhost:3030/actuator/metrics/http.server.requests | grep "5xx"
# 5xx errors: 0% (정상)

# 응답 시간 확인
curl -w "Time: %{time_total}s\n" -o /dev/null -s http://localhost:3030/api/users
# Time: 0.123s (정상)
```

---

##### 6단계: Green 환경 정리

```bash
# Green 컨테이너 정지
docker-compose --profile green stop

# 로그 백업 (분석용)
docker logs app_green > /tmp/green_failure_$(date +%Y%m%d_%H%M%S).log

# Green 환경 제거 (선택)
# docker-compose --profile green down
```

---

##### 7단계: 사후 분석

```bash
# 실패 원인 분석
echo "📊 Rollback Incident Report"
echo "- Timestamp: $(date)"
echo "- Trigger: 5xx error rate exceeded 45%"
echo "- Root Cause: NullPointerException in UserService"
echo "- Rollback Duration: 6 seconds"
echo "- Data Loss: None"

# 로그 분석
grep -i "error\|exception" /tmp/green_failure_*.log > failure_analysis.txt

# 개선 사항 도출
echo "Action Items:"
echo "1. Add null check in UserService.findUser()"
echo "2. Increase test coverage for UserService"
echo "3. Add integration test for user lookup"
```

---

### 롤백 메트릭

| 항목 | 값 |
|------|-----|
| **롤백 소요 시간** | 6-10초 |
| **롤백 다운타임** | 0초 |
| **데이터 손실** | 없음 (복제 유지) |
| **에러 노출 시간** | 최소화 (초 단위) |

---

## 🛠️ 주요 기능

### 1. 무중단 배포 (Zero-Downtime Deployment)

```
전통적 배포:
  Stop → Update → Start
  ▼
  다운타임 발생 (1-5분)

블루-그린 배포:
  Green 준비 → 트래픽 전환
  ▼
  다운타임 0초
```

### 2. Master-Master Replication

```sql
-- Blue MySQL ⇄ Green MySQL 양방향 복제
-- 어느 환경이 활성화되어도 데이터 일관성 보장

-- Blue → Green 복제
mysql_blue> INSERT INTO users VALUES (1, 'Alice');
mysql_green> SELECT * FROM users;  -- (1, 'Alice') 자동 복제

-- Green → Blue 복제
mysql_green> INSERT INTO users VALUES (2, 'Bob');
mysql_blue> SELECT * FROM users;   -- (2, 'Bob') 자동 복제
```

### 3. 자동 헬스체크

```yaml
# docker-compose.yml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
  interval: 30s
  timeout: 10s
  retries: 5
  start_period: 40s
```

### 4. 트래픽 제어

```nginx
# Nginx 동적 업스트림
upstream app {
    server app_blue:8080;   # 또는 app_green:8080
}

# 전환 시 설정 파일만 교체 후 reload
# nginx -s reload (무중단 설정 변경)
```

### 5. 리소스 제한

| 서비스 | CPU Limit | Memory Limit |
|--------|-----------|--------------|
| Nginx | 0.5 core | 256MB |
| App (Blue/Green) | 1.0 core | 1GB |
| MySQL (Blue/Green) | 1.0 core | 1GB |

---

## 🗄️ 스키마 마이그레이션 전략

### 문제: 스키마 변경과 블루-그린 배포

블루-그린 배포에서 **데이터베이스 스키마 변경**은 가장 까다로운 과제입니다:

```
Blue (v1.0): 기존 스키마 사용
Green (v2.0): 새 스키마 필요

문제: 두 버전이 동시에 같은 DB를 사용해야 함!
```

### 해결책: Expand-Contract 패턴

**2단계 배포로 안전하게 스키마 변경**

#### Phase 1: Expand (확장) - v2.0 배포

```sql
-- ❌ 위험: 컬럼 이름 직접 변경 (Blue 앱이 깨짐)
ALTER TABLE users CHANGE name full_name VARCHAR(255);

-- ✅ 안전: 새 컬럼 추가 (기존 컬럼 유지)
ALTER TABLE users ADD COLUMN full_name VARCHAR(255);

-- 애플리케이션 코드 (v2.0)
public void updateUser(User user) {
    // 양쪽 컬럼 모두 업데이트
    db.execute("UPDATE users SET name = ?, full_name = ? WHERE id = ?",
               user.getName(), user.getName(), user.getId());
}
```

**이점:**
- v1.0 (Blue): `name` 컬럼 계속 사용 가능
- v2.0 (Green): `full_name` 컬럼 사용하면서 `name`도 업데이트
- 롤백 가능: 언제든 Blue로 복귀 가능

---

#### Phase 2: Contract (축소) - v3.0 배포 (1-2주 후)

```sql
-- v2.0이 안정화된 후 (모든 트래픽이 Green으로 이동)
-- 이제 안전하게 기존 컬럼 삭제
ALTER TABLE users DROP COLUMN name;

-- 애플리케이션 코드 (v3.0)
public void updateUser(User user) {
    // full_name만 사용
    db.execute("UPDATE users SET full_name = ? WHERE id = ?",
               user.getName(), user.getId());
}
```

---

### 안전한 변경 vs 위험한 변경

#### ✅ 안전한 변경 (단일 배포 가능)

```sql
-- 1. 컬럼 추가 (NULL 허용 또는 DEFAULT 값)
ALTER TABLE users ADD COLUMN email VARCHAR(255);
ALTER TABLE users ADD COLUMN status VARCHAR(20) DEFAULT 'active';

-- 2. 테이블 추가
CREATE TABLE orders (
    id INT PRIMARY KEY,
    user_id INT,
    amount DECIMAL(10,2)
);

-- 3. 인덱스 추가/삭제
CREATE INDEX idx_user_email ON users(email);
DROP INDEX idx_old_column ON users;

-- 4. 뷰 추가
CREATE VIEW active_users AS
SELECT * FROM users WHERE status = 'active';
```

---

#### ⚠️ 위험한 변경 (2단계 배포 필수)

```sql
-- 1. 컬럼 이름 변경 ❌
ALTER TABLE users CHANGE name full_name VARCHAR(255);
-- → Expand-Contract 패턴 사용!

-- 2. 컬럼 삭제 ❌
ALTER TABLE users DROP COLUMN old_field;
-- → 2단계로 나누어 삭제!

-- 3. 컬럼 타입 변경 ❌
ALTER TABLE users MODIFY COLUMN age VARCHAR(10);
-- → 새 컬럼 추가 후 마이그레이션!

-- 4. NOT NULL 제약 추가 ❌
ALTER TABLE users MODIFY COLUMN email VARCHAR(255) NOT NULL;
-- → 데이터 정합성 확인 후 단계적 적용!
```

---

### 실전 예제: 컬럼 이름 변경

#### 잘못된 방법 ❌

```sql
-- 한 번에 변경 (Blue 앱이 즉시 에러!)
ALTER TABLE users CHANGE name full_name VARCHAR(255);

-- Blue 앱 에러 발생
ERROR: Unknown column 'name' in 'field list'
```

---

#### 올바른 방법 ✅

**Step 1: v2.0 배포 (Expand)**

```sql
-- 1. 새 컬럼 추가
ALTER TABLE users ADD COLUMN full_name VARCHAR(255);

-- 2. 기존 데이터 복사
UPDATE users SET full_name = name WHERE full_name IS NULL;

-- 3. 트리거 생성 (양방향 동기화)
DELIMITER $$
CREATE TRIGGER sync_user_name
BEFORE UPDATE ON users
FOR EACH ROW
BEGIN
    IF NEW.name IS NOT NULL THEN
        SET NEW.full_name = NEW.name;
    END IF;
    IF NEW.full_name IS NOT NULL THEN
        SET NEW.name = NEW.full_name;
    END IF;
END$$
DELIMITER ;
```

```java
// v2.0 애플리케이션 코드
public void updateUser(User user) {
    // 양쪽 컬럼 모두 업데이트
    jdbcTemplate.update(
        "UPDATE users SET name = ?, full_name = ? WHERE id = ?",
        user.getFullName(), user.getFullName(), user.getId()
    );
}
```

**배포 상태:**
```
Blue (v1.0): name 컬럼 사용 → 트리거로 full_name 자동 업데이트
Green (v2.0): full_name 사용, name도 함께 업데이트
→ 두 버전 모두 정상 작동!
```

---

**Step 2: v3.0 배포 (Contract) - 1-2주 후**

```sql
-- 1. 트리거 삭제
DROP TRIGGER sync_user_name;

-- 2. 기존 컬럼 삭제
ALTER TABLE users DROP COLUMN name;
```

```java
// v3.0 애플리케이션 코드
public void updateUser(User user) {
    // full_name만 사용
    jdbcTemplate.update(
        "UPDATE users SET full_name = ? WHERE id = ?",
        user.getFullName(), user.getId()
    );
}
```

---

### 상세 가이드

전체 마이그레이션 전략은 다음 문서를 참조하세요:

- **[SCHEMA_MIGRATION_GUIDE.md](./SCHEMA_MIGRATION_GUIDE.md)** - 스키마 변경 완전 가이드
- **[SCHEMA_ROLLBACK_GUIDE.md](./SCHEMA_ROLLBACK_GUIDE.md)** - 스키마 롤백 전략
- **[examples/schema-migration/](./examples/schema-migration/)** - 실전 예제

---

## 🔧 운영 가이드

### 배포 명령어

```bash
# Green으로 전환
./scripts/switch_to_green.sh

# Blue로 전환 (롤백)
./scripts/switch_to_blue.sh

# 통합 스크립트
./scripts/switch_env.sh green
./scripts/switch_env.sh blue
```

### 상태 확인

```bash
# 애플리케이션 상태
curl http://localhost:3030/health
curl http://localhost:3030/version

# Nginx 상태
curl http://localhost:8081/nginx-health
curl http://localhost:8081/upstream-health

# 컨테이너 상태
docker-compose ps

# 로그 확인
docker logs -f app_blue
docker logs -f app_green
```

### 데이터베이스 복제 상태

```bash
# Blue → Green 복제 확인
docker exec mysql_green mysql -u root -prootpass -e "SHOW SLAVE STATUS\G"

# Green → Blue 복제 확인
docker exec mysql_blue mysql -u root -prootpass -e "SHOW SLAVE STATUS\G"

# 복제 지연 확인
docker exec mysql_green mysql -u root -prootpass -e \
  "SHOW SLAVE STATUS\G" | grep "Seconds_Behind_Master"
```

---

## 🐛 트러블슈팅

### 1. 컨테이너가 시작되지 않는 경우

```bash
# 로그 확인
docker-compose logs app_blue

# 일반적인 원인
# - 포트 충돌 (이미 사용 중인 포트)
# - 메모리 부족
# - 이미지 빌드 실패

# 해결 방법
docker-compose down
docker system prune -a  # 불필요한 리소스 정리
docker-compose up -d
```

### 2. MySQL 연결 오류

```bash
# MySQL 상태 확인
docker exec mysql_blue mysqladmin ping -h localhost -u root -prootpass

# 일반적인 원인
# - MySQL이 아직 완전히 시작되지 않음
# - 비밀번호 불일치
# - 네트워크 문제

# 해결 방법
# 1. MySQL 준비 대기
sleep 15

# 2. 비밀번호 확인
docker exec mysql_blue mysql -u root -prootpass -e "SELECT 1"

# 3. 네트워크 확인
docker network ls
docker network inspect bluegreen-network
```

### 3. 복제 문제

```bash
# 복제 상태 확인
docker exec mysql_green mysql -u root -prootpass -e "SHOW SLAVE STATUS\G"

# 일반적인 문제
# - Slave_IO_Running: No
# - Slave_SQL_Running: No
# - Seconds_Behind_Master: NULL

# 해결 방법
# 1. 복제 재시작
docker exec mysql_green mysql -u root -prootpass -e "STOP SLAVE; START SLAVE;"

# 2. 복제 재설정
./scripts/setup_replication.sh

# 3. Position 수동 확인
docker exec mysql_blue mysql -u root -prootpass -e "SHOW MASTER STATUS\G"
```

### 4. Nginx 설정 문제

```bash
# Nginx 설정 테스트
docker exec nginx_lb nginx -t

# 설정 리로드
docker exec nginx_lb nginx -s reload

# Nginx 재시작
docker-compose restart nginx
```

### 5. 트래픽이 전환되지 않는 경우

```bash
# 1. 현재 업스트림 확인
docker exec nginx_lb cat /etc/nginx/upstream.conf

# 2. 업스트림 수동 변경
docker cp ./nginx/upstream-green.conf nginx_lb:/etc/nginx/upstream.conf
docker exec nginx_lb nginx -s reload

# 3. 전환 검증
for i in {1..10}; do curl -s http://localhost:3030/health; done
```

---

## 📁 프로젝트 구조

```
blue-green-study/
├── .github/
│   └── workflows/
│       ├── blue_green_deploy.yml    # 블루-그린 자동 배포 파이프라인
│       ├── manual_deploy.yml        # 수동 배포 워크플로우
│       └── pr_validation.yml        # PR 검증 및 테스트
├── bluegreen/                       # Spring Boot 애플리케이션
│   ├── src/
│   │   ├── main/
│   │   │   ├── java/com/study/bluegreen/
│   │   │   │   ├── BlueGreenApplication.java
│   │   │   │   └── ApiController.java
│   │   │   └── resources/
│   │   │       ├── application.yml       # 공통 설정
│   │   │       ├── application-blue.yml  # Blue 환경 설정
│   │   │       └── application-green.yml # Green 환경 설정
│   │   └── test/
│   └── build.gradle
├── mysql/
│   ├── blue.cnf                     # Blue MySQL 설정
│   └── green.cnf                    # Green MySQL 설정
├── nginx/
│   ├── nginx.conf                   # Nginx 메인 설정
│   ├── upstream.conf                # 현재 활성 업스트림
│   ├── upstream-blue.conf           # Blue 업스트림 템플릿
│   └── upstream-green.conf          # Green 업스트림 템플릿
├── scripts/
│   ├── setup_replication.sh         # MySQL 복제 설정 스크립트
│   ├── switch_to_blue.sh            # Blue로 전환 (롤백)
│   ├── switch_to_green.sh           # Green으로 전환
│   ├── switch_env.sh                # 통합 전환 스크립트
│   ├── demo.sh                      # 대화형 데모
│   └── test_deployment.sh           # 배포 테스트
├── examples/
│   └── schema-migration/
│       └── expand-contract-example.md
├── docker-compose.yml               # 컨테이너 오케스트레이션
├── Dockerfile                       # 애플리케이션 이미지
├── SCHEMA_MIGRATION_GUIDE.md        # 스키마 마이그레이션 가이드
├── SCHEMA_ROLLBACK_GUIDE.md         # 스키마 롤백 가이드
└── README.md
```

---

## 🔑 기술 스택

| 카테고리 | 기술 | 버전 |
|---------|------|------|
| **언어** | Java | 21 (Amazon Corretto) |
| **프레임워크** | Spring Boot | 3.x |
| **빌드 도구** | Gradle | 8.14.3 |
| **데이터베이스** | MySQL | 8.0 |
| **웹 서버** | Nginx | Alpine |
| **컨테이너** | Docker & Docker Compose | - |
| **CI/CD** | GitHub Actions | - |

---

## 📚 학습 포인트

이 프로젝트를 통해 다음을 학습할 수 있습니다:

- ✅ **블루-그린 배포 전략** - 무중단 배포의 원리와 구현
- ✅ **Docker 멀티 컨테이너** - Docker Compose를 통한 오케스트레이션
- ✅ **MySQL 복제** - Master-Master Replication 설정 및 관리
- ✅ **Nginx 로드밸런싱** - 동적 업스트림 관리 및 트래픽 제어
- ✅ **헬스체크** - 애플리케이션 상태 모니터링
- ✅ **Shell 스크립트** - 배포 자동화
- ✅ **CI/CD** - GitHub Actions 파이프라인
- ✅ **스키마 마이그레이션** - Expand-Contract 패턴

---

## ✅ 구현 완료
- CI/CD 파이프라인 (GitHub Actions)
- Master-Master Replication
- 자동화된 배포 스크립트
- 헬스체크 및 모니터링
- 스키마 마이그레이션 전략 문서화

---

## 📝 라이선스

이 프로젝트는 MIT 라이선스를 따릅니다.

---

## 💡 참고사항

- 이 프로젝트는 **학습 목적**으로 제작되었습니다
- 프로덕션 환경 적용 시 추가적인 보안 및 성능 최적화가 필요합니다
- 스키마 변경 시 반드시 Expand-Contract 패턴을 따르세요
- Blue 환경은 롤백을 위해 최소 1-2시간 유지하는 것을 권장합니다
