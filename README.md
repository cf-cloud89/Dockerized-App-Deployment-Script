# Automated Dockerized App Deployment Script

This repository contains **`deploy.sh`**, a production-grade Bash script that automates the setup, deployment, and configuration of a Dockerized application on a remote Linux server — complete with **NGINX reverse proxy** configuration.

---

## Features

- Secure SSH-based deployment  
- Automatic Docker & NGINX installation (if missing)  
- Supports both `Dockerfile` and `docker-compose.yml`  
- Real-time validation and logging  
- Safe re-runs (idempotent)  
- Optional cleanup flag  

---

## Usage

### 1 Make the script executable
```bash
chmod +x deploy.sh
```

### 2 Run the script
Execute the script and follow the interactive prompts:
```bash
./deploy.sh
```

The script will prompt you for:

- Git Repository URL  
- Personal Access Token (PAT)  
- Branch name *(optional, defaults to main)*  
- Remote Server SSH details:  
  - Username  
  - Server IP  
  - SSH key path  
- Application port (internal container port)

---

## Example Input

When prompted, enter details like:
```
Enter GitHub Repository URL: https://github.com/yourusername/sample-docker-app.git
Enter Personal Access Token (PAT): ghp_abcd1234efgh5678ijkl
Enter Branch name (default: main): main
Enter SSH username: ec2-user
Enter Server IP: 3.120.45.67
Enter path to SSH private key: ~/.ssh/my-key.pem
Enter internal app port: 5000
```

---

## Flags

| Flag | Description |
|------|--------------|
| `--cleanup` | Removes deployed Docker containers, images, and NGINX config before re-deployment |
| `--help` | Displays usage information |

### Example:
```bash
./deploy.sh --cleanup
```

---

## Logs

All actions are logged in a file named:
```
deploy_YYYYMMDD.log
```

You can view logs after execution:
```bash
cat deploy_20251020.log
```

---

## Prerequisites

- Bash 4.0+  
- SSH access to the remote Linux server  
- GitHub Personal Access Token (PAT) with repo access  
- The remote server must allow inbound port **80**

---

## Example Application

This repo includes a simple **Python Flask app** and a **Dockerfile** that serves a “Hello from Flask!” message on port 5000.

---

## License

MIT License — feel free to modify and adapt for your own DevOps projects.