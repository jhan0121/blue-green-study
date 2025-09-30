# Expand-Contract 패턴 실전 예제

## 시나리오: `name` → `full_name` 컬럼 이름 변경

### 📅 타임라인

```
Week 1 (v2.0): Expand - 새 컬럼 추가
Week 2 (v2.0): 데이터 마이그레이션 & 검증
Week 3 (v3.0): Contract - 이전 컬럼 삭제
```

---

## Phase 1: Expand (v2.0 배포)

### Step 1: Flyway 마이그레이션

```sql
-- V2__expand_add_full_name.sql
-- Add new column with sync triggers

-- 1. 새 컬럼 추가
ALTER TABLE User ADD COLUMN full_name VARCHAR(255) DEFAULT NULL;

-- 2. 기존 데이터 복사
UPDATE User SET full_name = name WHERE full_name IS NULL;

-- 3. 양방향 동기화 트리거
DELIMITER $$

CREATE TRIGGER user_name_sync_insert
BEFORE INSERT ON User
FOR EACH ROW
BEGIN
    IF NEW.full_name IS NULL AND NEW.name IS NOT NULL THEN
        SET NEW.full_name = NEW.name;
    END IF;
    IF NEW.name IS NULL AND NEW.full_name IS NOT NULL THEN
        SET NEW.name = NEW.full_name;
    END IF;
END$$

CREATE TRIGGER user_name_sync_update
BEFORE UPDATE ON User
FOR EACH ROW
BEGIN
    -- full_name이 변경되면 name도 업데이트
    IF NEW.full_name != OLD.full_name OR (NEW.full_name IS NOT NULL AND OLD.full_name IS NULL) THEN
        SET NEW.name = NEW.full_name;
    END IF;
    -- name이 변경되면 full_name도 업데이트
    IF NEW.name != OLD.name OR (NEW.name IS NOT NULL AND OLD.name IS NULL) THEN
        SET NEW.full_name = NEW.name;
    END IF;
END$$

DELIMITER ;

-- 4. 인덱스 복사
CREATE INDEX idx_user_full_name ON User(full_name);
```

### Step 2: 애플리케이션 코드 (v2.0)

```java
@Entity
@Table(name = "User")
public class User {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    // 이전 필드 (하위 호환용)
    @Column(name = "name")
    private String name;

    // 새 필드
    @Column(name = "full_name")
    private String fullName;

    // Getter: 새 필드 우선, 없으면 이전 필드 사용
    public String getFullName() {
        return fullName != null ? fullName : name;
    }

    // Setter: 양쪽 모두 업데이트 (트리거와 중복이지만 안전장치)
    public void setFullName(String fullName) {
        this.fullName = fullName;
        this.name = fullName;  // 하위 호환
    }

    public void setName(String name) {
        this.name = name;
        this.fullName = name;  // 상위 호환
    }

    @Deprecated
    public String getName() {
        return name;
    }
}
```

### Step 3: 배포 검증

```bash
# v1.0 (Blue) 테스트
$ curl http://blue:8080/users/1
{"id":1,"name":"John Doe"}  # 이전 API, 정상 작동

# v2.0 (Green) 테스트
$ curl http://green:8080/users/1
{"id":1,"name":"John Doe","fullName":"John Doe"}  # 양쪽 모두 반환

# v1.0에서 데이터 생성
$ curl -X POST http://blue:8080/users -d '{"name":"Jane Smith"}'
{"id":2,"name":"Jane Smith"}

# v2.0에서 확인
$ curl http://green:8080/users/2
{"id":2,"name":"Jane Smith","fullName":"Jane Smith"}  # 트리거로 동기화됨 ✓
```

---

## Phase 2: Contract (v3.0 배포 - 1~2주 후)

### Step 1: Flyway 마이그레이션

```sql
-- V3__contract_drop_name.sql
-- Remove old column after all services use full_name

-- 1. 트리거 제거
DROP TRIGGER IF EXISTS user_name_sync_insert;
DROP TRIGGER IF EXISTS user_name_sync_update;

-- 2. 이전 컬럼 삭제
ALTER TABLE User DROP COLUMN name;

-- 3. 이전 인덱스 제거 (있다면)
DROP INDEX IF EXISTS idx_user_name ON User;
```

### Step 2: 애플리케이션 코드 (v3.0)

```java
@Entity
@Table(name = "User")
public class User {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    // name 필드 완전 제거
    @Column(name = "full_name")
    private String fullName;

    public String getFullName() {
        return fullName;
    }

    public void setFullName(String fullName) {
        this.fullName = fullName;
    }
}
```

---

## 🔍 각 단계별 시스템 상태

### Phase 1 배포 중

```
Before:
Blue v1.0 (활성) → DB [name]

After Green Deploy:
Blue v1.0 (활성) → DB [name, full_name] ✓ 정상 (name만 사용)
Green v2.0 (대기)→ DB [name, full_name] ✓ 정상 (양쪽 사용)

After Traffic Switch:
Blue v1.0 (대기) → DB [name, full_name] ✓ 정상 (트리거로 동기화)
Green v2.0 (활성)→ DB [name, full_name] ✓ 정상

Rollback 가능: ✅ Blue로 즉시 전환 가능
```

### Phase 2 배포 중

```
Before:
Green v2.0 (활성) → DB [name, full_name]
Blue v1.0 (대기)  → DB [name, full_name]

After Green v3.0 Deploy:
Green v3.0 (대기) → DB [full_name] ✓ 정상
Blue v1.0 (활성) → DB [full_name] ❌ name 컬럼 없음

⚠️ 주의: Blue v1.0 사용 불가
→ Blue도 v2.0 이상으로 업그레이드 필요
→ 또는 v3.0만 유지
```

---

## ⚠️ 주의사항

### 1. Phase 1과 Phase 2 사이 충분한 간격 필요

```
이유:
- 모든 서비스가 v2.0 이상으로 업그레이드되었는지 확인
- 롤백 시나리오 대비
- 데이터 정합성 검증

권장 간격: 1~2주
```

### 2. 트리거 성능 영향

```sql
-- 대용량 테이블의 경우 트리거 대신 애플리케이션 레벨에서 동기화
-- 또는 배치 작업으로 주기적 동기화
```

### 3. Blue-Green 양쪽 버전 관리

```bash
Phase 1 기간:
- Blue: v1.0 (name만 사용)
- Green: v2.0 (name, full_name 병행)

Phase 2 기간:
- Blue: v2.0 (name, full_name 병행) ← 업그레이드 필수
- Green: v3.0 (full_name만 사용)
```

---

## 🧪 테스트 시나리오

### 테스트 1: 하위 호환성 (v1.0 → v2.0 스키마)

```bash
# v1.0 코드로 v2.0 DB 접근
1. SELECT * FROM User → name, full_name 모두 반환
2. v1.0은 full_name 무시 ✓
3. INSERT INTO User (name) → 트리거로 full_name 자동 설정 ✓
```

### 테스트 2: 데이터 동기화

```bash
# v2.0에서 full_name 업데이트
UPDATE User SET full_name = 'New Name' WHERE id = 1;

# v1.0에서 확인
SELECT name FROM User WHERE id = 1;
→ 'New Name' ✓ (트리거로 동기화됨)
```

### 테스트 3: 롤백

```bash
# Phase 1에서 Green → Blue 롤백
1. 트래픽 Blue로 전환
2. v1.0이 name 컬럼 사용 ✓
3. 데이터 손실 없음 ✓
```

---

## 📊 성능 영향 분석

### 트리거 오버헤드

```
Insert: +5~10% (트리거 실행)
Update: +5~10% (트리거 실행)
Select: 0% (영향 없음)

대용량 배치 작업:
- 트리거 일시 비활성화 고려
- 배치 후 수동 동기화
```

### 스토리지 증가

```
1개 컬럼 추가 (VARCHAR(255)):
- 1000만 건 × 255 bytes = ~2.5GB 추가
- 과도기 동안만 필요 (Phase 2 후 제거)
```

---

## 🎯 요약

### Phase 1 (Expand)
- ✅ 새 컬럼 추가 (이전 컬럼 유지)
- ✅ 트리거로 동기화
- ✅ 양쪽 버전 모두 작동
- ✅ 롤백 가능

### Phase 2 (Contract)
- ✅ 이전 컬럼 제거
- ⚠️ v1.0 사용 불가
- ✅ 스토리지 절약
- ⚠️ 롤백 어려움

### 핵심 원칙
1. **절대 단일 배포로 호환 불가능한 변경 금지**
2. **항상 2단계 배포 (Expand → Contract)**
3. **충분한 검증 기간 확보**
