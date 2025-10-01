#!/bin/bash

set -e

MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-rootpass}

echo "Switching to Green environment..."

# Green 환경이 실행 중인지 확인
if ! docker ps | grep -q "app_green"; then
    echo "Starting Green environment..."
    docker-compose --profile green up -d app_green mysql_green

    # Green MySQL read-only 해제
    sleep 5
    docker exec mysql_green mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "SET GLOBAL read_only = OFF; SET GLOBAL super_read_only = OFF;" 2>/dev/null || true

    # 헬스체크 대기
    echo "Waiting for Green environment to be healthy..."
    for i in {1..30}; do
        if docker exec app_green curl -s -f http://localhost:8080/health > /dev/null 2>&1; then
            echo "Green environment is healthy!"
            break
        fi
        echo "Attempt $i/30: Waiting for Green environment..."
        sleep 10
    done
fi

# 복제 지연 확인
echo "Checking replication lag..."
lag=$(docker exec mysql_green mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Seconds_Behind_Master" | awk '{print $2}' || echo "NULL")

if [ "$lag" != "0" ] && [ "$lag" != "NULL" ] && [ -n "$lag" ]; then
    echo "Waiting for replication sync (lag: ${lag}s)..."
    sleep $((lag + 5))
fi

# Green을 Master로 승격하고 역방향 복제 설정
echo "Setting up reverse replication (Green → Blue)..."

# 1. Green에서 복제 중지 및 쓰기 활성화
docker exec mysql_green mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "
STOP SLAVE;
SET GLOBAL read_only = OFF;
SET GLOBAL super_read_only = OFF;
" 2>/dev/null || true

# 2. Green의 Master 상태 가져오기
GREEN_STATUS=$(docker exec mysql_green mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "SHOW MASTER STATUS;" 2>/dev/null)
GREEN_FILE=$(echo "$GREEN_STATUS" | tail -n +2 | awk '{print $1}' | head -n 1)
GREEN_POS=$(echo "$GREEN_STATUS" | tail -n +2 | awk '{print $2}' | head -n 1)

echo "Green Master Status - File: $GREEN_FILE, Position: $GREEN_POS"

# 3. Blue를 Green의 Slave로 설정 (역방향 복제)
if [ -n "$GREEN_FILE" ] && [ -n "$GREEN_POS" ]; then
    echo "Setting up Blue as slave of Green..."
    docker exec mysql_blue mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "
    STOP SLAVE;
    RESET SLAVE ALL;
    CHANGE MASTER TO
      MASTER_HOST='mysql_green',
      MASTER_USER='replication_user',
      MASTER_PASSWORD='repl_password',
      MASTER_LOG_FILE='${GREEN_FILE}',
      MASTER_LOG_POS=${GREEN_POS};
    START SLAVE;
    SET GLOBAL read_only = ON;
    SET GLOBAL super_read_only = ON;
    " 2>/dev/null || echo "⚠️ Reverse replication setup failed"

    # 복제 상태 확인
    sleep 2
    REPL_CHECK=$(docker exec mysql_blue mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Slave_IO_Running" | awk '{print $2}' || echo "No")
    if [ "$REPL_CHECK" = "Yes" ]; then
        echo "✅ Reverse replication successfully established"
    else
        echo "⚠️ Reverse replication may have issues, check manually"
    fi
fi

# Nginx 업스트림 변경
echo "Updating Nginx configuration..."
docker exec nginx_lb sh -c "cat /etc/nginx/upstream-green.conf > /etc/nginx/upstream.conf"
docker exec nginx_lb nginx -s reload

echo "Traffic switched to Green environment!"

# 검증
sleep 3
RESPONSE=$(curl -s http://localhost:3030/health)
echo "Health check response: $RESPONSE"
if echo "$RESPONSE" | grep -iq green; then
    echo "✅ Switch to Green successful!"

    # Blue 환경 유지 (역방향 복제를 위해)
    echo "ℹ️  Blue environment kept running for reverse replication"
    echo "ℹ️  Blue MySQL is now replicating from Green"

    # 복제 상태 확인
    echo "Checking reverse replication status..."
    docker exec mysql_blue mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep -E "(Slave_IO_Running|Slave_SQL_Running)" || true
else
    echo "❌ Switch failed! Rolling back..."
    docker exec nginx_lb sh -c "cat /etc/nginx/upstream-blue.conf > /etc/nginx/upstream.conf"
    docker exec nginx_lb nginx -s reload
    exit 1
fi
