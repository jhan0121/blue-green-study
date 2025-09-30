#!/bin/bash

set -e

MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-rootpass}
REPLICATION_USER=${REPLICATION_USER:-replication_user}
REPLICATION_PASSWORD=${REPLICATION_PASSWORD:-repl_password}

echo "Waiting for MySQL services to be ready..."

# MySQL 서비스 헬스체크
for i in {1..30}; do
    if docker exec mysql_blue mysqladmin ping -h localhost -u root -p${MYSQL_ROOT_PASSWORD} --silent; then
        echo "Blue MySQL is ready!"
        break
    fi
    echo "Waiting for Blue MySQL... ($i/30)"
    sleep 5
done

for i in {1..30}; do
    if docker exec mysql_green mysqladmin ping -h localhost -u root -p${MYSQL_ROOT_PASSWORD} --silent; then
        echo "Green MySQL is ready!"
        break
    fi
    echo "Waiting for Green MySQL... ($i/30)"
    sleep 5
done

# Master (Blue) 설정
echo "Configuring Blue (Master) environment..."

# 복제 사용자가 이미 존재하는지 확인
if ! docker exec mysql_blue mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "SELECT User FROM mysql.user WHERE User='${REPLICATION_USER}'" | grep -q "${REPLICATION_USER}"; then
    echo "Creating replication user..."
    docker exec mysql_blue mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "
    CREATE USER '${REPLICATION_USER}'@'%' IDENTIFIED WITH 'mysql_native_password' BY '${REPLICATION_PASSWORD}';
    GRANT REPLICATION SLAVE ON *.* TO '${REPLICATION_USER}'@'%';
    FLUSH PRIVILEGES;
    "
fi

# Master 상태 정보 가져오기
echo "Getting master status..."
MASTER_STATUS=$(docker exec mysql_blue mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "SHOW MASTER STATUS;" 2>/dev/null)

MASTER_FILE=$(echo "$MASTER_STATUS" | tail -n +2 | awk '{print $1}' | head -n 1)
MASTER_POS=$(echo "$MASTER_STATUS" | tail -n +2 | awk '{print $2}' | head -n 1)

echo "Master File: $MASTER_FILE, Position: $MASTER_POS"

if [ -z "$MASTER_FILE" ] || [ -z "$MASTER_POS" ]; then
    echo "Error: Could not get master status"
    exit 1
fi

# Slave (Green) 설정
echo "Configuring Green (Slave) environment..."

# 기존 복제 설정 정지
docker exec mysql_green mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "STOP SLAVE;" || true

docker exec mysql_green mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "
CHANGE MASTER TO
  MASTER_HOST='mysql_blue',
  MASTER_USER='${REPLICATION_USER}',
  MASTER_PASSWORD='${REPLICATION_PASSWORD}',
  MASTER_LOG_FILE='${MASTER_FILE}',
  MASTER_LOG_POS=${MASTER_POS};
START SLAVE;
"

# 복제 상태 확인
echo "Checking slave status..."
sleep 5
docker exec mysql_green mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "SHOW SLAVE STATUS\G" | grep -E "(Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master)"

echo "Replication setup completed!"
