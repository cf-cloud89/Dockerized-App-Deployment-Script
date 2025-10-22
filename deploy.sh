#!/bin/bash

#######################################
# Dockerized Application Deployment Script
# Description: Automates deployment of Dockerized apps to remote servers
#######################################

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/deploy_$(date +%Y%m%d_%H%M%S).log"
TEMP_DIR="${SCRIPT_DIR}/temp_deploy"
CLEANUP_MODE=false

#######################################
# Logging Functions
#######################################

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"
}

#######################################
# Error Handling
#######################################

cleanup_on_error() {
    log_error "Script encountered an error. Cleaning up..."
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
    exit 1
}

trap cleanup_on_error ERR
trap 'log_info "Script interrupted by user"; exit 130' INT TERM

#######################################
# Validation Functions
#######################################

validate_url() {
    local url=$1
    if [[ ! "$url" =~ ^https?://.*\.git$ ]] && [[ ! "$url" =~ ^git@.*:.+\.git$ ]]; then
        log_error "Invalid Git repository URL format"
        return 1
    fi
    return 0
}

validate_ip() {
    local ip=$1
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log_error "Invalid IP address format"
        return 1
    fi
    return 0
}

validate_port() {
    local port=$1
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        log_error "Invalid port number. Must be between 1-65535"
        return 1
    fi
    return 0
}

validate_ssh_key() {
    local key_path=$1
    if [ ! -f "$key_path" ]; then
        log_error "SSH key file not found: $key_path"
        return 1
    fi
    
    # Check key permissions
    local perms=$(stat -c %a "$key_path" 2>/dev/null || stat -f %A "$key_path" 2>/dev/null)
    if [ "$perms" != "600" ] && [ "$perms" != "400" ]; then
        log_warn "SSH key permissions are $perms. Fixing to 600..."
        chmod 600 "$key_path"
    fi
    return 0
}

#######################################
# User Input Collection
#######################################

collect_parameters() {
    log_info "=== Collecting Deployment Parameters ==="
    
    # Git Repository URL
    while true; do
        read -p "Enter Git Repository URL: " GIT_REPO_URL
        if validate_url "$GIT_REPO_URL"; then
            break
        fi
    done
    
    # Personal Access Token
    read -sp "Enter Personal Access Token (PAT): " GIT_PAT
    echo
    if [ -z "$GIT_PAT" ]; then
        log_error "PAT cannot be empty"
        exit 1
    fi
    
    # Branch name
    read -p "Enter branch name [main]: " GIT_BRANCH
    GIT_BRANCH=${GIT_BRANCH:-main}
    
    # SSH Username
    read -p "Enter SSH username: " SSH_USER
    if [ -z "$SSH_USER" ]; then
        log_error "SSH username cannot be empty"
        exit 1
    fi
    
    # Server IP
    while true; do
        read -p "Enter server IP address: " SERVER_IP
        if validate_ip "$SERVER_IP"; then
            break
        fi
    done
    
    # SSH Key Path
    while true; do
        read -p "Enter SSH key path [~/.ssh/id_rsa]: " SSH_KEY_PATH
        SSH_KEY_PATH=${SSH_KEY_PATH:-~/.ssh/id_rsa}
        SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
        if validate_ssh_key "$SSH_KEY_PATH"; then
            break
        fi
    done
    
    # Application Port
    while true; do
        read -p "Enter application port (container internal port): " APP_PORT
        if validate_port "$APP_PORT"; then
            break
        fi
    done
    
    log_success "Parameters collected successfully"
}

#######################################
# Repository Operations
#######################################

clone_or_update_repo() {
    log_info "=== Cloning/Updating Repository ==="
    
    mkdir -p "$TEMP_DIR"
    cd "$TEMP_DIR"
    
    # Extract repo name from URL and convert to lowercase, replace special chars
    REPO_NAME=$(basename "$GIT_REPO_URL" .git | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//')
    REPO_PATH="${TEMP_DIR}/${REPO_NAME}"
    
    # Prepare authenticated URL
    if [[ "$GIT_REPO_URL" =~ ^https:// ]]; then
        AUTH_URL=$(echo "$GIT_REPO_URL" | sed "s|https://|https://${GIT_PAT}@|")
    else
        AUTH_URL="$GIT_REPO_URL"
    fi
    
    if [ -d "$REPO_PATH" ]; then
        log_info "Repository exists. Pulling latest changes..."
        cd "$REPO_PATH"
        git fetch origin
        git checkout "$GIT_BRANCH"
        git pull origin "$GIT_BRANCH"
    else
        log_info "Cloning repository..."
        git clone -b "$GIT_BRANCH" "$AUTH_URL" "$REPO_NAME"
        cd "$REPO_PATH"
    fi
    
    log_success "Repository ready at: $REPO_PATH"
}

verify_docker_files() {
    log_info "=== Verifying Docker Configuration Files ==="
    
    cd "$REPO_PATH"
    
    if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
        log_success "Found docker-compose.yml"
        COMPOSE_FILE=true
        return 0
    elif [ -f "Dockerfile" ]; then
        log_success "Found Dockerfile"
        COMPOSE_FILE=false
        return 0
    else
        log_error "No Dockerfile or docker-compose.yml found in repository"
        exit 1
    fi
}

#######################################
# SSH Operations
#######################################

test_ssh_connection() {
    log_info "=== Testing SSH Connection ==="
    
    if ssh -i "$SSH_KEY_PATH" -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "${SSH_USER}@${SERVER_IP}" "echo 'SSH connection successful'" &>/dev/null; then
        log_success "SSH connection established"
        return 0
    else
        log_error "Failed to establish SSH connection"
        exit 1
    fi
}

execute_remote_command() {
    local cmd=$1
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" "$cmd"
}

#######################################
# Remote Environment Setup
#######################################

prepare_remote_environment() {
    log_info "=== Preparing Remote Environment ==="
    
    execute_remote_command "sudo dnf update -y" || {
        log_error "Failed to update packages"
        exit 1
    }
    
    log_info "Installing Docker..."
    execute_remote_command "
        if ! command -v docker &> /dev/null; then
            sudo dnf install -y dnf-transport-https ca-certificates curl software-properties-common
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
            echo 'deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable' | sudo tee /etc/dnf/sources.list.d/docker.list > /dev/null
            sudo dnf update -y
            sudo dnf install -y docker-ce docker-ce-cli containerd.io
        fi
    " || log_warn "Docker might already be installed"
    
    log_info "Installing Docker Compose..."
    execute_remote_command "
        if ! command -v docker-compose &> /dev/null; then
            sudo curl -L \"https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)\" -o /usr/local/bin/docker-compose
            sudo chmod +x /usr/local/bin/docker-compose
        fi
    " || log_warn "Docker Compose might already be installed"
    
    log_info "Installing Nginx..."
    execute_remote_command "
        if ! command -v nginx &> /dev/null; then
            sudo dnf install -y nginx
        fi
    " || log_warn "Nginx might already be installed"
    
    log_info "Configuring Docker permissions..."
    execute_remote_command "
        sudo usermod -aG docker ${SSH_USER} || true
        sudo systemctl enable docker
        sudo systemctl start docker
        sudo systemctl enable nginx
        sudo systemctl start nginx
    "
    
    # Verify installations
    log_info "Verifying installations..."
    local docker_version=$(execute_remote_command "docker --version")
    local compose_version=$(execute_remote_command "docker-compose --version")
    local nginx_version=$(execute_remote_command "nginx -v 2>&1")
    
    log_success "Docker: $docker_version"
    log_success "Docker Compose: $compose_version"
    log_success "Nginx: $nginx_version"
}

#######################################
# Application Deployment
#######################################

deploy_application() {
    log_info "=== Deploying Application ==="
    
    # Create remote directory
    REMOTE_APP_DIR="/home/${SSH_USER}/app/${REPO_NAME}"
    execute_remote_command "mkdir -p $REMOTE_APP_DIR"
    
    # Transfer files
    log_info "Transferring project files..."
    rsync -avz -e "ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no" \
        --exclude='.git' \
        --exclude='node_modules' \
        --exclude='*.log' \
        "${REPO_PATH}/" \
        "${SSH_USER}@${SERVER_IP}:${REMOTE_APP_DIR}/"
    
    log_success "Files transferred successfully"
    
    # Stop existing containers
    log_info "Stopping existing containers (if any)..."
    execute_remote_command "
        cd $REMOTE_APP_DIR
        if [ -f 'docker-compose.yml' ] || [ -f 'docker-compose.yaml' ]; then
            docker-compose down 2>/dev/null || true
        else
            docker stop ${REPO_NAME}_container 2>/dev/null || true
            docker rm ${REPO_NAME}_container 2>/dev/null || true
        fi
    " 2>/dev/null || log_info "No existing containers to stop"
    
    # Build and run
    if [ "$COMPOSE_FILE" = true ]; then
        log_info "Building and running with Docker Compose..."
        execute_remote_command "
            cd $REMOTE_APP_DIR
            docker-compose build
            docker-compose up -d
        "
    else
        log_info "Building and running with Docker..."
        # Ensure image and container names are Docker-compliant (lowercase, no special chars)
        IMAGE_NAME="${REPO_NAME}-image"
        CONTAINER_NAME="${REPO_NAME}-container"
        execute_remote_command "
            cd $REMOTE_APP_DIR
            docker build -t \${IMAGE_NAME} .
            docker run -d --name \${CONTAINER_NAME} -p ${APP_PORT}:${APP_PORT} \${IMAGE_NAME}
        "
    fi
    
    log_success "Application deployed successfully"
    
    # Wait for container to be healthy
    sleep 5
    
    # Verify container is running (search for repo name in any running container)
    local container_status=$(execute_remote_command "docker ps --filter name=${REPO_NAME} --format '{{.Status}}' | head -n1")
    if [ -n "$container_status" ]; then
        log_success "Container is running: $container_status"
    else
        log_error "Container failed to start"
        log_info "Checking container logs..."
        execute_remote_command "docker ps -a --filter name=${REPO_NAME} --format '{{.Names}}' | head -n1 | xargs -r docker logs --tail 50" || true
        exit 1
    fi
}

#######################################
# Nginx Configuration
#######################################

configure_nginx() {
    log_info "=== Configuring Nginx Reverse Proxy ==="
    
    local nginx_config="/etc/nginx/sites-available/${REPO_NAME}"
    
    execute_remote_command "
        sudo tee $nginx_config > /dev/null <<'EOF'
server {
    listen 80;
    server_name ${SERVER_IP} _;

    location / {
        proxy_pass http://localhost:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
    "
    
    # Enable site
    execute_remote_command "
        sudo ln -sf $nginx_config /etc/nginx/sites-enabled/${REPO_NAME}
        sudo rm -f /etc/nginx/sites-enabled/default
    "
    
    # Test configuration
    log_info "Testing Nginx configuration..."
    execute_remote_command "sudo nginx -t"
    
    # Reload Nginx
    execute_remote_command "sudo systemctl reload nginx"
    
    log_success "Nginx configured and reloaded successfully"
}

#######################################
# Deployment Validation
#######################################

validate_deployment() {
    log_info "=== Validating Deployment ==="
    
    # Check Docker service
    local docker_status=$(execute_remote_command "sudo systemctl is-active docker")
    if [ "$docker_status" = "active" ]; then
        log_success "Docker service is running"
    else
        log_error "Docker service is not running"
        exit 1
    fi
    
    # Check container health
    local container_count=$(execute_remote_command "docker ps --filter name=${REPO_NAME} | wc -l")
    if [ "$container_count" -gt 1 ]; then
        log_success "Container is running"
    else
        log_error "Container is not running"
        exit 1
    fi
    
    # Check Nginx
    local nginx_status=$(execute_remote_command "sudo systemctl is-active nginx")
    if [ "$nginx_status" = "active" ]; then
        log_success "Nginx is running"
    else
        log_error "Nginx is not running"
        exit 1
    fi
    
    # Test endpoint locally on server
    log_info "Testing application endpoint..."
    sleep 3
    
    local http_response=$(execute_remote_command "curl -s -o /dev/null -w '%{http_code}' http://localhost:${APP_PORT}/ || echo '000'")
    if [ "$http_response" = "200" ] || [ "$http_response" = "301" ] || [ "$http_response" = "302" ]; then
        log_success "Application is responding (HTTP $http_response)"
    else
        log_warn "Application returned HTTP $http_response"
    fi
    
    # Test through Nginx
    local nginx_response=$(execute_remote_command "curl -s -o /dev/null -w '%{http_code}' http://localhost/ || echo '000'")
    if [ "$nginx_response" = "200" ] || [ "$nginx_response" = "301" ] || [ "$nginx_response" = "302" ]; then
        log_success "Nginx proxy is working (HTTP $nginx_response)"
    else
        log_warn "Nginx returned HTTP $nginx_response"
    fi
    
    log_success "=== Deployment Validation Complete ==="
    log_info "Application URL: http://${SERVER_IP}"
    log_info "Direct application port: ${APP_PORT}"
}

#######################################
# Cleanup Functions
#######################################

cleanup_local() {
    log_info "Cleaning up local temporary files..."
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
    log_success "Local cleanup complete"
}

cleanup_remote() {
    log_info "=== Performing Remote Cleanup ==="
    
    execute_remote_command "
        cd /home/${SSH_USER}/app/${REPO_NAME} 2>/dev/null || exit 0
        if [ -f 'docker-compose.yml' ] || [ -f 'docker-compose.yaml' ]; then
            docker-compose down -v 2>/dev/null || true
        else
            # Stop and remove containers matching repo name
            docker ps -a --filter name=${REPO_NAME} --format '{{.Names}}' | xargs -r docker stop 2>/dev/null || true
            docker ps -a --filter name=${REPO_NAME} --format '{{.Names}}' | xargs -r docker rm 2>/dev/null || true
            # Remove images matching repo name
            docker images --filter reference='*${REPO_NAME}*' --format '{{.Repository}}:{{.Tag}}' | xargs -r docker rmi 2>/dev/null || true
        fi
        
        sudo rm -f /etc/nginx/sites-enabled/${REPO_NAME}
        sudo rm -f /etc/nginx/sites-available/${REPO_NAME}
        sudo systemctl reload nginx
        
        rm -rf /home/${SSH_USER}/app/${REPO_NAME}
    "
    
    log_success "Remote cleanup complete"
}

#######################################
# Main Function
#######################################

main() {
    echo "============================================"
    echo "  Dockerized Application Deployment Script"
    echo "============================================"
    echo ""
    
    log_info "Deployment started at $(date)"
    log_info "Log file: $LOG_FILE"
    
    # Check for cleanup flag
    if [ "${1:-}" = "--cleanup" ]; then
        CLEANUP_MODE=true
        collect_parameters
        cleanup_remote
        cleanup_local
        log_success "Cleanup completed successfully"
        exit 0
    fi
    
    # Main deployment flow
    collect_parameters
    clone_or_update_repo
    verify_docker_files
    test_ssh_connection
    prepare_remote_environment
    deploy_application
    configure_nginx
    validate_deployment
    cleanup_local
    
    log_success "=== DEPLOYMENT COMPLETED SUCCESSFULLY ==="
    log_info "Application is now live at: http://${SERVER_IP}"
    log_info "Deployment log saved to: $LOG_FILE"
    
    echo ""
    echo "============================================"
    echo "  Deployment Summary"
    echo "============================================"
    echo "Repository: $REPO_NAME"
    echo "Branch: $GIT_BRANCH"
    echo "Server: $SERVER_IP"
    echo "Application Port: $APP_PORT"
    echo "Access URL: http://${SERVER_IP}"
    echo "============================================"
}

# Run main function
main "$@"
