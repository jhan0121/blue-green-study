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

### 📊 배포 과정 상세 흐름

#### 1️⃣ 초기 상태 (Blue 환경 운영)
```
사용자 → [Nginx] → [Blue App] ← [Blue MySQL (Master)]
                         ↓
                    [Green MySQL (Slave)]
                    [Green App (Standby)]
```
- **Blue 환경**이 실제 트래픽 처리
- **Green 환경**은 대기 상태 (복제를 통한 데이터 동기화)

#### 2️⃣ 새 버전 배포 준비
```bash
# 1. Green 환경에 새 버전 배포
docker-compose up -d app_green mysql_green

# 2. 헬스체크 및 준비상태 확인
curl http://localhost:8080/health  # Green 컨테이너 직접 확인
```

#### 3️⃣ 데이터 동기화 확인
```
Blue MySQL (Master) → Green MySQL (Slave)
        ↓                      ↓
   [실시간 복제]          [복제 지연 확인]
```
- MySQL 복제 상태 점검
- 데이터 동기화 완료 대기
- 복제 지연시간 모니터링

#### 4️⃣ 트래픽 전환 (Blue → Green)
```bash
# 전환 과정 자동화
./scripts/switch_to_green.sh

# 내부적으로 수행되는 작업들:
# 1. Green 환경 헬스체크
# 2. 복제 지연 확인 및 대기
# 3. Blue DB를 읽기전용으로 전환
# 4. Green DB에서 복제 중지 및 쓰기 활성화
# 5. Nginx 업스트림을 Green으로 변경
# 6. 전환 검증
```

#### 5️⃣ 전환 완료 상태
```
사용자 → [Nginx] → [Green App] ← [Green MySQL (Master)]
                         ↓
                    [Blue MySQL (Standby)]
                    [Blue App (Standby)]
```
- **Green 환경**이 실제 트래픽 처리
- **Blue 환경**은 롤백을 위해 대기

#### 6️⃣ 롤백 (문제 발생 시)
```bash
# 즉시 롤백 실행
./scripts/switch_to_blue.sh

# 자동 롤백 조건:
# - Green 환경 헬스체크 실패
# - 데이터베이스 연결 오류
# - 애플리케이션 응답 오류
```

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