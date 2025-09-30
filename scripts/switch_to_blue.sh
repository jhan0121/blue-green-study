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

# Nginx 업스트림 변경
echo "Updating Nginx configuration..."
docker exec nginx_lb cp /etc/nginx/nginx-blue.conf /etc/nginx/nginx.conf
docker exec nginx_lb nginx -s reload

echo "Traffic switched to Blue environment!"

# 검증
sleep 3
RESPONSE=$(curl -s http://localhost:3030/health)
echo "Health check response: $RESPONSE"
if echo "$RESPONSE" | grep -iq blue; then
    echo "✅ Switch to Blue successful!"

    # Green 환경 정리
    echo "Stopping Green environment..."
    docker-compose stop app_green mysql_green
else
    echo "❌ Switch failed! Rolling back..."
    docker exec nginx_lb cp /etc/nginx/nginx-green.conf /etc/nginx/nginx.conf
    docker exec nginx_lb nginx -s reload
    exit 1
fi
