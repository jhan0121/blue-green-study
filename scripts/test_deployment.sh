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

if ! docker ps | grep -q "nginx_lb"; then
    log_error "Nginx load balancer is not running"
    exit 1
fi

if ! docker ps | grep -q "app_blue"; then
    log_error "Blue application is not running"
    exit 1
fi

log_success "Basic containers are running"

# Test 2: Nginx health checks
echo ""
log_info "Test 2: Nginx Health Checks"

test_endpoint "$NGINX_HEALTH_URL/nginx-health" "healthy" "Nginx internal health"
test_endpoint "$NGINX_HEALTH_URL/upstream-health" "OK" "Upstream health via Nginx"

# Test 3: Application endpoints
echo ""
log_info "Test 3: Application Endpoints"

test_endpoint "$BASE_URL/" "blue\|Blue" "Main page (should be Blue)"
test_endpoint "$BASE_URL/health" "blue\|Blue" "Health endpoint"
test_endpoint "$BASE_URL/version" "blue\|Blue" "Version endpoint"

# Test 4: MySQL connectivity
echo ""
log_info "Test 4: Database Connectivity"

if docker exec mysql_blue mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "SELECT 1" >/dev/null 2>&1; then
    log_success "Blue MySQL connection successful"
else
    log_error "Blue MySQL connection failed"
fi

# Test 5: Replication setup (if Green is running)
echo ""
log_info "Test 5: Replication Status"

if docker ps | grep -q "mysql_green"; then
    SLAVE_STATUS=$(docker exec mysql_green mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Slave_IO_Running" | awk '{print $2}' || echo "No")
    
    if [ "$SLAVE_STATUS" = "Yes" ]; then
        log_success "MySQL replication is running"
    else
        log_error "MySQL replication is not running properly"
    fi
else
    log_info "Green MySQL not running - replication test skipped"
fi

# Test 6: Environment switching test
echo ""
log_info "Test 6: Environment Switching Test"

# Start Green environment if not running
if ! docker ps | grep -q "app_green"; then
    log_info "Starting Green environment for testing..."
    docker-compose --profile green up -d app_green mysql_green >/dev/null 2>&1

    # Green MySQL read-only 해제
    sleep 5
    docker exec mysql_green mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "SET GLOBAL read_only = OFF; SET GLOBAL super_read_only = OFF;" 2>/dev/null || true

    # Wait for Green to be ready
    for i in {1..10}; do
        if check_container_health "app_green" "Green application"; then
            break
        fi
        sleep 3
    done
fi

if docker ps | grep -q "app_green"; then
    # Test switching to Green
    log_info "Testing switch to Green..."
    if ./scripts/switch_to_green.sh >/dev/null 2>&1; then
        sleep 3
        if test_endpoint "$BASE_URL/health" "green\|Green" "Health check after switch to Green"; then
            log_success "Switch to Green successful"
            
            # Test switching back to Blue
            log_info "Testing switch back to Blue..."
            if ./scripts/switch_to_blue.sh >/dev/null 2>&1; then
                sleep 3
                if test_endpoint "$BASE_URL/health" "blue\|Blue" "Health check after switch to Blue"; then
                    log_success "Switch back to Blue successful"
                else
                    log_error "Switch back to Blue failed"
                fi
            else
                log_error "Switch back to Blue script failed"
            fi
        else
            log_error "Switch to Green verification failed"
        fi
    else
        log_error "Switch to Green script failed"
    fi
else
    log_info "Green environment not available - switching test skipped"
fi

echo ""
echo "🏁 Test Summary"
echo "=============="
log_success "Blue-Green deployment test completed!"
log_info "Check the logs above for any failures"

# Cleanup
log_info "Cleaning up test environment..."
docker-compose stop app_green mysql_green >/dev/null 2>&1 || true

echo ""
log_success "All tests completed!"
