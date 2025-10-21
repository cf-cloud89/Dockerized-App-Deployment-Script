#!/usr/bin/env bash
#
# deploy.sh - full deployment automation for Dockerized app + NGINX reverse proxy
# Follows the Task Breakdown provided by the user
#
# Usage:
#   ./deploy.sh           # interactive deploy
#   ./deploy.sh --dry-run # show actions but do not modify remote host
#   ./deploy.sh --cleanup # cleanup deployed resources on remote host
#
set -o errexit
set -o nounset
set -o pipefail

########################################
# Configuration & globals
########################################
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOGFILE="$(pwd)/deploy_${TIMESTAMP}.log"
DRY_RUN=0
CLEANUP=0

# default ssh options (do not change unless you know why)
SSH_DEFAULT_OPTS="-o BatchMode=yes -o ConnectTimeout=15"

########################################
# Helpers
########################################
log() { printf "%s | INFO  | %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOGFILE"; }
warn() { printf "%s | WARN  | %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOGFILE" >&2; }
err() { printf "%s | ERROR | %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOGFILE" >&2; }
die() { err "$*"; exit "${2:-1}"; }

mask_token() {
  local t="$1"
  [ -z "$t" ] && printf "%s" "" && return
  [ "${#t}" -le 8 ] && printf "****" && return
  printf "%s...%s" "${t:0:4}" "${t: -4}"
}

usage() {
  cat <<EOF
Usage: $0 [--dry-run] [--cleanup] [-h|--help]
  --dry-run   : Print actions, do not perform remote changes
  --cleanup   : Remove containers and nginx config from remote (requires same inputs)
  -h, --help   : Show this help
EOF
  exit 0
}

########################################
# Argument parsing
########################################
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --cleanup) CLEANUP=1; shift ;;
    -h|--help) usage ;;
    *) die "Unknown option: $1" ;;
  esac
done

########################################
# Trap / cleanup
########################################
on_exit() {
  local rc=$?
  if [ $rc -ne 0 ]; then
    err "Script failed with exit code $rc. See $LOGFILE"
  else
    log "Script finished (exit code 0). Log: $LOGFILE"
  fi
}
trap on_exit EXIT

########################################
# 1) Collect and validate inputs
########################################
collect_inputs() {
  log "Collecting inputs..."

  printf "Git Repository URL (HTTPS): "
  read -r GIT_URL
  [ -n "$GIT_URL" ] || die "Git repo URL is required." 10

  printf "Branch (default: main): "
  read -r GIT_BRANCH
  GIT_BRANCH=${GIT_BRANCH:-main}

  printf "Personal Access Token (PAT) (will be hidden): "
  stty -echo
  read -r GIT_PAT
  stty echo
  printf "\n"
  [ -n "$GIT_PAT" ] || die "Personal Access Token is required." 11

  printf "Remote SSH username (e.g. ec2-user, ubuntu): "
  read -r SSH_USER
  [ -n "$SSH_USER" ] || die "SSH username required." 12

  printf "Remote host (IP or hostname): "
  read -r REMOTE_HOST
  [ -n "$REMOTE_HOST" ] || die "Remote host required." 13

  printf "SSH private key path (absolute or ~ path): "
  read -r SSH_KEY
  [ -n "$SSH_KEY" ] || die "SSH key path required." 14
  # expand ~
  SSH_KEY="${SSH_KEY/#\~/$HOME}"
  [ -f "$SSH_KEY" ] || die "SSH private key not found at $SSH_KEY" 15

  printf "Internal container port (container listens on this port, e.g. 5000): "
  read -r APP_PORT
  printf '%s' "$APP_PORT" | grep -qE '^[0-9]+$' || die "Invalid app port." 16

  # log masked inputs
  log "Inputs: repo=$(printf '%.120s' "$GIT_URL"), branch=$GIT_BRANCH, PAT=$(mask_token "$GIT_PAT"), remote=${SSH_USER}@${REMOTE_HOST}, ssh_key=$SSH_KEY, app_port=$APP_PORT"
}

########################################
# 2) Local prechecks and clone/pull
########################################
prechecks_and_clone() {
  log "Running local prechecks..."
  for cmd in ssh rsync git curl; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd" 20
  done

  mkdir -p ./deploy_workspace
  cd ./deploy_workspace || die "Failed to cd to workspace" 21

  REPO_DIR="$(basename -s .git "$GIT_URL")"
  AUTH_URL="$(printf "%s" "$GIT_URL" | sed -e "s#https://#https://${GIT_PAT}@#")"

  if [ -d "$REPO_DIR/.git" ]; then
    log "Repository exists locally, fetching changes..."
    cd "$REPO_DIR" || die "cd repo failed" 22
    git fetch --all --prune >>"$LOGFILE" 2>&1 || die "git fetch failed" 23
    git checkout "$GIT_BRANCH" >>"$LOGFILE" 2>&1 || die "git checkout $GIT_BRANCH failed" 24
    git pull origin "$GIT_BRANCH" >>"$LOGFILE" 2>&1 || die "git pull failed" 25
  else
    log "Cloning repository branch '$GIT_BRANCH'..."
    git clone --branch "$GIT_BRANCH" --single-branch "$AUTH_URL" "$REPO_DIR" >>"$LOGFILE" 2>&1 || die "git clone failed" 26
    cd "$REPO_DIR" || die "cd repo failed" 27
  fi

  PROJECT_DIR="$(pwd)"
  log "Project directory: $PROJECT_DIR"

  if [ ! -f "Dockerfile" ] && [ ! -f "docker-compose.yml" ] && [ ! -f "docker-compose.yaml" ]; then
    die "No Dockerfile or docker-compose.yml found in project root ($PROJECT_DIR)" 28
  fi
  log "Found Dockerfile/docker-compose in project root."
}

########################################
# 3) SSH connectivity check
########################################
ssh_check() {
  log "Checking SSH connectivity to ${SSH_USER}@${REMOTE_HOST}..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would run: ssh -i $SSH_KEY $SSH_DEFAULT_OPTS $SSH_USER@$REMOTE_HOST 'echo OK'"
    return 0
  fi

  # attempt a harmless echo to check connectivity; use StrictHostKeyChecking=accept-new if supported else no
  ssh -i "$SSH_KEY" $SSH_DEFAULT_OPTS -o StrictHostKeyChecking=accept-new "${SSH_USER}@${REMOTE_HOST}" "echo SSH_OK" >/dev/null 2>&1 || \
    die "SSH connectivity failed to ${REMOTE_HOST}. Try connecting manually with: ssh -i $SSH_KEY ${SSH_USER}@${REMOTE_HOST}" 30

  log "SSH connectivity OK"
}

########################################
# 4) Remote preparation script
########################################
remote_prep() {
  log "Preparing remote environment..."

  remote_script="$(mktemp)"
  cat >"$remote_script" <<'REMOTE_EOF'
set -e
# detect package manager
if command -v apt-get >/dev/null 2>&1; then
  PKG_UPDATE="sudo apt-get update -y"
  PKG_INSTALL="sudo apt-get install -y"
elif command -v yum >/dev/null 2>&1; then
  PKG_UPDATE="sudo yum update -y"
  PKG_INSTALL="sudo yum install -y"
else
  echo "NO_SUPPORTED_PKG_MANAGER"
  exit 1
fi

# update packages
echo "UPDATING"
$PKG_UPDATE

# install prerequisites
$PKG_INSTALL curl ca-certificates openssl -y || true

# docker
if ! command -v docker >/dev/null 2>&1; then
  echo "Installing docker..."
  curl -fsSL https://get.docker.com | sh
fi
sudo systemctl enable --now docker || true

# docker-compose plugin/binary best-effort
if ! command -v docker-compose >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y docker-compose-plugin || true
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y docker-compose-plugin || true
  fi
fi

# nginx
if ! command -v nginx >/dev/null 2>&1; then
  echo "Installing nginx..."
  $PKG_INSTALL nginx -y || true
  sudo systemctl enable --now nginx || true
fi

# add current user to docker group if possible
if id -nG "$USER" 2>/dev/null | grep -qv docker; then
  sudo usermod -aG docker "$USER" || true
fi

# show versions
docker --version || true
docker-compose --version || true
nginx -v || true
echo "REMOTE_PREP_DONE"
REMOTE_EOF

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would upload and run remote prep script"
    rm -f "$remote_script"
    return 0
  fi

  scp -i "$SSH_KEY" -o BatchMode=yes "$remote_script" "${SSH_USER}@${REMOTE_HOST}:/tmp/remote_prep_${TIMESTAMP}.sh" >>"$LOGFILE" 2>&1 || die "Failed to upload remote prep script" 40
  ssh -i "$SSH_KEY" -o BatchMode=yes "${SSH_USER}@${REMOTE_HOST}" "bash /tmp/remote_prep_${TIMESTAMP}.sh" >>"$LOGFILE" 2>&1 || die "Remote preparation failed" 41
  ssh -i "$SSH_KEY" -o BatchMode=yes "${SSH_USER}@${REMOTE_HOST}" "rm -f /tmp/remote_prep_${TIMESTAMP}.sh" || true
  rm -f "$remote_script"
  log "Remote preparation completed"
}

########################################
# 5) Transfer project files (rsync)
########################################
transfer_files() {
  log "Transferring project files to remote..."
  REMOTE_BASE_DIR="~/deployments"
  # We'll use a timestamped folder to be idempotent
  REMOTE_PROJECT_DIR="${REMOTE_BASE_DIR}/$(basename "$PROJECT_DIR")_${TIMESTAMP}"
  RSYNC_EXCLUDES="--exclude .git --exclude node_modules --exclude __pycache__"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] rsync -e \"ssh -i $SSH_KEY -o BatchMode=yes\" $RSYNC_EXCLUDES -avz \"$PROJECT_DIR/\" ${SSH_USER}@${REMOTE_HOST}:$REMOTE_PROJECT_DIR/"
    return 0
  fi

  ssh -i "$SSH_KEY" -o BatchMode=yes "${SSH_USER}@${REMOTE_HOST}" "mkdir -p ${REMOTE_BASE_DIR}" >>"$LOGFILE" 2>&1 || die "Failed to create remote base dir" 50
  rsync -e "ssh -i $SSH_KEY -o BatchMode=yes" $RSYNC_EXCLUDES -avz "$PROJECT_DIR"/ "${SSH_USER}@${REMOTE_HOST}:${REMOTE_PROJECT_DIR}/" >>"$LOGFILE" 2>&1 || die "rsync failed" 51

  log "Files copied to remote: ${REMOTE_PROJECT_DIR}"
}

########################################
# 6) Deploy remotely: build/run containers, configure nginx
########################################
remote_deploy() {
  log "Deploying application on remote..."

  remote_deploy_script="$(mktemp)"
  cat >"$remote_deploy_script" <<'REMOTE_DEPLOY_EOF'
set -e
PROJECT_DIR="$1"
APP_PORT="$2"
NAME="$3"

cd "$PROJECT_DIR" || exit 10

# Stop and remove existing container if present
if docker ps -a --format '{{.Names}}' | grep -q "^$NAME$"; then
  docker rm -f "$NAME" || true
fi

# Kill any process listening on APP_PORT (best-effort) to avoid bind errors
if command -v ss >/dev/null 2>&1; then
  if ss -ltn "( sport = :$APP_PORT )" | grep -q LISTEN; then
    # attempt to find pid using fuser
    sudo fuser -k "${APP_PORT}/tcp" || true
  fi
elif command -v lsof >/dev/null 2>&1; then
  if lsof -i TCP:"$APP_PORT" | grep -q LISTEN; then
    sudo fuser -k "${APP_PORT}/tcp" || true
  fi
fi

# Build and run
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  # bring down any previous
  docker compose down --remove-orphans || docker-compose down --remove-orphans || true
  docker compose up -d --build || docker-compose up -d --build
else
  docker build -t "$NAME" . || exit 20
  docker run -d --name "$NAME" --restart unless-stopped -p 127.0.0.1:${APP_PORT}:${APP_PORT} "$NAME"
fi

# Create nginx config
NGINX_CONF="/etc/nginx/conf.d/${NAME}.conf"
cat <<'NGINX_EOF' | sudo tee ${NGINX_CONF} > /dev/null
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:APP_PORT_PLACEHOLDER;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }
}
NGINX_EOF

# replace placeholder with actual port (using sed)
sudo sed -i "s/APP_PORT_PLACEHOLDER/${APP_PORT}/g" ${NGINX_CONF}

# test and reload nginx
sudo nginx -t
sudo systemctl reload nginx || sudo systemctl restart nginx || true

# quick health check
curl -sS -o /dev/null -w "%{http_code}" "http://127.0.0.1:${APP_PORT}" || true
echo "DEPLOY_DONE"
REMOTE_DEPLOY_EOF

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would upload deploy script and run it on remote"
    rm -f "$remote_deploy_script"
    return 0
  fi

  scp -i "$SSH_KEY" -o BatchMode=yes "$remote_deploy_script" "${SSH_USER}@${REMOTE_HOST}:/tmp/remote_deploy_${TIMESTAMP}.sh" >>"$LOGFILE" 2>&1 || die "Failed to upload remote deploy script" 60
  ssh -i "$SSH_KEY" -o BatchMode=yes "${SSH_USER}@${REMOTE_HOST}" "bash /tmp/remote_deploy_${TIMESTAMP}.sh '${REMOTE_PROJECT_DIR}' '${APP_PORT}' '${APP_NAME}'" >>"$LOGFILE" 2>&1 || die "Remote deploy failed" 61
  ssh -i "$SSH_KEY" -o BatchMode=yes "${SSH_USER}@${REMOTE_HOST}" "rm -f /tmp/remote_deploy_${TIMESTAMP}.sh" || true
  rm -f "$remote_deploy_script"
  log "Remote deploy completed"
}

########################################
# 7) Validate deployment
########################################
validate() {
  log "Validating deployment..."

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] skipping remote validation"
    return 0
  fi

  # Docker service check
  ssh -i "$SSH_KEY" -o BatchMode=yes "${SSH_USER}@${REMOTE_HOST}" "sudo systemctl is-active --quiet docker" >>"$LOGFILE" 2>&1 || die "Docker service not active on remote" 70

  # Container status
  ssh -i "$SSH_KEY" -o BatchMode=yes "${SSH_USER}@${REMOTE_HOST}" "docker ps --filter 'name=${APP_NAME}' --format 'table {{.Names}}\\t{{.Status}}' || true" >>"$LOGFILE" 2>&1

  # Test via nginx public endpoint
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://${REMOTE_HOST}/api" || echo "000")
  log "HTTP status for http://${REMOTE_HOST}/api : ${HTTP_STATUS}"

  if [ "${HTTP_STATUS}" = "000" ]; then
    die "Could not reach http://${REMOTE_HOST}/api (curl error)" 71
  fi
  if [ "${HTTP_STATUS}" != "200" ]; then
    warn "Unexpected HTTP status ${HTTP_STATUS} (expected 200). Check logs."
    ssh -i "$SSH_KEY" -o BatchMode=yes "${SSH_USER}@${REMOTE_HOST}" "sudo tail -n 80 /var/log/nginx/error.log" >>"$LOGFILE" 2>&1 || true
    die "Deployment validation failed (HTTP ${HTTP_STATUS})" 72
  fi

  log "Validation successful (HTTP 200)."
}

########################################
# 8) Cleanup remote resources
########################################
remote_cleanup() {
  log "Running remote cleanup..."

  cleanup_script="$(mktemp)"
  cat >"$cleanup_script" <<'CLEAN_EOF'
set -e
NAME="$1"
# stop and remove containers under deployments
if [ -d ~/deployments ]; then
  for d in ~/deployments/*; do
    if [ -d "$d" ]; then
      cd "$d" || continue
      if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
        docker compose down --remove-orphans || docker-compose down --remove-orphans || true
      else
        CNAME="$(basename "$d")_container"
        docker rm -f "$CNAME" || true
      fi
    fi
  done
fi
# remove nginx conf created by script
sudo rm -f /etc/nginx/conf.d/"$NAME".conf || true
sudo systemctl reload nginx || true
echo "CLEAN_DONE"
CLEAN_EOF

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would run cleanup script on remote"
    rm -f "$cleanup_script"
    return 0
  fi

  scp -i "$SSH_KEY" -o BatchMode=yes "$cleanup_script" "${SSH_USER}@${REMOTE_HOST}:/tmp/cleanup_${TIMESTAMP}.sh" >>"$LOGFILE" 2>&1 || die "Failed to upload cleanup script" 80
  ssh -i "$SSH_KEY" -o BatchMode=yes "${SSH_USER}@${REMOTE_HOST}" "bash /tmp/cleanup_${TIMESTAMP}.sh '${APP_NAME}'" >>"$LOGFILE" 2>&1 || die "Remote cleanup failed" 81
  ssh -i "$SSH_KEY" -o BatchMode=yes "${SSH_USER}@${REMOTE_HOST}" "rm -f /tmp/cleanup_${TIMESTAMP}.sh" || true
  rm -f "$cleanup_script"
  log "Remote cleanup completed"
}

########################################
# Main flow
########################################
main() {
  collect_inputs
  prechecks_and_clone

  # derive APP_NAME from repo dir for nicer naming and idempotency
  APP_NAME="$(basename "$PROJECT_DIR" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' '-' )"
  log "Using application name: ${APP_NAME}"

  ssh_check

  if [ "$CLEANUP" -eq 1 ]; then
    remote_prep   # ensure remote available
    transfer_files # safe: ensures remote base dir exists
    remote_cleanup
    log "Cleanup finished"
    return 0
  fi

  remote_prep
  transfer_files
  remote_deploy
  validate
}

main "$@"
