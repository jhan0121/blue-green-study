#!/bin/bash

set -e

ENVIRONMENT=$1
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-rootpass}

if [ -z "$ENVIRONMENT" ]; then
    echo "Usage: $0 [blue|green]"
    exit 1
fi

if [ "$ENVIRONMENT" = "green" ]; then
    echo "Switching to Green environment..."

    # 1. Green 환경이 실행 중인지 확인
    if ! docker ps | grep -q "app_green"; then
        echo "Starting Green environment..."
        docker-compose up -d app_green mysql_green

        # 헬스체크 대기
        for i in {1..30}; do
            if docker exec app_green curl -s -f http://localhost:8080/health > /dev/null 2>&1; then
                echo "Green environment is healthy!"
                break
            fi
            echo "Waiting for Green environment... ($i/30)"
            sleep 10
        done
    fi

    # 2. Green의 복제 상태 확인
    SLAVE_STATUS=$(docker exec mysql_green mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "SHOW SLAVE STATUS\G" | grep "Seconds_Behind_Master" | awk '{print $2}' || echo "NULL")

    if [ "$SLAVE_STATUS" != "0" ] && [ "$SLAVE_STATUS" != "NULL" ]; then
        echo "Warning: Green environment is $SLAVE_STATUS seconds behind!"
        echo "Waiting for synchronization..."
        sleep $((SLAVE_STATUS + 5))
    fi

    # 3. Blue를 읽기 전용으로 전환 (쓰기 트래픽 중지)
    docker exec mysql_blue mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "SET GLOBAL read_only = ON;"

    # 4. Green에서 복제 중지 및 쓰기 가능으로 전환
    docker exec mysql_green mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "STOP SLAVE; SET GLOBAL read_only = OFF;"

    # 5. Nginx 설정 변경
    docker exec nginx_lb sed -i 's/server app_blue:8080/server app_green:8080/g' /etc/nginx/nginx.conf
    docker exec nginx_lb nginx -s reload

    echo "Traffic switched to Green environment!"

    # 6. 검증
    sleep 3
    if curl -s http://localhost:3030/health | grep -i green; then
        echo "✅ Switch to Green successful!"

        # Blue 환경 정리 (선택사항)
        echo "Stopping Blue environment..."
        docker-compose stop app_blue
    else
        echo "❌ Switch failed! Health check did not return Green"
        exit 1
    fi

elif [ "$ENVIRONMENT" = "blue" ]; then
    echo "Switching back to Blue environment..."

    # 1. Blue 환경이 실행 중인지 확인
    if ! docker ps | grep -q "app_blue"; then
        echo "Starting Blue environment..."
        docker-compose up -d app_blue mysql_blue

        # 헬스체크 대기
        for i in {1..30}; do
            if docker exec app_blue curl -s -f http://localhost:8080/health > /dev/null 2>&1; then
                echo "Blue environment is healthy!"
                break
            fi
            echo "Waiting for Blue environment... ($i/30)"
            sleep 10
        done
    fi

    # 2. 역방향 전환 로직
    docker exec mysql_green mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "SET GLOBAL read_only = ON;"
    docker exec mysql_blue mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "SET GLOBAL read_only = OFF;"

    # 3. Nginx 설정 변경
    docker exec nginx_lb sed -i 's/server app_green:8080/server app_blue:8080/g' /etc/nginx/nginx.conf
    docker exec nginx_lb nginx -s reload

    echo "Traffic switched to Blue environment!"

    # 4. 검증
    sleep 3
    if curl -s http://localhost:3030/health | grep -i blue; then
        echo "✅ Switch to Blue successful!"

        # Green 환경 정리
        echo "Stopping Green environment..."
        docker-compose stop app_green
    else
        echo "❌ Switch failed! Health check did not return Blue"
        exit 1
    fi

else
    echo "Invalid environment: $ENVIRONMENT"
    echo "Usage: $0 [blue|green]"
    exit 1
fi
