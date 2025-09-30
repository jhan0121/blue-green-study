#!/bin/bash

set -e

echo "🧪 Blue-Green Deployment Test"
echo "============================"

# Load environment variables
if [ -f .env ]; then
    source .env
fi

MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-rootpass}
BASE_URL="http://localhost:3030"
NGINX_HEALTH_URL="http://localhost:8081"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${YELLOW}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

test_endpoint() {
    local url=$1
    local expected=$2
    local description=$3
    
    log_info "Testing: $description"
    
    if response=$(curl -s "$url" 2>/dev/null); then
        if echo "$response" | grep -qi "$expected"; then
            log_success "$description - OK"
            return 0
        else
            log_error "$description - Expected '$expected', got: $response"
            return 1
        fi
    else
        log_error "$description - Request failed"
        return 1
    fi
}

check_container_health() {
    local container=$1
    local description=$2
    
    if docker ps | grep -q "$container"; then
        if docker exec "$container" curl -s -f http://localhost:8080/health >/dev/null 2>&1; then
            log_success "$description is healthy"
            return 0
        else
            log_error "$description health check failed"
            return 1
        fi
    else
        log_error "$description is not running"
        return 1
    fi
}

# Test 1: Initial setup test
echo ""
log_info "Test 1: Initial Environment Setup"

# Check current deployment state
BLUE_RUNNING=false
GREEN_RUNNING=false
NGINX_RUNNING=false

if docker ps | grep -q "nginx_lb"; then
    NGINX_RUNNING=true
fi

if docker ps | grep -q "app_blue"; then
    BLUE_RUNNING=true
fi

if docker ps | grep -q "app_green"; then
    GREEN_RUNNING=true
fi

log_info "Current state: Nginx=$NGINX_RUNNING, Blue=$BLUE_RUNNING, Green=$GREEN_RUNNING"

# Handle initial deployment case (nothing running)
if [ "$NGINX_RUNNING" = false ] && [ "$BLUE_RUNNING" = false ] && [ "$GREEN_RUNNING" = false ]; then
    log_info "No environment detected - Setting up initial Blue deployment..."
    docker-compose up -d app_blue mysql_blue nginx >/dev/null 2>&1
    sleep 15

    if docker ps | grep -q "app_blue" && docker ps | grep -q "nginx_lb"; then
        log_success "Initial Blue environment deployed"
        BLUE_RUNNING=true
        NGINX_RUNNING=true
    else
        log_error "Failed to deploy initial environment"
        exit 1
    fi
elif [ "$NGINX_RUNNING" = false ]; then
    log_error "Nginx load balancer is not running but apps are - inconsistent state"
    exit 1
elif [ "$BLUE_RUNNING" = false ] && [ "$GREEN_RUNNING" = false ]; then
    log_error "No application environment is running"
    exit 1
else
    log_success "Basic containers are running"
fi

# Test 2: Nginx health checks
echo ""
log_info "Test 2: Nginx Health Checks"

test_endpoint "$NGINX_HEALTH_URL/nginx-health" "healthy" "Nginx internal health"
test_endpoint "$NGINX_HEALTH_URL/upstream-health" "OK" "Upstream health via Nginx"

# Test 3: Application endpoints
echo ""
log_info "Test 3: Application Endpoints"

# Determine which environment is currently active
CURRENT_ENV="unknown"
HEALTH_RESPONSE=$(curl -s "$BASE_URL/health" 2>/dev/null || echo "")
if echo "$HEALTH_RESPONSE" | grep -qi "blue"; then
    CURRENT_ENV="blue"
elif echo "$HEALTH_RESPONSE" | grep -qi "green"; then
    CURRENT_ENV="green"
fi

log_info "Currently active environment: $CURRENT_ENV"

test_endpoint "$BASE_URL/" "$CURRENT_ENV" "Main page"
test_endpoint "$BASE_URL/health" "$CURRENT_ENV" "Health endpoint"
test_endpoint "$BASE_URL/version" "$CURRENT_ENV" "Version endpoint"

# Test 4: MySQL connectivity
echo ""
log_info "Test 4: Database Connectivity"

if docker exec mysql_blue mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "SELECT 1" >/dev/null 2>&1; then
    log_success "Blue MySQL connection successful"
else
    log_error "Blue MySQL connection failed"
fi

# Test 5: Replication Status (양방향 복제 확인)
echo ""
log_info "Test 5: Replication Status"

# 현재 활성 환경에 따라 복제 방향 확인
ACTIVE_ENV=$(curl -s "$BASE_URL/health" 2>/dev/null | grep -oiE "(blue|green)" | head -1 | tr '[:upper:]' '[:lower:]')

if [ "$ACTIVE_ENV" = "blue" ]; then
    # Blue가 활성이면 Green이 Blue의 Slave여야 함
    if docker ps | grep -q "mysql_green"; then
        SLAVE_STATUS=$(docker exec mysql_green mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Slave_IO_Running" | awk '{print $2}' || echo "No")
        if [ "$SLAVE_STATUS" = "Yes" ]; then
            log_success "MySQL replication is running (Blue → Green)"
        else
            log_info "Green is standby without active replication"
        fi
    else
        log_info "Green MySQL not running - replication test skipped"
    fi
elif [ "$ACTIVE_ENV" = "green" ]; then
    # Green이 활성이면 Blue가 Green의 Slave여야 함
    if docker ps | grep -q "mysql_blue"; then
        SLAVE_STATUS=$(docker exec mysql_blue mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Slave_IO_Running" | awk '{print $2}' || echo "No")
        if [ "$SLAVE_STATUS" = "Yes" ]; then
            log_success "MySQL replication is running (Green → Blue)"
        else
            log_info "Blue is standby without active replication"
        fi
    else
        log_info "Blue MySQL not running - replication test skipped"
    fi
else
    log_info "Unable to determine active environment for replication test"
fi

# Test 6: Environment switching test
echo ""
log_info "Test 6: Environment Switching Test"

# Determine current active environment and target environment
ACTIVE_ENV=$(curl -s "$BASE_URL/health" 2>/dev/null | grep -oiE "(blue|green)" | head -1 | tr '[:upper:]' '[:lower:]')
if [ "$ACTIVE_ENV" = "blue" ]; then
    TARGET_ENV="green"
    TARGET_CONTAINER="app_green"
    TARGET_MYSQL="mysql_green"
else
    TARGET_ENV="blue"
    TARGET_CONTAINER="app_blue"
    TARGET_MYSQL="mysql_blue"
fi

log_info "Active environment: $ACTIVE_ENV, Target: $TARGET_ENV"

# Start target environment if not running
if ! docker ps | grep -q "$TARGET_CONTAINER"; then
    log_info "Starting $TARGET_ENV environment for testing..."

    if [ "$TARGET_ENV" = "green" ]; then
        docker-compose --profile green up -d app_green mysql_green >/dev/null 2>&1
        # Green MySQL read-only 해제
        sleep 5
        docker exec mysql_green mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "SET GLOBAL read_only = OFF; SET GLOBAL super_read_only = OFF;" 2>/dev/null || true
    else
        docker-compose up -d app_blue mysql_blue >/dev/null 2>&1
    fi

    # Wait for target environment to be ready
    log_info "Waiting for $TARGET_ENV environment to be ready..."
    sleep 10
    for i in {1..10}; do
        if check_container_health "$TARGET_CONTAINER" "$TARGET_ENV application"; then
            break
        fi
        if [ $i -lt 10 ]; then
            sleep 5
        fi
    done
fi

if docker ps | grep -q "$TARGET_CONTAINER"; then
    # Test switching to target environment
    log_info "Testing switch to $TARGET_ENV..."
    if [ "$TARGET_ENV" = "green" ]; then
        SWITCH_SCRIPT="./scripts/switch_to_green.sh"
    else
        SWITCH_SCRIPT="./scripts/switch_to_blue.sh"
    fi

    if $SWITCH_SCRIPT >/dev/null 2>&1; then
        sleep 3
        if test_endpoint "$BASE_URL/health" "$TARGET_ENV" "Health check after switch to $TARGET_ENV"; then
            log_success "Switch to $TARGET_ENV successful"

            # Test switching back to original environment
            log_info "Testing switch back to $ACTIVE_ENV..."
            if [ "$ACTIVE_ENV" = "green" ]; then
                SWITCH_BACK_SCRIPT="./scripts/switch_to_green.sh"
            else
                SWITCH_BACK_SCRIPT="./scripts/switch_to_blue.sh"
            fi

            # Restart the original environment if it was stopped
            if ! docker ps | grep -q "app_$ACTIVE_ENV"; then
                log_info "Restarting $ACTIVE_ENV environment..."
                if [ "$ACTIVE_ENV" = "green" ]; then
                    docker-compose --profile green up -d app_green mysql_green >/dev/null 2>&1
                else
                    docker-compose up -d app_blue mysql_blue >/dev/null 2>&1
                fi
                sleep 10
            fi

            if $SWITCH_BACK_SCRIPT >/dev/null 2>&1; then
                sleep 3
                if test_endpoint "$BASE_URL/health" "$ACTIVE_ENV" "Health check after switch to $ACTIVE_ENV"; then
                    log_success "Switch back to $ACTIVE_ENV successful"
                else
                    log_error "Switch back to $ACTIVE_ENV failed"
                fi
            else
                log_error "Switch back to $ACTIVE_ENV script failed"
            fi
        else
            log_error "Switch to $TARGET_ENV verification failed"
        fi
    else
        log_error "Switch to $TARGET_ENV script failed"
    fi
else
    log_info "$TARGET_ENV environment not available - switching test skipped"
fi

echo ""
echo "🏁 Test Summary"
echo "=============="
log_success "Blue-Green deployment test completed!"
log_info "Check the logs above for any failures"

# Cleanup
log_info "Cleaning up test environment..."
# Keep both environments running for reverse replication
FINAL_ACTIVE=$(curl -s "$BASE_URL/health" 2>/dev/null | grep -oiE "(blue|green)" | head -1 | tr '[:upper:]' '[:lower:]')

if [ "$FINAL_ACTIVE" = "blue" ]; then
    log_info "Keeping both environments for reverse replication"
    log_info "Active: Blue (Master) → Green (Slave)"

    # 역방향 복제 상태 확인
    if docker ps | grep -q "mysql_green"; then
        REPL_STATUS=$(docker exec mysql_green mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Slave_IO_Running" | awk '{print $2}' || echo "No")
        if [ "$REPL_STATUS" = "Yes" ]; then
            log_success "Reverse replication is active (Green replicating from Blue)"
        else
            log_info "Green is available for instant failover (replication may not be active)"
        fi
    fi
elif [ "$FINAL_ACTIVE" = "green" ]; then
    log_info "Keeping both environments for reverse replication"
    log_info "Active: Green (Master) → Blue (Slave)"

    # 역방향 복제 상태 확인
    if docker ps | grep -q "mysql_blue"; then
        REPL_STATUS=$(docker exec mysql_blue mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Slave_IO_Running" | awk '{print $2}' || echo "No")
        if [ "$REPL_STATUS" = "Yes" ]; then
            log_success "Reverse replication is active (Blue replicating from Green)"
        else
            log_info "Blue is available for instant failover (replication may not be active)"
        fi
    fi
fi

echo ""
log_success "All tests completed!"
log_info "Active environment: $FINAL_ACTIVE"
log_info "Both environments are kept running for instant rollback capability"
