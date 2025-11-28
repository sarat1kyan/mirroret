# Local Repository Server - Deployment Checklist

## Pre-Installation Checklist

### Hardware Requirements
- [ ] Server has minimum 4 GB RAM (8 GB recommended)
- [ ] Server has minimum 2 CPU cores (4 cores recommended)
- [ ] Disk space available:
  - [ ] Debian/Ubuntu: 500 GB - 1 TB
  - [ ] RHEL/CentOS: 200 GB - 500 GB
- [ ] Network connectivity: Minimum 100 Mbps (1 Gbps recommended)

### Software Requirements
- [ ] Linux distribution installed (Ubuntu 22.04, CentOS 9, or similar)
- [ ] Root/sudo access available
- [ ] Internet connectivity to official repositories
- [ ] No conflicting services on port 8080

### Network Prerequisites
- [ ] Static IP assigned to server
- [ ] Server IP: ________________
- [ ] Network segment: ________________ (e.g., 192.168.1.0/24)
- [ ] DNS resolution working
- [ ] Firewall rules planned

## Installation Phase

### Step 1: Download Installation Script
- [ ] Script downloaded: `local-repo-server-install.sh`
- [ ] Script permissions set: `chmod +x local-repo-server-install.sh`
- [ ] Script integrity verified (optional): `sha256sum local-repo-server-install.sh`

### Step 2: Run Installation
- [ ] Installation started: `sudo ./local-repo-server-install.sh`
- [ ] Installation completed without errors
- [ ] Installation log reviewed: `/var/log/local-repo-setup.log`
- [ ] All directories created successfully
- [ ] Nginx installed and running
- [ ] Cron job configured

### Step 3: Verify Installation
- [ ] Nginx status: `systemctl status nginx` → active (running)
- [ ] Port 8080 listening: `netstat -tlnp | grep 8080`
- [ ] Directory structure exists: `ls -la /var/local-repo/`
- [ ] Scripts executable: `ls -lah /var/local-repo/scripts/`
- [ ] Web interface accessible: `curl http://localhost:8080/`

## Initial Configuration

### Step 4: Configure Sync Settings
- [ ] Review mirror configuration:
  - [ ] Debian/Ubuntu: `/etc/apt/mirror.list`
  - [ ] RHEL/CentOS: Repository URLs configured
- [ ] Adjust mirrors to closest location (optional)
- [ ] Verify excluded architectures (e.g., i386 if not needed)
- [ ] Confirm components to sync (main, universe, etc.)

### Step 5: Configure Firewall
- [ ] Firewall rules added for port 8080
- [ ] Rules tested from client machine
- [ ] Source IP restrictions applied (recommended)
- [ ] Firewall configuration documented

### Step 6: Security Hardening (Optional but Recommended)
- [ ] HTTPS certificate generated
- [ ] Nginx SSL configuration updated
- [ ] Basic authentication configured
- [ ] IP whitelisting implemented
- [ ] SELinux/AppArmor policies reviewed

## First Sync

### Step 7: Initial Repository Sync
- [ ] Sync started: `/var/local-repo/scripts/sync-mirror.sh`
- [ ] Sync progress monitored: `tail -f /var/local-repo/logs/sync-*.log`
- [ ] Disk space monitored during sync: `watch df -h /var/local-repo`
- [ ] Sync completed successfully
- [ ] Sync duration recorded: ________ hours
- [ ] Final disk usage: ________ GB

### Step 8: Package Approval
- [ ] New packages reviewed: `/var/local-repo/scripts/show-updates.sh`
- [ ] Approval method decided:
  - [ ] Auto-approve all (initial setup)
  - [ ] Manual selective approval
  - [ ] Whitelist-based approval
- [ ] Packages approved: `/var/local-repo/scripts/approve-packages.sh`
- [ ] Repository metadata generated
- [ ] Approved packages count: ________

## Client Configuration

### Step 9: Configure First Test Client
- [ ] Test client selected
- [ ] Client OS: ________________
- [ ] Original repository configuration backed up
- [ ] Local repository configuration downloaded
- [ ] Configuration file installed
- [ ] Package cache updated successfully
- [ ] Test package installed: `apt/dnf install htop`
- [ ] Verification: Package source = local repository

### Step 10: Mass Client Deployment (if applicable)
- [ ] Client configuration script created
- [ ] Ansible playbook prepared (optional)
- [ ] Rollout plan documented
- [ ] Pilot group selected (5-10 clients)
- [ ] Pilot rollout successful
- [ ] Full rollout completed
- [ ] All clients verified

## Automation Setup

### Step 11: Verify Automated Tasks
- [ ] Cron job listed: `crontab -l`
- [ ] Sync schedule: Daily at ________ (default: 2:00 AM)
- [ ] Email notifications configured (optional)
- [ ] Log rotation configured
- [ ] Backup schedule defined

### Step 12: Monitoring Setup
- [ ] Disk usage monitoring enabled
- [ ] Nginx access logs monitoring
- [ ] Sync success/failure alerts
- [ ] Security update detection scheduled
- [ ] Dashboard/monitoring tool configured (optional)

## Documentation

### Step 13: Document Your Setup
- [ ] Server information documented:
  - Server IP: ________________
  - Port: 8080
  - Distribution: ________________
  - Installation date: ________________
- [ ] Network diagram created
- [ ] Client configuration documented
- [ ] Approval workflow documented
- [ ] Emergency procedures documented
- [ ] Team trained on daily operations

## Testing & Validation

### Step 14: Functional Testing
- [ ] Client can install new packages
- [ ] Client can update existing packages
- [ ] Client can search packages
- [ ] Package dependencies resolve correctly
- [ ] Multiple clients can download simultaneously
- [ ] Repository handles client disconnections gracefully

### Step 15: Failure Testing
- [ ] Tested: Nginx service restart
- [ ] Tested: Package rollback procedure
- [ ] Tested: Client behavior when server offline
- [ ] Tested: Sync failure recovery
- [ ] Tested: Disk full scenario
- [ ] Tested: Network interruption during sync

### Step 16: Performance Testing
- [ ] Measured: Single client download speed
- [ ] Measured: Multiple client concurrent downloads
- [ ] Measured: Repository sync duration
- [ ] Measured: Approval workflow time
- [ ] Performance acceptable: Yes / No
- [ ] Optimizations applied if needed

## Security Audit

### Step 17: Security Validation
- [ ] Only port 8080 exposed
- [ ] Firewall rules verified
- [ ] Unauthorized access blocked
- [ ] Package integrity checked
- [ ] Logs reviewed for suspicious activity
- [ ] Security update detection working
- [ ] CVE tracking functional

## Operational Readiness

### Step 18: Create Operational Procedures
- [ ] Daily checklist created
- [ ] Weekly maintenance procedures documented
- [ ] Monthly audit procedures defined
- [ ] Emergency contact list created
- [ ] Escalation procedures defined
- [ ] On-call schedule established (if applicable)

### Step 19: Backup & Disaster Recovery
- [ ] Backup strategy defined
- [ ] Configuration files backed up
- [ ] Approved package list backed up
- [ ] Scripts backed up
- [ ] Disaster recovery plan documented
- [ ] Recovery tested successfully
- [ ] Recovery time objective (RTO): ________ hours
- [ ] Recovery point objective (RPO): ________ hours

### Step 20: Final Sign-Off
- [ ] All installation steps completed
- [ ] All tests passed
- [ ] Documentation complete
- [ ] Team trained
- [ ] Monitoring active
- [ ] Backups configured
- [ ] Production ready

**Deployment completed by**: ________________  
**Date**: ________________  
**Sign-off**: ________________

---

## Post-Deployment Tasks

### First Week
- [ ] Day 1: Monitor initial sync and approvals
- [ ] Day 2: Verify all clients updated successfully
- [ ] Day 3: Review logs for any errors
- [ ] Day 4: Check disk usage trends
- [ ] Day 5: Test emergency rollback
- [ ] Day 7: Weekly maintenance completed

### First Month
- [ ] Week 1: Daily monitoring
- [ ] Week 2: Adjust approval workflow if needed
- [ ] Week 3: Optimize sync schedule
- [ ] Week 4: First monthly audit completed
- [ ] Performance metrics collected
- [ ] Security review completed
- [ ] Team feedback collected
- [ ] Improvements documented

## Ongoing Maintenance Schedule

### Daily (5 minutes)
- [ ] Check sync logs
- [ ] Review security updates
- [ ] Approve/review new packages
- [ ] Monitor disk space

### Weekly (30 minutes)
- [ ] Review client connectivity
- [ ] Clean old logs
- [ ] Update blacklist if needed
- [ ] Check for system updates on repo server

### Monthly (1-2 hours)
- [ ] Full system audit
- [ ] Test disaster recovery
- [ ] Review and update documentation
- [ ] Backup configurations
- [ ] Performance review
- [ ] Security assessment

### Quarterly (2-4 hours)
- [ ] Comprehensive security audit
- [ ] Review approval rules
- [ ] Test all emergency procedures
- [ ] Update team training
- [ ] Architecture review
- [ ] Capacity planning

---

## Troubleshooting Guide

### Common Issues During Deployment

#### Issue: Installation Script Fails
**Symptoms**: Script exits with error  
**Solution**:
- [ ] Check `/var/log/local-repo-setup.log`
- [ ] Verify internet connectivity
- [ ] Ensure sufficient disk space
- [ ] Check for conflicting services on port 8080
- [ ] Verify root/sudo permissions

#### Issue: Nginx Won't Start
**Symptoms**: systemctl status nginx shows failed  
**Solution**:
- [ ] Run `nginx -t` to test configuration
- [ ] Check port 8080 not in use: `netstat -tlnp | grep 8080`
- [ ] Review nginx error log: `/var/log/nginx/error.log`
- [ ] Verify file permissions on /var/local-repo

#### Issue: Sync Takes Too Long
**Symptoms**: Initial sync exceeds 12 hours  
**Solution**:
- [ ] Check network bandwidth: `speedtest-cli`
- [ ] Switch to closer mirror
- [ ] Reduce components being synced
- [ ] Increase parallel downloads (edit nthreads)

#### Issue: Clients Can't Connect
**Symptoms**: Client apt/dnf update fails  
**Solution**:
- [ ] Verify nginx running: `systemctl status nginx`
- [ ] Test from client: `curl http://SERVER_IP:8080/`
- [ ] Check firewall: `ufw status` or `firewall-cmd --list-all`
- [ ] Verify client config file syntax
- [ ] Check DNS resolution

#### Issue: Packages Not Installing
**Symptoms**: "Package not found" errors on clients  
**Solution**:
- [ ] Verify packages in approved directory
- [ ] Regenerate repository metadata
- [ ] Clear client cache: `apt clean` or `dnf clean all`
- [ ] Verify repository URL in client config

---

## Success Criteria

The deployment is considered successful when:

1. ✅ Repository server fully operational
2. ✅ Initial sync completed successfully
3. ✅ All clients configured and tested
4. ✅ Automated sync working (verified after first cron run)
5. ✅ Package approval workflow functional
6. ✅ Security measures in place
7. ✅ Monitoring and alerts active
8. ✅ Documentation complete
9. ✅ Team trained and confident
10. ✅ Backup and recovery tested

**Congratulations! Your local repository server is production-ready!**

---

## Appendix: Contact Information

| Role | Name | Contact |
|------|------|---------|
| Primary Admin | ____________ | ____________ |
| Secondary Admin | ____________ | ____________ |
| Security Contact | ____________ | ____________ |
| Network Admin | ____________ | ____________ |

## Appendix: Server Details

| Item | Value |
|------|-------|
| Hostname | ____________ |
| IP Address | ____________ |
| Operating System | ____________ |
| Disk Partition | ____________ |
| Total Disk Space | ____________ |
| Network Interface | ____________ |
| Installation Date | ____________ |
| Last Audit Date | ____________ |

---

**Save this checklist and refer to it during deployment!**
