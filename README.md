# Automated Dockerized App Deployment Script

This project contains:
- A **POSIX-compliant `deploy.sh`** script that automates deployment of a Dockerized Flask app to a remote Linux server.
- A **simple Flask web app** (`app.py`) running behind **Nginx as a reverse proxy**.
- Configuration for **idempotent**, repeatable deployments on **AWS EC2** or any SSH-accessible server.

---

## Features

- Interactive user input for repo and server details  
- Automated installation of Docker, Docker Compose, and Nginx  
- Secure file transfer using SSH and rsync  
- Dynamic Nginx reverse proxy configuration  
- Automatic app validation via HTTP request  
- Supports `--dry-run` and `--cleanup` modes  
- Fully **POSIX-compliant** (runs on `/bin/sh`)

---

## Flask App Overview

The included Flask app (`app.py`) exposes two endpoints:

- `/` → Returns a plain text welcome message  
- `/api` → Returns JSON confirmation of successful deployment

### Example Output

```bash
$ curl http://<EC2_PUBLIC_IP>/api
{"message":"Flask app deployed successfully via deploy.sh","status":"OK"}
```

---

## Prerequisites

- Local machine with:
  - `git`, `ssh`, `rsync`, `curl`
- Remote server (e.g., AWS EC2) with:
  - SSH access (key-based)
  - `sudo` privileges
- A GitHub repository containing this project’s files

---

## Usage

### 1 Make the script executable
```bash
chmod +x deploy.sh
```

### 2 Run interactively
```bash
./deploy.sh
```

You’ll be prompted for:
- GitHub repo URL (HTTPS)
- Branch name (default: main)
- Personal Access Token (PAT)
- Remote SSH username (e.g., ubuntu)
- Remote host (EC2 IP address)
- SSH key path (e.g., ~/.ssh/mykey.pem)
- Application internal port (e.g., 5000)

### 3 Optional flags

| Flag | Description |
|------|--------------|
| `--dry-run` | Prints actions without making remote changes |
| `--cleanup` | Removes deployed app and Nginx config from remote server |
| `-h`, `--help` | Shows help info |

Example:
```bash
./deploy.sh --dry-run
```

---

## Accessing the App

Once deployment is complete, visit:
```
http://<EC2_PUBLIC_IP>/api
```
You should receive a **JSON response** confirming successful deployment.

---

## Cleanup

To stop and remove deployed containers and configurations:
```bash
./deploy.sh --cleanup
```

---
