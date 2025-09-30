# Blue-Green Deployment Study

Docker 컨테이너 기반 블루-그린 배포 실습 레포지토리입니다.

## 🏗️ 아키텍처

```
                [Nginx Load Balancer]
                        |
              ┌─────────┼─────────┐
              ▼                   ▼
    [Blue Environment]    [Green Environment]
     - Spring Boot App     - Spring Boot App
     - MySQL Master       - MySQL Slave
```

## 📋 구성 요소

- **Nginx**: 로드밸런서 및 리버스 프록시
- **Spring Boot**: 애플리케이션 서버 (Blue/Green)
- **MySQL**: 데이터베이스 (Master-Slave 복제)
- **Docker Compose**: 컨테이너 오케스트레이션

## 🔄 블루-그린 배포 흐름

블루-그린 배포는 두 개의 동일한 운영 환경(Blue/Green)을 유지하면서 무중단 배포를 실현하는 전략입니다.

## 📋 배포 시나리오별 상세 가이드

### 시나리오 1: 초기 배포 (Clean State)

**상황**: 아무것도 배포되지 않은 상태에서 첫 배포

#### 1단계: 인프라 준비
```bash
# 네트워크 및 볼륨 자동 생성
docker-compose up -d mysql_blue nginx
```
**수행 작업:**
- Docker 네트워크 생성 (`bluegreen-network`)
- MySQL 볼륨 생성 및 초기화
- Nginx 로드밸런서 시작

#### 2단계: Blue 환경 배포
```bash
# Blue 애플리케이션 배포
docker build -t myapp:blue .
docker-compose up -d app_blue
```
**배포 흐름:**
```
[빌드] → [이미지 생성] → [컨테이너 시작] → [헬스체크]
   ↓           ↓              ↓              ↓
Gradle     myapp:blue      app_blue       30초 대기
```

#### 3단계: 초기 트래픽 설정
```bash
# Nginx에서 Blue로 트래픽 라우팅 설정 (자동)
# upstream.conf가 기본적으로 Blue를 가리킴
```

#### 4단계: 검증
```bash
curl http://localhost:3030/health
# 응답: OK - blue

curl http://localhost:3030/version
# 응답: Version: 1 - Env: blue
```

**✅ 결과 상태:**
```
사용자 → [Nginx:3030] → [Blue App:8080] ← [Blue MySQL:3306]
```

---

### 시나리오 2: Blue → Green 무중단 배포

**상황**: Blue 환경이 운영 중이며, 새 버전을 Green으로 배포

#### 1단계: 현재 상태 확인
```bash
# 현재 활성 환경 확인
curl http://localhost:3030/health
# 응답: OK - blue

# 컨테이너 상태 확인
docker ps --format "table {{.Names}}\t{{.Status}}"
```
**예상 출력:**
```
NAMES          STATUS
app_blue       Up 10 minutes (healthy)
mysql_blue     Up 10 minutes (healthy)
nginx_lb       Up 10 minutes
```

#### 2단계: Green 환경 준비 (무중단)
```bash
# MySQL 복제 설정
docker-compose --profile green up -d mysql_green
sleep 10
./scripts/setup_replication.sh
```
**복제 설정 과정:**
```
Blue MySQL (Master)
    ↓ [Binary Log]
    ↓ [Position: 197]
    ↓
Green MySQL (Slave)
    ↓ [START SLAVE]
    ↓ [Replication Running]
    ✓ [Data Synced]
```

**핵심 포인트:**
- ⚠️ **Blue는 계속 트래픽 처리** (다운타임 0초)
- Green MySQL이 Blue 데이터를 실시간 복제
- 복제 지연(Seconds_Behind_Master) 확인

#### 3단계: Green 애플리케이션 배포
```bash
# 새 버전 이미지 빌드
docker build -t myapp:green .

# Green 애플리케이션 시작
docker-compose --profile green up -d app_green
```
**배포 중 상태:**
```
사용자 → [Nginx] → [Blue App] (트래픽 100%)
                      ↓
                 [Blue MySQL] → [Green MySQL] (복제)
                      ↑              ↓
                  (활성)        [Green App] (준비중)
```

#### 4단계: Green 헬스체크
```bash
# 자동으로 30초간 헬스체크 수행
# 최대 30회 재시도 (10초 간격)
for i in {1..30}; do
    if docker exec app_green curl -s -f http://localhost:8080/health; then
        echo "Green is ready!"
        break
    fi
    sleep 10
done
```

#### 5단계: 트래픽 전환
```bash
./scripts/switch_to_green.sh
```
**전환 과정 상세:**
```bash
1. Green 환경 최종 헬스체크
   ✓ app_green:8080/health → OK

2. 복제 지연 확인
   mysql> SHOW SLAVE STATUS\G
   Seconds_Behind_Master: 0  ✓

3. Green MySQL 쓰기 활성화
   mysql_green> SET GLOBAL read_only = OFF;

4. Nginx 업스트림 변경
   upstream.conf: app_blue → app_green
   nginx -s reload

5. 트래픽 검증 (5초 후)
   curl localhost:3030/health
   → OK - green ✓
```

**트래픽 전환 타임라인:**
```
T+0s:  Blue 100% | Green 0%   (전환 시작)
T+1s:  Blue 50%  | Green 50%  (Nginx reload 중)
T+2s:  Blue 0%   | Green 100% (전환 완료)
```

#### 6단계: 전환 후 검증
```bash
# 여러 요청 테스트
for i in {1..10}; do
    curl -s http://localhost:3030/health
    sleep 0.5
done
# 모든 응답: OK - green
```

#### 7단계: Blue 환경 정리 (선택적)
```bash
# 10초 대기 후 Blue 정리
sleep 10
docker-compose stop app_blue mysql_blue
```

**✅ 최종 상태:**
```
사용자 → [Nginx:3030] → [Green App:8080] ← [Green MySQL:3306]
                              ↑
                         (100% 트래픽)

[Blue App] (정지)
[Blue MySQL] (정지)
```

**📊 배포 메트릭:**
- 다운타임: **0초**
- 전환 시간: ~2초
- 롤백 가능 기간: Green 검증 완료까지

---

### 시나리오 3: Green → Blue 롤백

**상황**: Green 배포 후 문제 발견, Blue로 즉시 롤백 필요

#### 1단계: 문제 감지
```bash
# Green 환경에서 에러 발생
curl http://localhost:3030/health
# 응답: 500 Internal Server Error

# 로그 확인
docker logs app_green --tail 50
# ERROR: Database connection failed
```

#### 2단계: Blue 환경 재시작 (이미 정지된 경우)
```bash
# Blue가 정지되어 있으면 재시작
if ! docker ps | grep -q "app_blue"; then
    docker-compose up -d app_blue mysql_blue
    sleep 10
fi
```

#### 3단계: 즉시 롤백 실행
```bash
./scripts/switch_to_blue.sh
```
**롤백 과정:**
```bash
1. Blue 환경 헬스체크
   ✓ app_blue:8080/health → OK

2. Nginx 업스트림 변경
   upstream.conf: app_green → app_blue
   nginx -s reload

3. 트래픽 검증
   curl localhost:3030/health
   → OK - blue ✓

4. Green 환경 정리
   docker-compose stop app_green mysql_green
```

**⚡ 롤백 타임라인:**
```
T+0s:  Green 100% (에러 발생)
T+2s:  Blue 시작 확인
T+4s:  Nginx 전환
T+6s:  Blue 100% (롤백 완료)
```

**✅ 롤백 완료:**
```
사용자 → [Nginx:3030] → [Blue App:8080] ← [Blue MySQL:3306]
                              ↑
                         (안정적인 이전 버전)
```

**📊 롤백 메트릭:**
- 롤백 시간: **~6초**
- 에러 노출 시간: 최소화
- 데이터 손실: 없음 (MySQL 복제 유지)

---

### 시나리오 4: Green 운영 중 → Blue로 새 버전 배포

**상황**: Green이 운영 중이며, Blue로 새 버전 배포 (역방향 배포)

이 시나리오는 **시나리오 2의 역방향**으로, 동일한 프로세스를 따릅니다:

#### 간략 흐름:
```bash
1. 현재 상태: Green 활성
   curl localhost:3030/health → OK - green

2. Blue 환경 준비
   docker build -t myapp:blue .
   docker-compose up -d app_blue mysql_blue

3. Blue 헬스체크 대기 (30초)

4. 트래픽 전환
   ./scripts/switch_to_blue.sh

5. 검증 및 Green 정리
   docker-compose stop app_green mysql_green
```

**✅ 결과:** Green → Blue 무중단 전환 완료

---

### 시나리오 5: 동일 환경 업데이트 (In-Place Update)

**상황**: Blue 운영 중, Blue에 새 버전 직접 배포 (Green 미사용)

⚠️ **주의**: 이 방법은 짧은 다운타임이 발생합니다.

#### 프로세스:
```bash
1. 새 이미지 빌드
   docker build -t myapp:blue .

2. Blue 컨테이너 재시작
   docker-compose up -d --force-recreate app_blue

3. 헬스체크 대기
   # 약 10-15초 다운타임 발생

4. 서비스 복구
   curl localhost:3030/health → OK - blue
```

**⚠️ 다운타임:**
- 예상 다운타임: 10-20초
- 권장하지 않음 (무중단 배포 위반)

**💡 권장사항:**
항상 Blue ↔ Green 방식을 사용하여 무중단 배포 유지

---

## 🔄 배포 시나리오 비교표

| 시나리오 | 다운타임 | 롤백 시간 | 복잡도 | 권장도 |
|---------|---------|----------|--------|--------|
| 초기 배포 (Clean State) | N/A | N/A | ⭐ | ✅ 필수 |
| Blue → Green 배포 | **0초** | ~6초 | ⭐⭐ | ✅ 권장 |
| Green → Blue 롤백 | **0초** | ~6초 | ⭐⭐ | ✅ 권장 |
| Green → Blue 배포 | **0초** | ~6초 | ⭐⭐ | ✅ 권장 |
| In-Place Update | 10-20초 | N/A | ⭐ | ⚠️ 비권장 |

---

## 📊 배포 단계별 체크리스트

### 배포 전 (Pre-Deployment)
```bash
☐ 새 버전 이미지 빌드 완료
☐ 현재 활성 환경 확인
☐ 타겟 환경 리소스 가용성 확인
☐ 데이터베이스 백업 완료
☐ 복제 상태 정상 (Green 사용 시)
```

### 배포 중 (During Deployment)
```bash
☐ 타겟 환경 컨테이너 시작 성공
☐ 애플리케이션 헬스체크 통과
☐ 데이터베이스 연결 정상
☐ 복제 지연 시간 0초 (Green 사용 시)
☐ Nginx 트래픽 전환 성공
```

### 배포 후 (Post-Deployment)
```bash
☐ 새 환경에서 정상 응답 확인
☐ 주요 기능 테스트 통과
☐ 로그 모니터링 (에러 없음)
☐ 성능 메트릭 정상
☐ 이전 환경 정리 (선택)
```

### 롤백 조건
```bash
☑ 헬스체크 실패 (3회 이상)
☑ HTTP 5xx 에러 급증
☑ 응답 시간 임계값 초과
☑ 데이터베이스 연결 실패
☑ 치명적인 버그 발견
```

---

## 🎯 배포 전략 선택 가이드

### 언제 Blue-Green을 사용할까?

**✅ 사용 권장:**
- 프로덕션 환경 배포
- 중요 업데이트/핫픽스
- 대규모 리팩토링
- 데이터베이스 마이그레이션 포함

**⚠️ 사용 고려:**
- 개발/스테이징 환경 (간소화 가능)
- 매우 작은 패치 (비용 대비 효과)

### 배포 시간대 권장사항

| 배포 유형 | 권장 시간 | 이유 |
|----------|----------|------|
| Major Update | 새벽 2-4시 | 트래픽 최소 시간대 |
| Minor Update | 업무 시간 가능 | 무중단 배포 보장 |
| Hotfix | 즉시 | 긴급 수정 필요 |
| 데이터 마이그레이션 | 새벽 2-4시 | 복제 지연 최소화 |

### 🔧 핵심 메커니즘

#### 🔀 트래픽 스위칭
```nginx
# Nginx 업스트림 설정
upstream app {
    server app_blue:8080;   # 현재 활성 환경
}

# 스위칭 시 sed 명령으로 변경
sed -i 's/server app_blue:8080/server app_green:8080/g' nginx.conf
nginx -s reload
```

#### 🗄️ 데이터베이스 복제
```sql
-- Master (Active 환경)
SET GLOBAL read_only = OFF;  -- 쓰기 가능

-- Slave (Standby 환경)
START SLAVE;                 -- 복제 시작
SET GLOBAL read_only = ON;   -- 읽기 전용
```

#### 🏥 헬스체크 메커니즘
```bash
# 애플리케이션 헬스체크
curl -f http://app:8080/health

# 복제 상태 확인
mysql -e "SHOW SLAVE STATUS\G" | grep "Seconds_Behind_Master"

# 전환 검증
curl http://localhost:3030/health | grep "green"
```

### ⚡ 장점과 특징

| 장점 | 설명 |
|------|------|
| **무중단 배포** | 트래픽 손실 없이 새 버전 배포 |
| **즉시 롤백** | 문제 발생 시 이전 환경으로 즉시 복원 |
| **리스크 최소화** | 새 버전을 프로덕션과 동일한 환경에서 테스트 |
| **데이터 일관성** | Master-Slave 복제로 데이터 동기화 보장 |
| **모니터링** | 배포 과정의 각 단계별 검증 |

### 📋 배포 체크리스트

```bash
# 배포 전 체크리스트
□ 새 버전 이미지 준비 완료
□ Green 환경 리소스 가용성 확인
□ 데이터베이스 복제 상태 정상
□ 백업 및 복구 계획 수립

# 배포 중 모니터링
□ 애플리케이션 헬스체크 통과
□ 데이터베이스 연결 정상
□ 복제 지연 시간 허용 범위 내
□ 트래픽 전환 성공

# 배포 후 검증
□ 새 환경에서 정상적인 응답
□ 모든 기능 정상 작동 확인
□ 로그 및 메트릭 모니터링
□ 이전 환경 정리 (선택적)
```

## 🚀 빠른 시작

### 1. 환경 설정

```bash
# 환경 변수 확인
cp .env.example .env  # .env 파일이 이미 구성되어 있습니다

# 애플리케이션 빌드
cd bluegreen
./gradlew build
cd ..
```

### 2. Blue 환경 시작

```bash
# Blue 환경 시작
docker-compose up -d app_blue mysql_blue nginx

# 애플리케이션 확인
curl http://localhost:3030/health
# 응답: OK - blue
```

### 3. 복제 설정 (선택사항)

```bash
# Green MySQL 시작
docker-compose up -d mysql_green

# 복제 설정
./scripts/setup_replication.sh
```

### 4. 전체 데모 실행

```bash
# 대화형 데모 실행
./scripts/demo.sh

# 또는 테스트 스크립트 실행
./scripts/test_deployment.sh
```

## 🔄 배포 명령어

### 환경 전환

```bash
# Green으로 전환
./scripts/switch_to_green.sh

# Blue로 전환 (롤백)
./scripts/switch_to_blue.sh

# 또는 통합 스크립트 사용
./scripts/switch_env.sh green  # Green으로 전환
./scripts/switch_env.sh blue   # Blue로 전환
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
```

## 📁 프로젝트 구조

```
├── bluegreen/                    # Spring Boot 애플리케이션
│   ├── src/main/resources/
│   │   ├── application.yml       # 기본 설정
│   │   ├── application-blue.yml  # Blue 환경 설정
│   │   └── application-green.yml # Green 환경 설정
│   └── build.gradle
├── mysql/
│   ├── blue.cnf                  # Blue MySQL 설정
│   └── green.cnf                 # Green MySQL 설정
├── nginx/
│   └── nginx.conf                # Nginx 설정
├── scripts/
│   ├── setup_replication.sh      # 복제 설정
│   ├── switch_env.sh             # 환경 전환 (통합)
│   ├── switch_to_blue.sh         # Blue 전환
│   ├── switch_to_green.sh        # Green 전환
│   ├── demo.sh                   # 대화형 데모
│   └── test_deployment.sh        # 테스트 스크립트
├── docker-compose.yml            # 컨테이너 설정
├── Dockerfile                    # 애플리케이션 이미지
└── .env                          # 환경 변수
```

## 🛠️ 주요 개선사항

### ✅ 해결된 문제들

1. **포트 설정 통일**: 모든 스크립트에서 8080 포트 사용
2. **MySQL 비밀번호 통일**: 환경변수로 통합 관리
3. **Docker Compose 개선**: 헬스체크, MySQL 설정 파일 마운트 추가
4. **스크립트 안정성**: 에러 처리 및 검증 로직 강화
5. **Nginx 설정 향상**: 로드밸런싱, 헬스체크, 보안 헤더 추가

### 🔧 주요 기능

- **제로 다운타임 배포**: 트래픽 손실 없이 환경 전환
- **자동 헬스체크**: 배포 전 애플리케이션 상태 확인
- **데이터베이스 복제**: Master-Slave 구조로 데이터 일관성 보장
- **롤백 지원**: 문제 발생 시 이전 환경으로 자동 복원
- **모니터링**: Nginx 상태 페이지 및 헬스체크 엔드포인트

## 🗄️ 스키마 마이그레이션 전략

Blue-Green 배포에서 데이터베이스 스키마 변경은 신중하게 처리해야 합니다.

### **핵심 원칙**

1. **하위 호환성 유지**: 구 버전이 신 스키마에서 작동 가능
2. **확장-축소 패턴 사용**: 2단계 배포로 위험 최소화
3. **롤백 가능성 확보**: 언제든 이전 버전으로 복귀

### **안전한 변경 vs 위험한 변경**

#### ✅ 안전한 변경 (단일 배포 가능)
```sql
-- 컬럼 추가 (NULL 허용)
ALTER TABLE User ADD COLUMN email VARCHAR(255);

-- 테이블 추가
CREATE TABLE orders (...);

-- 인덱스 추가/삭제
CREATE INDEX idx_user_email ON User(email);
```

#### ⚠️ 위험한 변경 (2단계 배포 필수)
```sql
-- 컬럼 이름 변경
ALTER TABLE User CHANGE name full_name VARCHAR(255);  ❌

-- 컬럼 삭제
ALTER TABLE User DROP COLUMN old_field;  ❌
```

### **Expand-Contract 패턴 예제**

**Phase 1: Expand (v2.0)**
```sql
-- 새 컬럼 추가 (이전 컬럼 유지)
ALTER TABLE User ADD COLUMN full_name VARCHAR(255);

-- 동기화 트리거
CREATE TRIGGER user_sync BEFORE UPDATE ON User
FOR EACH ROW SET NEW.full_name = NEW.name;
```

**Phase 2: Contract (v3.0 - 1~2주 후)**
```sql
-- 이전 컬럼 삭제
ALTER TABLE User DROP COLUMN name;
```

### **상세 가이드**

전체 마이그레이션 가이드는 [SCHEMA_MIGRATION_GUIDE.md](./SCHEMA_MIGRATION_GUIDE.md)를 참조하세요.

실전 예제는 [examples/schema-migration/](./examples/schema-migration/)을 확인하세요.

---

## 🐛 트러블슈팅

### 일반적인 문제들

1. **컨테이너가 시작되지 않는 경우**
   ```bash
   docker-compose logs [service_name]
   ```

2. **MySQL 연결 오류**
   ```bash
   # MySQL 컨테이너 상태 확인
   docker exec mysql_blue mysqladmin ping -h localhost -u root -prootpass
   ```

3. **복제 문제**
   ```bash
   # Slave 상태 확인
   docker exec mysql_green mysql -u root -prootpass -e "SHOW SLAVE STATUS\G"
   ```

4. **Nginx 설정 문제**
   ```bash
   # Nginx 설정 테스트
   docker exec nginx_lb nginx -t
   ```

## 📚 학습 포인트

- Docker Compose를 이용한 멀티 컨테이너 애플리케이션 관리
- Nginx를 이용한 로드밸런싱 및 리버스 프록시 설정
- MySQL Master-Slave 복제 구성
- 무중단 배포 전략 구현
- 헬스체크 및 모니터링 설정
- Shell 스크립트를 이용한 배포 자동화

## 📈 확장 가능성

- CI/CD 파이프라인 통합
- 쿠버네티스 환경으로 마이그레이션
- 모니터링 및 로깅 시스템 추가 (Prometheus, Grafana)
- 부하 테스트 자동화
- 다중 인스턴스 배포

---

💡 **참고**: 이 프로젝트는 학습 목적으로 제작되었으며, 프로덕션 환경에서 사용하기 전에 추가적인 보안 및 성능 최적화가 필요할 수 있습니다.