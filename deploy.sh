#!/bin/sh
# POSIX-compliant deploy.sh
# Automates Dockerized app deployment with NGINX reverse proxy

# ========== CONFIGURATION ==========
LOGFILE="deploy_$(date +%Y%m%d).log"

# ========== LOGGING & ERROR HANDLING ==========
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | INFO | $1" | tee -a "$LOGFILE"
}

error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | ERROR | $1" | tee -a "$LOGFILE" >&2
    exit 1
}

cleanup() {
    log "Cleaning up temporary files..."
    rm -rf "$TMPDIR" 2>/dev/null
}
trap cleanup EXIT

# ========== VALIDATION HELPERS ==========
require_command() {
    command -v "$1" >/dev/null 2>&1 || error "Missing required command: $1"
}

# ========== 1. USER INPUT ==========
echo "Enter Git Repository URL:"
read REPO_URL || error "Repository URL required."

echo "Enter your Personal Access Token (PAT):"
read PAT || error "PAT required."

echo "Enter branch name (default: main):"
read BRANCH
if [ -z "$BRANCH" ]; then
    BRANCH="main"
fi

echo "Enter remote server SSH username:"
read SSH_USER || error "SSH username required."

echo "Enter remote server IP address:"
read SERVER_IP || error "Server IP required."

echo "Enter SSH key path (absolute path):"
read SSH_KEY || error "SSH key path required."

echo "Enter application internal port (e.g., 5000):"
read APP_PORT || error "App port required."

# Validate tools
for cmd in git ssh scp docker; do
    require_command "$cmd"
done

# ========== 2. CLONE OR UPDATE REPO ==========
TMPDIR=$(mktemp -d)
cd "$TMPDIR" || exit 1

AUTH_URL=$(echo "$REPO_URL" | sed "s#https://#https://$PAT@#")
log "Cloning repository..."
if ! git clone -b "$BRANCH" "$AUTH_URL" app 2>>"$LOGFILE"; then
    error "Failed to clone repository."
fi

cd app || error "Failed to enter repo directory."

# Verify Docker file existence
if [ -f "docker-compose.yml" ]; then
    log "Found docker-compose.yml"
elif [ -f "Dockerfile" ]; then
    log "Found Dockerfile"
else
    error "No Dockerfile or docker-compose.yml found."
fi

# ========== 3. REMOTE CONNECTION VALIDATION ==========
log "Checking SSH connectivity..."
ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$SERVER_IP" "echo 'SSH OK'" \
    || error "SSH connection failed."

# ========== 4. PREPARE REMOTE ENVIRONMENT ==========
log "Installing Docker, Docker Compose, and NGINX remotely..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
sudo yum update -y
sudo yum install -y docker nginx git
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker \$USER
sudo systemctl enable nginx
sudo systemctl start nginx
EOF

# ========== 5. DEPLOY APPLICATION ==========
log "Transferring files to remote server..."
scp -i "$SSH_KEY" -r "$TMPDIR/app" "$SSH_USER@$SERVER_IP:/home/$SSH_USER/app" || error "File transfer failed."

log "Building and running Docker container remotely..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
cd /home/$SSH_USER/app
if [ -f docker-compose.yml ]; then
  sudo docker-compose down || true
  sudo docker-compose up -d --build
else
  sudo docker build -t hngapp .
  sudo docker stop hngapp || true
  sudo docker rm hngapp || true
  sudo docker run -d -p $APP_PORT:$APP_PORT --name hngapp hngapp
fi
EOF

# ========== 6. CONFIGURE NGINX REVERSE PROXY ==========
log "Configuring NGINX as reverse proxy..."
NGINX_CONF="/etc/nginx/conf.d/hngapp.conf"

ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
sudo tee /etc/nginx/conf.d/hngapp.conf > /dev/null <<CONFIG
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
CONFIG
sudo nginx -t && sudo systemctl reload nginx
EOF

# ========== 7. VALIDATION ==========
log "Validating deployment..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
sudo systemctl status docker | grep active || echo 'Docker inactive'
sudo systemctl status nginx | grep active || echo 'Nginx inactive'
curl -I http://localhost || echo 'App may not be reachable locally.'
EOF

# ========== 8. SUCCESS ==========
log "Deployment completed successfully! Visit: http://$SERVER_IP"

exit 0
