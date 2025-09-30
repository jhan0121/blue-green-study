# 스키마 마이그레이션 가이드

## 📋 Blue-Green 배포에서 안전한 스키마 변경

### 원칙

1. **하위 호환성 유지**: 구 버전이 신 스키마에서 작동 가능
2. **확장-축소 패턴 사용**: 2단계 배포
3. **롤백 가능성 확보**: 언제든 이전 버전으로 복귀

---

## 🟢 안전한 변경 (단일 배포 가능)

### ✅ 컬럼 추가 (NULL 허용 또는 기본값)

```sql
-- V2__add_email.sql
ALTER TABLE User
ADD COLUMN email VARCHAR(255) DEFAULT NULL;

-- 또는
ALTER TABLE User
ADD COLUMN status VARCHAR(20) DEFAULT 'ACTIVE';
```

**배포 전략:**
- Green 배포 시 자동 마이그레이션
- Blue는 새 컬럼 무시 (하위 호환)
- 롤백 가능

### ✅ 테이블 추가

```sql
-- V2__add_orders.sql
CREATE TABLE orders (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

### ✅ 인덱스 추가/삭제

```sql
-- V2__add_index.sql
CREATE INDEX idx_user_email ON User(email);

-- 또는
DROP INDEX idx_old_field ON User;
```

---

## 🟡 주의 필요 (확장-축소 패턴 사용)

### ⚠️ 컬럼 이름 변경

#### Phase 1: 확장 (v2.0)
```sql
-- V2__add_full_name.sql
ALTER TABLE User ADD COLUMN full_name VARCHAR(255);

-- 데이터 복사 트리거
DELIMITER $$
CREATE TRIGGER user_name_sync_insert
BEFORE INSERT ON User
FOR EACH ROW
BEGIN
    IF NEW.full_name IS NULL THEN
        SET NEW.full_name = NEW.name;
    END IF;
    IF NEW.name IS NULL THEN
        SET NEW.name = NEW.full_name;
    END IF;
END$$

CREATE TRIGGER user_name_sync_update
BEFORE UPDATE ON User
FOR EACH ROW
BEGIN
    IF NEW.full_name != OLD.full_name THEN
        SET NEW.name = NEW.full_name;
    END IF;
    IF NEW.name != OLD.name THEN
        SET NEW.full_name = NEW.name;
    END IF;
END$$
DELIMITER ;

-- 기존 데이터 마이그레이션
UPDATE User SET full_name = name WHERE full_name IS NULL;
```

```java
// v2.0 애플리케이션 코드
@Entity
public class User {
    @Column(name = "name")
    private String name;

    @Column(name = "full_name")
    private String fullName;

    // Getter에서 fallback 처리
    public String getFullName() {
        return fullName != null ? fullName : name;
    }

    // Setter에서 동기화
    public void setFullName(String fullName) {
        this.fullName = fullName;
        this.name = fullName;  // 하위 호환
    }
}
```

#### Phase 2: 축소 (v3.0 - 다음 배포)
```sql
-- V3__drop_name.sql
DROP TRIGGER IF EXISTS user_name_sync_insert;
DROP TRIGGER IF EXISTS user_name_sync_update;
ALTER TABLE User DROP COLUMN name;
```

```java
// v3.0 애플리케이션 코드
@Entity
public class User {
    @Column(name = "full_name")
    private String fullName;  // name 제거
}
```

### ⚠️ NOT NULL 컬럼 추가

#### Phase 1: NULL 허용으로 추가
```sql
-- V2__add_phone.sql
ALTER TABLE User ADD COLUMN phone VARCHAR(20) DEFAULT NULL;

-- 기본값 설정
UPDATE User SET phone = '000-0000-0000' WHERE phone IS NULL;
```

#### Phase 2: NOT NULL 제약조건 추가
```sql
-- V3__phone_not_null.sql
ALTER TABLE User MODIFY COLUMN phone VARCHAR(20) NOT NULL;
```

---

## 🔴 위험한 변경 (절대 단일 배포 금지)

### ❌ 컬럼 삭제

**올바른 방법:**

#### Phase 1: 사용 중단 (v2.0)
```java
@Column(name = "deprecated_field")
@Deprecated
private String deprecatedField;  // 읽기만 허용, 쓰기 금지
```

#### Phase 2: 완전 제거 (v3.0)
```sql
-- V3__drop_deprecated.sql
ALTER TABLE User DROP COLUMN deprecated_field;
```

### ❌ 컬럼 타입 변경

**올바른 방법:**

#### Phase 1: 새 컬럼 추가
```sql
-- V2__add_age_int.sql
ALTER TABLE User ADD COLUMN age_int INT;
UPDATE User SET age_int = CAST(age_string AS UNSIGNED);
```

#### Phase 2: 이전 컬럼 삭제
```sql
-- V3__drop_age_string.sql
ALTER TABLE User DROP COLUMN age_string;
ALTER TABLE User CHANGE COLUMN age_int age INT;
```

---

## 🎯 배포 체크리스트

### 배포 전 확인사항

```bash
□ 스키마 변경이 하위 호환 가능한가?
□ 구 버전이 신 스키마에서 작동하는가?
□ 롤백 시나리오를 테스트했는가?
□ 데이터 마이그레이션 시간을 측정했는가?
□ 복제 지연을 고려했는가?
```

### 배포 중 모니터링

```bash
□ Blue 환경 에러 로그 확인
□ MySQL 복제 상태 확인 (Seconds_Behind_Master)
□ 애플리케이션 헬스체크 통과
```

### 배포 후 검증

```bash
□ 양쪽 환경에서 CRUD 테스트
□ 데이터 정합성 확인
□ 롤백 테스트 수행
```

---

## 🔧 Flyway 설정 권장사항

```yaml
spring:
  flyway:
    enabled: true
    baseline-on-migrate: true
    validate-on-migrate: true  # 활성화 권장
    out-of-order: false
    ignore-missing-migrations: false
    baseline-version: 1
    locations: classpath:db/migration
```

---

## 📊 마이그레이션 시간 예측

| 데이터 양 | 컬럼 추가 | 인덱스 생성 | 데이터 복사 |
|----------|---------|-----------|-----------|
| 100만 건 | ~1초 | ~10초 | ~30초 |
| 1000만 건 | ~5초 | ~2분 | ~5분 |
| 1억 건 | ~30초 | ~20분 | ~30분 |

**대용량 마이그레이션:**
- Online DDL 사용 (MySQL 5.6+)
- 배치 처리 (1000건씩)
- 유지보수 시간대 배포

---

## 🚨 롤백 시나리오

### 시나리오 1: 배포 직후 문제 발견

```bash
# 트래픽 전환 전
1. Green 중지
2. Blue 유지
3. 스키마 롤백 SQL 실행
```

### 시나리오 2: 트래픽 전환 후 문제 발견

```bash
# 호환 가능한 스키마인 경우
1. Blue로 트래픽 전환
2. Green 재배포 or 수정

# 호환 불가능한 스키마인 경우
1. 긴급 패치 배포 (Hot Fix)
2. 스키마 롤백 SQL 준비 필수
```

---

## 📚 참고 자료

- [Expand-Contract Pattern](https://martinfowler.com/bliki/ParallelChange.html)
- [MySQL Online DDL](https://dev.mysql.com/doc/refman/8.0/en/innate-online-ddl.html)
- [Flyway Documentation](https://flywaydb.org/documentation/)
