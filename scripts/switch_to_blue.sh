#!/bin/bash

set -e

echo "Switching to Blue environment..."

# Blue 환경 시작 (중지된 경우)
if ! docker ps | grep -q "app_blue"; then
    echo "Starting Blue environment..."
    docker-compose up -d app_blue mysql_blue

    # 헬스체크 대기
    for i in {1..30}; do
        if docker exec app_blue curl -s -f http://localhost:8080/health > /dev/null 2>&1; then
            echo "Blue environment is healthy!"
            break
        fi
        echo "Attempt $i/30: Waiting for Blue environment..."
        sleep 10
    done
fi

# Blue를 Master로 재승격하고 역방향 복제 설정
echo "Setting up reverse replication (Blue → Green)..."

# 1. Blue에서 복제 중지 및 쓰기 활성화
docker exec mysql_blue mysql -u root -prootpass -e "
STOP SLAVE;
SET GLOBAL read_only = OFF;
SET GLOBAL super_read_only = OFF;
" 2>/dev/null || true

# 2. Blue의 Master 상태 가져오기
BLUE_STATUS=$(docker exec mysql_blue mysql -u root -prootpass -e "SHOW MASTER STATUS;" 2>/dev/null)
BLUE_FILE=$(echo "$BLUE_STATUS" | tail -n +2 | awk '{print $1}' | head -n 1)
BLUE_POS=$(echo "$BLUE_STATUS" | tail -n +2 | awk '{print $2}' | head -n 1)

echo "Blue Master Status - File: $BLUE_FILE, Position: $BLUE_POS"

# 3. Green을 Blue의 Slave로 설정 (역방향 복제)
if [ -n "$BLUE_FILE" ] && [ -n "$BLUE_POS" ] && docker ps | grep -q "mysql_green"; then
    echo "Setting up Green as slave of Blue..."
    docker exec mysql_green mysql -u root -prootpass -e "
    STOP SLAVE;
    CHANGE MASTER TO
      MASTER_HOST='mysql_blue',
      MASTER_USER='replication_user',
      MASTER_PASSWORD='repl_password',
      MASTER_LOG_FILE='${BLUE_FILE}',
      MASTER_LOG_POS=${BLUE_POS};
    START SLAVE;
    SET GLOBAL read_only = ON;
    SET GLOBAL super_read_only = ON;
    " 2>/dev/null || echo "⚠️ Reverse replication setup failed"
fi

# Nginx 업스트림 변경
echo "Updating Nginx configuration..."
docker exec nginx_lb sh -c "cat /etc/nginx/upstream-blue.conf > /etc/nginx/upstream.conf"
docker exec nginx_lb nginx -s reload

echo "Traffic switched to Blue environment!"

# 검증
sleep 3
RESPONSE=$(curl -s http://localhost:3030/health)
echo "Health check response: $RESPONSE"
if echo "$RESPONSE" | grep -iq blue; then
    echo "✅ Switch to Blue successful!"

    # Green 환경 유지 (역방향 복제를 위해)
    if docker ps | grep -q "mysql_green"; then
        echo "ℹ️  Green environment kept running for reverse replication"
        echo "ℹ️  Green MySQL is now replicating from Blue"

        # 복제 상태 확인
        echo "Checking reverse replication status..."
        docker exec mysql_green mysql -u root -prootpass -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep -E "(Slave_IO_Running|Slave_SQL_Running)" || true
    fi
else
    echo "❌ Switch failed! Rolling back..."
    docker exec nginx_lb sh -c "cat /etc/nginx/upstream-green.conf > /etc/nginx/upstream.conf"
    docker exec nginx_lb nginx -s reload
    exit 1
fi
