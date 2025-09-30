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
    docker exec mysql_green mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "SET GLOBAL read_only = OFF; SET GLOBAL super_read_only = OFF;" 2>/dev/null || true

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
lag=$(docker exec mysql_green mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "SHOW SLAVE STATUS\G" | grep "Seconds_Behind_Master" | awk '{print $2}' || echo "NULL")

if [ "$lag" != "0" ] && [ "$lag" != "NULL" ] && [ -n "$lag" ]; then
    echo "Waiting for replication sync (lag: ${lag}s)..."
    sleep $((lag + 5))
fi

# Nginx 업스트림 변경
echo "Updating Nginx configuration..."
docker cp nginx/upstream-green.conf nginx_lb:/etc/nginx/upstream.conf
docker exec nginx_lb nginx -s reload

echo "Traffic switched to Green environment!"

# 검증
sleep 3
RESPONSE=$(curl -s http://localhost:3030/health)
echo "Health check response: $RESPONSE"
if echo "$RESPONSE" | grep -iq green; then
    echo "✅ Switch to Green successful!"

    # Blue 환경 정리 (선택사항)
    echo "Stopping Blue environment..."
    docker-compose stop app_blue mysql_blue
else
    echo "❌ Switch failed! Rolling back..."
    docker cp nginx/upstream-blue.conf nginx_lb:/etc/nginx/upstream.conf
    docker exec nginx_lb nginx -s reload
    exit 1
fi
