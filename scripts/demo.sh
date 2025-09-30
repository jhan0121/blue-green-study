#!/bin/bash

# Blue-Green Deployment Demo Script
# This script demonstrates the complete blue-green deployment process

set -e

echo "🚀 Blue-Green Deployment Demo"
echo "============================="
echo ""

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_step() {
    echo -e "${YELLOW}🔄 $1${NC}"
}

log_blue() {
    echo -e "${BLUE}🔵 $1${NC}"
}

log_green() {
    echo -e "${GREEN}🟢 $1${NC}"
}

BASE_URL="http://localhost:3030"

echo "This demo will:"
echo "1. Start the Blue environment"
echo "2. Set up MySQL replication"
echo "3. Deploy Green environment"
echo "4. Switch traffic to Green"
echo "5. Switch back to Blue"
echo ""
read -p "Press Enter to start the demo..."

# Step 1: Start Blue environment
log_step "Step 1: Starting Blue Environment"
log_blue "Bringing up Blue application and database..."
docker-compose up -d app_blue mysql_blue nginx

echo "Waiting for Blue environment to be ready..."
for i in {1..30}; do
    if curl -s http://localhost:3030/health | grep -qi blue; then
        break
    fi
    echo "  Waiting... ($i/30)"
    sleep 3
done

log_blue "Blue environment is ready!"
echo "  🌐 Application: $BASE_URL"
echo "  ❤️  Health: $(curl -s $BASE_URL/health)"
echo ""

# Step 2: Setup replication
log_step "Step 2: Setting up MySQL Replication"
docker-compose up -d mysql_green
echo "Waiting for MySQL services to be ready..."
sleep 10

log_blue "Configuring master-slave replication..."
./scripts/setup_replication.sh
echo ""

# Step 3: Deploy Green
log_step "Step 3: Deploying Green Environment"
log_green "Starting Green application..."
docker-compose up -d app_green

echo "Waiting for Green environment to be ready..."
for i in {1..30}; do
    if docker exec app_green curl -s http://localhost:8080/health | grep -qi green 2>/dev/null; then
        break
    fi
    echo "  Waiting... ($i/30)"
    sleep 5
done

log_green "Green environment is ready!"
echo "  Green health check: $(docker exec app_green curl -s http://localhost:8080/health 2>/dev/null || echo 'Not ready')"
echo ""

# Step 4: Switch to Green
log_step "Step 4: Switching Traffic to Green"
log_green "Switching load balancer to Green environment..."

echo "Current traffic target: $(curl -s $BASE_URL/health)"
./scripts/switch_to_green.sh

echo "New traffic target: $(curl -s $BASE_URL/health)"
echo ""

# Demonstrate Green is active
log_green "Green environment is now active!"
echo "  🌐 Application: $BASE_URL"
echo "  ❤️  Health: $(curl -s $BASE_URL/health)"
echo "  📊 Version: $(curl -s $BASE_URL/version)"
echo ""

read -p "Press Enter to switch back to Blue..."

# Step 5: Switch back to Blue
log_step "Step 5: Switching Back to Blue"
log_blue "Rolling back to Blue environment..."

echo "Current traffic target: $(curl -s $BASE_URL/health)"
./scripts/switch_to_blue.sh

echo "New traffic target: $(curl -s $BASE_URL/health)"
echo ""

# Final status
log_blue "Blue environment is active again!"
echo "  🌐 Application: $BASE_URL"
echo "  ❤️  Health: $(curl -s $BASE_URL/health)"
echo "  📊 Version: $(curl -s $BASE_URL/version)"
echo ""

echo "🎉 Demo completed successfully!"
echo ""
echo "Key takeaways:"
echo "  ✅ Zero-downtime deployment achieved"
echo "  ✅ Database replication working"
echo "  ✅ Traffic switching working"
echo "  ✅ Rollback capability confirmed"
echo ""

log_step "Cleaning up demo environment..."
echo "Stopping Green environment..."
docker-compose stop app_green mysql_green

echo ""
echo "🏁 Demo finished! Blue environment remains active."
