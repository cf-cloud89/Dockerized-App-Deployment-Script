# Dockerized Application Deployment Script

A production-grade Bash script that automates the complete deployment of Dockerized applications to remote Linux servers with Nginx reverse proxy configuration.

## Features

- Automated Docker & Nginx installation
- Git repository cloning with PAT authentication
- Support for both Dockerfile and docker-compose.yml
- Automatic Nginx reverse proxy configuration
- Comprehensive error handling and logging
- Port conflict resolution
- Idempotent deployment (safe to run multiple times)
- Support for Ubuntu/Debian and RHEL/CentOS/Fedora
- Cleanup mode for resource removal

## Prerequisites

### Local Machine
- Bash 4.0+
- Git
- SSH client
- rsync (optional, script will fallback to scp)

### Remote Server
- Ubuntu/Debian or RHEL/CentOS/Fedora
- SSH access with key-based authentication
- Sudo privileges

## Quick Start

### 1. Clone This Repository
```bash
git clone https://github.com/cf-cloud89/Dockerized-App-Deployment-Script.git
cd Dockerized-App-Deployment-Script
chmod +x deploy.sh
```

### 2. Prepare Your Application Code and Repository
Ensure your application has either:
- **Dockerfile** - for single container apps
- **docker-compose.yml** - for multi-container apps

### 3. Run Deployment
```bash
./deploy.sh
```

### 4. Provide Required Information
The script will prompt you for:
- Git repository URL
- Personal Access Token (PAT)
- Branch name (default: main)
- SSH username
- Server IP address
- SSH key path (default: ~/.ssh/id_rsa)
- Application port

### 5. Access Your Application
```bash
http://<YOUR_SERVER_IP>
```

## Usage Examples

### Deploy Application
```bash
./deploy.sh
```

### Clean Up Deployment
```bash
./deploy.sh --cleanup
```

**Important:** Your application MUST bind to `0.0.0.0`, not `localhost`.

## GitHub Personal Access Token

1. Go to GitHub → Settings → Developer settings → Personal access tokens (classic)
2. Generate new token
3. Select scope
4. Copy token and use when prompted by script

## SSH Key Setup

```bash
# Generate SSH key if needed
ssh-keygen -t rsa -b 4096 -f ~/.ssh/<key_name>

# Copy to server
ssh-copy-id -i ~/.ssh/<key_name>.pub user@server-ip

# Test connection
ssh -i ~/.ssh/<key_name> user@server-ip
```

## What The Script Does

1. **Collects Parameters** - Validates all user inputs
2. **Clones Repository** - Authenticates and pulls your code
3. **Tests SSH Connection** - Verifies server access
4. **Prepares Environment** - Installs Docker, Docker Compose, Nginx
5. **Deploys Application** - Builds and runs Docker containers
6. **Configures Nginx** - Sets up reverse proxy on port 80
7. **Validates Deployment** - Tests all services and endpoints
8. **Logs Everything** - Creates timestamped deployment logs

## Deployment Flow

```
User Input → Clone Repo → SSH Test → Install Dependencies
     ↓
Stop Old Containers → Build Image → Run Container
     ↓
Configure Nginx → Test Endpoints → Success!
```

## Logs

All operations are logged to timestamped files:
```bash
deploy_YYYYMMDD_HHMMSS.log
```

Check logs for debugging:
```bash
cat deploy_20251023_143000.log
```

## Troubleshooting

### SSH Connection Fails
```bash
# Check SSH key permissions
chmod 600 ~/.ssh/<key_name>

# Test connection
ssh -vvv -i ~/.ssh/<key_name> user@server-ip
```

### Port Already in Use
The script automatically stops conflicting containers. If issues persist:
```bash
# On remote server
docker ps
docker stop container-name
```

### Application Not Accessible
```bash
# Check container logs
ssh user@server-ip
docker logs container-name

# Check Nginx
sudo systemctl status nginx
sudo tail -f /var/log/nginx/error.log
```

## Supported Operating Systems

**Remote Server:**
- Ubuntu 20.04, 22.04, 24.04
- Debian 10, 11, 12
- RHEL 8, 9
- CentOS 8, 9
- Fedora 38, 39, 40

**Local Machine:**
- Any Unix-like system with Bash 4.0+

## Security Considerations

- PAT tokens are never logged
- SSH keys require correct permissions (600)
- Uses key-based authentication only
- All credentials are user-provided at runtime

## Project Structure

```
Dockerized-App-Deployment-Script/
├── deploy.sh           # Main deployment script
├── README.md           # This file
├── server.py           # Replace with your app
├── Dockerfile          # Replace with your Dockerfile or docker-compose.yml file
└── deploy_*.log        # Generated log files
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

---

**Made with ❤️ for the DevOps Community**
