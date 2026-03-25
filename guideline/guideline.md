# Proxmox + .NET + PostgreSQL Deployment Guideline

## Overview

This guide describes a production-ready, portable architecture using: -
Proxmox (VM infrastructure) - .NET applications - PostgreSQL - Docker +
Nginx - Ansible

## Goals

-   Provider portability
-   Reproducible setup
-   Zero downtime deployments
-   Graceful shutdown
-   Reliable backups

------------------------------------------------------------------------

## 1. Infrastructure Layout

### Virtual Machines

-   VM 100: ansible-control (2 vCPU, 4GB RAM)
-   VM 1020: app-20 (8 vCPU, 16GB RAM)
-   VM 1030: db-30 (8 vCPU, 24GB RAM)

------------------------------------------------------------------------

## 2. Network Setup

-   Use Proxmox bridge (vmbr0)
-   Assign static IPs:
    -   192.168.0.10 ansible-control
    -   192.168.0.20 app-20
    -   192.168.0.30 db-30

------------------------------------------------------------------------

## 3. Base OS Template

-   Ubuntu 24.04 LTS
-   Install:
    -   qemu-guest-agent
    -   cloud-init

------------------------------------------------------------------------

## 4. Ansible Setup

### Install

``` bash
sudo apt update
sudo apt install -y python3-pip git
pip install ansible
```

### Inventory

``` ini
[app]
app-20 ansible_host=192.168.0.20 ansible_user=deploy

[db]
db-30 ansible_host=192.168.0.30 ansible_user=deploy
```

------------------------------------------------------------------------

## 5. Docker Setup (app-20)

Install Docker:

``` bash
sudo apt install -y docker.io docker-compose-plugin
```

------------------------------------------------------------------------

## 6. Deployment Strategy

### Blue/Green Deployment

-   Two slots: blue / green
-   Deploy to inactive slot
-   Health check via:
    -   /.well-known/live
    -   /.well-known/ready
-   Switch Nginx upstream
-   Drain old instance

------------------------------------------------------------------------

## 7. Nginx

-   Reverse proxy
-   Reload without downtime:

``` bash
nginx -t && systemctl reload nginx
```

------------------------------------------------------------------------

## 8. PostgreSQL

-   Dedicated VM
-   Backup with pg_dump
-   Restrict access by IP

------------------------------------------------------------------------

## 9. Backup Strategy

-   Daily DB backups
-   External storage (S3 / remote VPS)
-   Test restore regularly

------------------------------------------------------------------------

## 10. Deployment Flow

1.  Build Docker image
2.  Deploy to inactive slot
3.  Wait for readiness
4.  Switch traffic
5.  Stop old instance

------------------------------------------------------------------------

## 11. Best Practices

-   Do not hardcode IPs
-   Use environment variables
-   Keep configs versioned
-   Test rollback procedures

------------------------------------------------------------------------

## Conclusion

This setup provides a balance between simplicity and production
readiness, without Kubernetes complexity.
