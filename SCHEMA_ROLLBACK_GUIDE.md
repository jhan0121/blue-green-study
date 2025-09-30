# 스키마 변경 케이스별 롤백 가능성 가이드

## 📋 목차

1. [롤백 가능성 매트릭스](#롤백-가능성-매트릭스)
2. [안전한 변경 (즉시 롤백 가능)](#안전한-변경-즉시-롤백-가능)
3. [주의 필요 변경 (조건부 롤백)](#주의-필요-변경-조건부-롤백)
4. [위험한 변경 (롤백 불가/어려움)](#위험한-변경-롤백-불가어려움)
5. [롤백 전략별 체크리스트](#롤백-전략별-체크리스트)

---

## 롤백 가능성 매트릭스

| 변경 유형 | 롤백 난이도 | 데이터 손실 위험 | 권장 롤백 방법 | 최대 롤백 시간 |
|---------|-----------|----------------|--------------|--------------|
| 컬럼 추가 (NULL/기본값) | 🟢 쉬움 | 없음 | 트래픽 전환 | 즉시 |
| 테이블 추가 | 🟢 쉬움 | 없음 | 트래픽 전환 | 즉시 |
| 인덱스 추가 | 🟢 쉬움 | 없음 | 트래픽 전환 | 즉시 |
| 인덱스 삭제 | 🟢 쉬움 | 없음 | 트래픽 전환 + 재생성 | 5분 |
| 컬럼 추가 (NOT NULL) | 🟡 보통 | 낮음 | 조건부 (기본값 필요) | 10분 |
| 컬럼 이름 변경 (Phase 1) | 🟡 보통 | 없음 | 트래픽 전환 | 즉시 |
| 컬럼 이름 변경 (Phase 2) | 🔴 어려움 | 높음 | 스냅샷 복원 | 30분+ |
| 컬럼 삭제 | 🔴 불가능 | 매우 높음 | 백업 복원 | 1시간+ |
| 컬럼 타입 변경 | 🔴 어려움 | 높음 | 데이터 재변환 | 1시간+ |
| 테이블 삭제 | 🔴 불가능 | 매우 높음 | 백업 복원 | 2시간+ |

---

## 안전한 변경 (즉시 롤백 가능)

### 1. 컬럼 추가 (NULL 허용 또는 기본값)

#### 변경 내용
```sql
-- V2__add_email.sql
ALTER TABLE User ADD COLUMN email VARCHAR(255) DEFAULT NULL;
```

#### 롤백 시나리오

**상황**: v2.0 배포 후 5분 뒤 버그 발견

```bash
# 1단계: 트래픽을 Blue(v1.0)로 즉시 전환
$ ./scripts/switch_to_blue.sh

# 2단계: 확인
$ curl http://localhost/health
{"status":"ok","version":"1.0","environment":"blue"}

# 3단계 (선택): 스키마 롤백 (데이터 손실 없음)
$ docker exec mysql_blue mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "
USE bluegreen;
ALTER TABLE User DROP COLUMN email;
"
```

**결과**:
- ✅ 즉시 롤백 (1분 이내)
- ✅ 데이터 손실 없음 (v1.0은 email 컬럼 무시)
- ✅ 서비스 중단 없음

**이유**: v1.0 코드는 email 컬럼을 참조하지 않으므로 존재 여부와 무관하게 작동

---

### 2. 테이블 추가

#### 변경 내용
```sql
-- V2__add_orders_table.sql
CREATE TABLE orders (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT NOT NULL,
    total_amount DECIMAL(10,2),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

#### 롤백 시나리오

**상황**: v2.0에서 orders 테이블 관련 기능에 버그 발견

```bash
# 1단계: Blue로 트래픽 전환
$ ./scripts/switch_to_blue.sh

# 2단계: 테이블 삭제 (선택)
$ docker exec mysql_blue mysql -e "DROP TABLE IF EXISTS bluegreen.orders;"
```

**결과**:
- ✅ 즉시 롤백 가능
- ✅ 기존 User 데이터에 영향 없음
- ⚠️ orders 테이블 데이터는 손실 (새로 추가된 데이터)

**주의**: orders 테이블에 입력된 주문 데이터는 복구 불가. 롤백 전 데이터 백업 권장.

---

### 3. 인덱스 추가

#### 변경 내용
```sql
-- V2__add_email_index.sql
CREATE INDEX idx_user_email ON User(email);
```

#### 롤백 시나리오

```bash
# Blue로 트래픽 전환 (인덱스는 성능에만 영향, 기능에는 무관)
$ ./scripts/switch_to_blue.sh

# 인덱스 삭제 (선택)
$ docker exec mysql_blue mysql -e "DROP INDEX idx_user_email ON bluegreen.User;"
```

**결과**:
- ✅ 완전한 롤백
- ✅ 데이터 손실 없음
- ✅ 성능만 원래대로 (쿼리 속도 저하 가능)

---

### 4. 인덱스 삭제

#### 변경 내용
```sql
-- V2__drop_old_index.sql
DROP INDEX idx_old_field ON User;
```

#### 롤백 시나리오

**상황**: 인덱스 삭제 후 쿼리 성능 저하 발견

```bash
# 1단계: Blue로 트래픽 전환
$ ./scripts/switch_to_blue.sh

# 2단계: 인덱스 재생성
$ docker exec mysql_blue mysql -e "
USE bluegreen;
CREATE INDEX idx_old_field ON User(old_field);
"
```

**결과**:
- ✅ 롤백 가능
- ✅ 데이터 손실 없음
- ⏱️ 인덱스 재생성 시간 필요 (대용량 테이블의 경우 수 분 소요)

**예상 시간**:
- 100만 건: ~10초
- 1000만 건: ~2분
- 1억 건: ~20분

---

## 주의 필요 변경 (조건부 롤백)

### 5. 컬럼 추가 (NOT NULL 제약조건)

#### 변경 내용
```sql
-- V2__add_phone_not_null.sql
ALTER TABLE User ADD COLUMN phone VARCHAR(20) NOT NULL DEFAULT '000-0000-0000';
```

#### 롤백 시나리오

**상황**: v2.0 배포 후 전화번호 검증 로직에 버그 발견

```bash
# 1단계: Blue로 트래픽 전환
$ ./scripts/switch_to_blue.sh

# ⚠️ 문제: Blue(v1.0)은 phone 컬럼에 값을 넣지 않음
# → INSERT 시도 시 NOT NULL 제약조건 위반
```

**해결책**:

```sql
-- Option 1: NOT NULL 제약조건 제거 (임시 조치)
ALTER TABLE User MODIFY COLUMN phone VARCHAR(20) DEFAULT NULL;

-- Option 2: 트리거로 기본값 자동 설정
DELIMITER $$
CREATE TRIGGER user_phone_default
BEFORE INSERT ON User
FOR EACH ROW
BEGIN
    IF NEW.phone IS NULL THEN
        SET NEW.phone = '000-0000-0000';
    END IF;
END$$
DELIMITER ;
```

**결과**:
- 🟡 조건부 롤백 가능
- ✅ 기존 데이터 보존
- ⚠️ v1.0에서 새로 생성된 User는 기본값 '000-0000-0000' 사용

**교훈**: NOT NULL 컬럼은 반드시 **2단계 배포** 필요
1. Phase 1: NULL 허용으로 추가 → 데이터 입력
2. Phase 2: NOT NULL 제약조건 추가

---

### 6. 컬럼 이름 변경 (Expand Phase - Phase 1)

#### 변경 내용
```sql
-- V2__expand_add_full_name.sql
ALTER TABLE User ADD COLUMN full_name VARCHAR(255);
UPDATE User SET full_name = name WHERE full_name IS NULL;

-- 양방향 동기화 트리거
CREATE TRIGGER user_name_sync_update
BEFORE UPDATE ON User FOR EACH ROW
BEGIN
    IF NEW.full_name != OLD.full_name THEN SET NEW.name = NEW.full_name; END IF;
    IF NEW.name != OLD.name THEN SET NEW.full_name = NEW.name; END IF;
END$$
```

#### 롤백 시나리오

**상황**: v2.0 배포 후 full_name 관련 버그 발견

```bash
# 트래픽을 Blue(v1.0)로 전환
$ ./scripts/switch_to_blue.sh

# 확인: v1.0은 name 컬럼만 사용, full_name 무시
$ curl -X POST http://localhost/users -d '{"name":"Jane Doe"}'
{"id":1,"name":"Jane Doe"}  # v1.0 응답

# Green(v2.0)에서 확인
$ docker exec app_green curl http://localhost:8080/users/1
{"id":1,"name":"Jane Doe","fullName":"Jane Doe"}  # 트리거로 동기화됨 ✓
```

**결과**:
- ✅ 완전한 롤백 가능
- ✅ 데이터 손실 없음 (트리거가 양방향 동기화)
- ✅ v1.0과 v2.0 모두 정상 작동

**이유**: Expand Phase는 하위 호환성을 유지하도록 설계됨

---

## 위험한 변경 (롤백 불가/어려움)

### 7. 컬럼 이름 변경 (Contract Phase - Phase 2)

#### 변경 내용
```sql
-- V3__contract_drop_name.sql
DROP TRIGGER IF EXISTS user_name_sync_update;
ALTER TABLE User DROP COLUMN name;  -- 이전 컬럼 삭제
```

#### 롤백 시나리오

**상황**: v3.0 배포 후 심각한 버그 발견, v1.0으로 롤백 필요

```bash
# ❌ 문제: v1.0은 name 컬럼을 필수로 사용
# → name 컬럼이 없으므로 v1.0 실행 불가

$ ./scripts/switch_to_blue.sh
# Blue 컨테이너 시작 시도...
ERROR: Column 'name' not found in table 'User'
```

**긴급 복구 절차**:

```sql
-- 1단계: 컬럼 재생성 (데이터 복사)
ALTER TABLE User ADD COLUMN name VARCHAR(255);
UPDATE User SET name = full_name;

-- 2단계: 트리거 재설정
CREATE TRIGGER user_name_sync_update
BEFORE UPDATE ON User FOR EACH ROW
BEGIN
    IF NEW.full_name != OLD.full_name THEN SET NEW.name = NEW.full_name; END IF;
    IF NEW.name != OLD.name THEN SET NEW.full_name = NEW.name; END IF;
END$$

-- 3단계: Blue 재시작
docker restart app_blue
```

**결과**:
- 🔴 즉시 롤백 불가능
- ⏱️ 복구 시간: 10~30분 (데이터 양에 따라)
- ⚠️ 서비스 다운타임 발생 가능
- ✅ 데이터 손실은 없음 (full_name에 데이터 보존됨)

**예방책**: Contract Phase는 **최소 1~2주 검증 후** 진행

---

### 8. 컬럼 삭제

#### 변경 내용
```sql
-- V2__drop_deprecated_field.sql
ALTER TABLE User DROP COLUMN deprecated_field;
```

#### 롤백 시나리오

**상황**: v2.0 배포 후 deprecated_field가 실제로는 필요했다는 것을 발견

```bash
# ❌ 치명적 문제: 컬럼 데이터 완전 손실
```

**복구 방법**:

```sql
-- Option 1: 백업에서 복원 (데이터 손실 최소화)
# 1. 최근 백업 확인
$ docker exec mysql_blue mysql -e "SHOW BINARY LOGS;"

# 2. 특정 시점으로 복원 (Point-in-Time Recovery)
$ mysqlbinlog --start-datetime="2025-10-01 10:00:00" \
              --stop-datetime="2025-10-01 10:30:00" \
              mysql-bin.000123 | mysql -u root -p

-- Option 2: 컬럼 재생성 + 기본값 설정 (데이터 손실 감수)
ALTER TABLE User ADD COLUMN deprecated_field VARCHAR(255) DEFAULT 'UNKNOWN';
```

**결과**:
- 🔴 롤백 거의 불가능
- 💔 **데이터 영구 손실**
- ⏱️ 복구 시간: 1~2시간 (백업 복원)
- ⚠️ 백업 시점 이후 데이터는 손실

**교훈**: 컬럼 삭제는 **최소 4주 이상 Deprecated 상태 유지 후** 진행

---

### 9. 컬럼 타입 변경

#### 변경 내용
```sql
-- V2__change_age_type.sql
ALTER TABLE User MODIFY COLUMN age INT;  -- VARCHAR(3) → INT
```

#### 롤백 시나리오

**상황**: INT 변환 후 데이터 손실 발견 ('25세' → 25 변환 시 '세' 손실)

```bash
# ❌ 문제: 타입 변환은 비가역적
# '25세' → 25 (INT) → '25' (VARCHAR) - '세' 복구 불가
```

**복구 방법**:

```sql
-- Option 1: 백업에서 복원
# 1. 최근 풀 백업 + 바이너리 로그로 복원
$ mysqlbackup --backup-dir=/backup/2025-10-01 --apply-log
$ mysqlbackup --backup-dir=/backup/2025-10-01 --copy-back

-- Option 2: 타입만 되돌리기 (데이터 손실 감수)
ALTER TABLE User MODIFY COLUMN age VARCHAR(10);
-- 결과: '25'로 변환됨 ('세'는 이미 손실)
```

**결과**:
- 🔴 완전한 롤백 불가능
- 💔 데이터 변환 손실 (형식 정보 손실)
- ⏱️ 복구 시간: 1~3시간

**올바른 방법**: Expand-Contract 패턴 사용

```sql
-- Phase 1: 새 컬럼 추가
ALTER TABLE User ADD COLUMN age_int INT;
UPDATE User SET age_int = CAST(REGEXP_REPLACE(age_string, '[^0-9]', '') AS UNSIGNED);

-- Phase 2 (1~2주 후): 이전 컬럼 삭제
ALTER TABLE User DROP COLUMN age_string;
ALTER TABLE User CHANGE COLUMN age_int age INT;
```

---

### 10. 테이블 삭제

#### 변경 내용
```sql
-- V2__drop_old_table.sql
DROP TABLE legacy_users;
```

#### 롤백 시나리오

**상황**: legacy_users 테이블이 실제로는 배치 작업에서 사용 중이었음

```bash
# ❌ 치명적 문제: 테이블 전체 데이터 손실
```

**복구 방법**:

```sql
-- 유일한 방법: 풀 백업 복원
# 1. 서비스 중단
$ docker stop app_blue app_green

# 2. 데이터베이스 복원
$ docker exec -i mysql_blue mysql -u root -p < /backup/full_backup_2025-10-01.sql

# 3. 바이너리 로그로 최신 상태까지 재생
$ mysqlbinlog mysql-bin.000123 mysql-bin.000124 | mysql -u root -p

# 4. 서비스 재시작
$ docker start app_blue
```

**결과**:
- 🔴 롤백 거의 불가능
- 💔 **전체 테이블 데이터 손실**
- ⏱️ 복구 시간: 2~4시간 (데이터 양에 따라)
- ⚠️ **서비스 완전 중단 필요**

**예방책**:
1. 테이블 삭제 전 최소 **2개월 Deprecated** 상태 유지
2. 삭제 전 전체 데이터 덤프 백업 생성
3. 의존성 완전 제거 확인 (외래키, 배치 작업, 레거시 스크립트)

---

## 롤백 전략별 체크리스트

### 🟢 즉시 롤백 (1~5분)

**적용 가능 변경**:
- ✅ 컬럼 추가 (NULL/기본값)
- ✅ 테이블 추가
- ✅ 인덱스 추가
- ✅ Expand Phase 변경

**롤백 절차**:
```bash
□ Blue 환경 헬스체크 확인
□ 트래픽 Blue로 전환 (./scripts/switch_to_blue.sh)
□ Green 환경 로그 확인
□ 데이터 정합성 검증
□ (선택) 스키마 원복
```

**예상 다운타임**: 0초 (무중단)

---

### 🟡 조건부 롤백 (10~30분)

**적용 가능 변경**:
- ⚠️ NOT NULL 컬럼 추가
- ⚠️ 인덱스 삭제 (대용량 테이블)
- ⚠️ Expand Phase 후 일부 데이터 입력됨

**롤백 절차**:
```bash
□ 현재 데이터 스냅샷 생성
□ Blue로 트래픽 전환
□ 제약조건 완화 (NOT NULL → NULL)
□ 인덱스 재생성 (필요 시)
□ 데이터 검증 스크립트 실행
□ 모니터링 강화 (1시간)
```

**예상 다운타임**: 0~5분 (제약조건 수정 시)

---

### 🔴 긴급 복구 (1~4시간)

**적용 가능 변경**:
- ❌ Contract Phase 변경
- ❌ 컬럼 삭제
- ❌ 테이블 삭제
- ❌ 컬럼 타입 변경

**롤백 절차**:
```bash
□ 즉시 서비스 중단 공지
□ 현재 상태 풀 덤프 백업
□ 최근 백업 파일 확인 (백업 시점 확인)
□ 데이터베이스 복원 시작
□ 바이너리 로그로 Point-in-Time Recovery
□ 데이터 정합성 검증 (샘플링)
□ Blue 환경 재시작
□ 모니터링 및 로그 분석 (24시간)
□ 인시던트 보고서 작성
```

**예상 다운타임**: 30분 ~ 4시간

**복구 불가능 케이스**:
- 백업이 없는 경우
- 바이너리 로그가 비활성화된 경우
- 백업 시점이 너무 오래된 경우 (1주일 이상)

---

## 🛡️ 롤백 위험 최소화 전략

### 1. 배포 전 준비

```bash
# 백업 생성 (배포 직전)
$ docker exec mysql_blue mysqldump -u root -p${MYSQL_ROOT_PASSWORD} \
  --all-databases --single-transaction --master-data=2 \
  > backup_before_v2_$(date +%Y%m%d_%H%M%S).sql

# 바이너리 로그 활성화 확인
$ docker exec mysql_blue mysql -e "SHOW VARIABLES LIKE 'log_bin';"
| log_bin | ON |

# 현재 바이너리 로그 위치 기록
$ docker exec mysql_blue mysql -e "SHOW MASTER STATUS;"
```

### 2. 배포 중 모니터링

```bash
# 실시간 에러 로그 모니터링
$ docker logs -f app_green | grep -i error

# 복제 상태 확인 (역방향 복제)
$ docker exec mysql_blue mysql -e "SHOW SLAVE STATUS\G" | grep -E "(Running|Behind)"

# 쿼리 성능 모니터링
$ docker exec mysql_green mysql -e "SHOW PROCESSLIST;"
```

### 3. 롤백 결정 기준

| 지표 | 정상 범위 | 경고 | 즉시 롤백 |
|-----|----------|------|----------|
| 에러율 | < 0.1% | 0.1~1% | > 1% |
| 응답 시간 | < 200ms | 200~500ms | > 500ms |
| DB 복제 지연 | < 1초 | 1~10초 | > 10초 |
| CPU 사용률 | < 70% | 70~90% | > 90% |
| 메모리 사용률 | < 80% | 80~95% | > 95% |

### 4. 롤백 후 검증

```bash
# 데이터 정합성 체크
SELECT COUNT(*) FROM User;  -- Blue와 Green 동일한지 확인

# 복제 상태 확인
SHOW SLAVE STATUS\G

# 애플리케이션 기능 테스트
$ ./scripts/test_deployment.sh

# 샘플 데이터 조회 (최근 1시간)
SELECT * FROM User WHERE created_at > NOW() - INTERVAL 1 HOUR LIMIT 10;
```

---

## 📊 실전 롤백 시나리오 요약

| 시나리오 | 롤백 가능 여부 | 복구 시간 | 데이터 손실 | 권장 조치 |
|---------|--------------|----------|-----------|----------|
| 새 컬럼 추가 후 버그 | ✅ 가능 | 1분 | 없음 | 트래픽 전환 |
| 새 테이블 추가 후 성능 저하 | ✅ 가능 | 1분 | 신규 테이블만 | 트래픽 전환 |
| Expand Phase 후 버그 | ✅ 가능 | 1분 | 없음 | 트래픽 전환 |
| NOT NULL 컬럼 추가 후 오류 | 🟡 조건부 | 10분 | 없음 | 제약조건 완화 |
| Contract Phase 후 버그 | 🔴 어려움 | 30분 | 없음 | 컬럼 재생성 |
| 컬럼 삭제 후 의존성 발견 | 🔴 불가능 | 2시간 | 높음 | 백업 복원 |
| 타입 변경 후 데이터 손상 | 🔴 불가능 | 2시간 | 높음 | 백업 복원 |
| 테이블 삭제 후 의존성 발견 | 🔴 불가능 | 4시간 | 매우 높음 | 풀 백업 복원 |

---

## 🎯 핵심 원칙

### DO ✅
1. **항상 배포 직전 백업 생성**
2. **Expand-Contract 패턴으로 2단계 배포**
3. **Phase 간 최소 1~2주 간격 유지**
4. **롤백 스크립트 사전 준비**
5. **카나리 배포 또는 Blue-Green으로 점진적 전환**

### DON'T ❌
1. **백업 없이 컬럼/테이블 삭제 금지**
2. **단일 배포로 Contract Phase 실행 금지**
3. **프로덕션에서 직접 타입 변경 금지**
4. **바이너리 로그 비활성화 금지**
5. **롤백 테스트 없이 프로덕션 배포 금지**

---

## 📞 긴급 상황 대응 플로우

```
배포 후 심각한 버그 발견
         ↓
    [5분 이내인가?]
    ↙ Yes      No ↘
트래픽 전환      백업 시점 확인
    ↓              ↓
  완료       [1시간 이내인가?]
           ↙ Yes      No ↘
    PITR 복구        풀 백업 복원
         ↓              ↓
    데이터 검증      데이터 검증
         ↓              ↓
    서비스 재개    인시던트 보고서
```

---

## 참고 자료

- [MySQL Point-in-Time Recovery](https://dev.mysql.com/doc/refman/8.0/en/point-in-time-recovery.html)
- [Blue-Green Deployment Rollback Strategies](https://martinfowler.com/bliki/BlueGreenDeployment.html)
- [Database Refactoring Best Practices](https://www.databaserefactoring.com/)
