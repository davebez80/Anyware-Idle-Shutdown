#!/bin/bash
# Copyright (c) 2018 Teradici Corporation; © Copyright 2023 HP Development Company, L.P.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
#
# Installs and configures the 'shut down when idle' systemd service and timer
# definitions, optionally disabling the service at installation.
#
# If the '--remove' or '-remove' options are specified, the systemd units
# and idle monitor script are removed from the system.

SERVICE_NAME="CAMIdleShutdown"
SERVICE="${SERVICE_NAME}.service"
TIMER="${SERVICE_NAME}.timer"
SERVICE_PATH="/etc/systemd/system/${SERVICE}"
TIMER_PATH="/etc/systemd/system/${TIMER}"
SERVICE_CONFIG_PATH="${SERVICE_PATH}.d"
TIMER_CONFIG_PATH="${TIMER_PATH}.d"
TIMER_CONFIG="${TIMER_CONFIG_PATH}/CAMIdleShutdown.conf"
SERVICE_CONFIG="${SERVICE_CONFIG_PATH}/CAMIdleShutdown.conf"

MONITOR_SCRIPT=/opt/Teradici_CAM_idle_shutdown.py

# Idle time in minutes before auto-shutdown should be engaged
IDLE_TIMER=240
# If set to 1, the auto-shutdown service will be disabled
IS_DISABLED=0

function die() {
    printf '%s\n' "$1" >&2
    exit 1
}

function create_monitor_script() {
    touch ${MONITOR_SCRIPT}
    chmod 644 ${MONITOR_SCRIPT}
    cat <<'EOF'> ${MONITOR_SCRIPT}
#!/usr/bin/python
# Copyright 2017 Teradici Corporation; © Copyright 2023 HP Development Company, L.P.

import syslog
import time
import os
import subprocess
import re

# Shutdown the machine if it has been idle more than the specified number of minutes
# Additionally, do not log off if there is an active ssh connection, or
# there are instances of pcoip-server processes running.

syslog.openlog("ShutdownIdleAgent", syslog.LOG_PID)

# Used for measuring CPU Usage, initialize to 0
BusyTime_last = BusyTime_now = IdleTime_now = IdleTime_last = 0

# File containing state information
startTimeFile = "/tmp/CAMIdleState"
cpuUsageFile = "/tmp/CAMIdleStateCPU"

# Default settings
defaultIdleTime = 5             # time in minutes
defaultCpuThreshold = 20

def getStartTime():
    """
    Check what the start time is
    """
    if os.path.exists(startTimeFile):
        with open(startTimeFile, 'rb') as f:
            startTime = f.read()
        return int(startTime)
    else:
        return None

def clearStartTime():
    """
    Clears what the start time is
    """
    if os.path.exists(startTimeFile):
        os.remove(startTimeFile)

def setStartTime(startTime):
    """
    Set what the start time is
    """
    with open(startTimeFile, 'wb') as f:
        f.write(str(int(startTime)))
    return

def loadCPU():
    """
    Get what the Idle and Busy CPU Time was for last sample
    """
    if os.path.exists(cpuUsageFile):
        with open(cpuUsageFile, 'rb') as f:
            return map(float, f.read().split(','))
    return [0, 0]

def saveCPU(idleTime, busyTime):
    """
    Set what the Idle and Busy CPU Time was for last sample
    """
    with open(cpuUsageFile, 'wb') as f:
        f.write("{idle},{busy}".format(
            idle=idleTime,
            busy=busyTime
        ))
    return

def activeConnectionsExist():
    """
    Check for active PCoIP or SSH sessions
    """
    # Check for SSH Session
    sessions = subprocess.check_output(['/usr/bin/who']).split('\n')
    for session in sessions:
        # Check if session is an X-Session
        re_session = re.match(".*\((.*)\)", session)
        if re_session and not re_session.group(1).startswith(":"):
            return True

    # Check for PCoIP Session
    processes = subprocess.check_output(['/bin/ps', 'aux']).split('\n')
    for process in processes:
        if 'pcoip-server' in process:
            return True

    return False

def getCPULoad():
    """
    Get average CPU Load since last Poll

    For each CPU there are 7 counters:
        UserTime, NiceTime, SystemTime, IdleTime, IOwaitTime, IRQTime, and SoftIRQTime
    The average CPU usage since startup for any given sample is therefore simply:

        Usage = (1 - IdleTime/(IdleTime + BusyTime))*100%, where
        BusyTime = UserTime + NiceTime + SystemTime + IOwaitTime + IRQTime + SoftIRQTime

    This is pretty straight forward, but what is needed is actually the average CPU usage
    over the sampling interval. To get this, we need to values of the IdleTime and BusyTime
    of the previous sample. This leads to the equation:

        Usage_avg   = Change in CPU Stat Counter
                    = 1 - (IdleTime_now - IdleTime_last)/((IdleTime_now + BusyTime_now) - (IdleTime_last + BusyTime_last))
                    = ((IdleTime_now + BusyTime_now) - (IdleTime_last + BusyTime_last))/((IdleTime_now + BusyTime_now) - (IdleTime_last + BusyTime_last))
                        - (IdleTime_now - IdleTime_last)/((IdleTime_now + BusyTime_now) - (IdleTime_last + BusyTime_last))
                    = (IdleTime_now + BusyTime_now -IdleTime_last - BusyTime_last - IdleTime_now + IdleTime_last)/((IdleTime_now + BusyTime_now) - (IdleTime_last + BusyTime_last))
                    = (BusyTime_now - BusyTime_last)/((IdleTime_now + BusyTime_now) - (IdleTime_last + BusyTime_last))
    """
    IdleTime_last, BusyTime_last = loadCPU()
    cpu_usage = 0
    cpu_stats = ''
    proc_stats = subprocess.check_output(['/bin/cat','/proc/stat']).split('\n')
    for stat in proc_stats:
        if re.match('^cpu[^\d]+', stat):
            cpu_stats = stat
            break

    re_cpu_stats = re.match('^cpu\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+', cpu_stats)
    if re_cpu_stats:
        user_cpu = float(re_cpu_stats.group(1))
        nice_cpu = float(re_cpu_stats.group(2))
        system_cpu = float(re_cpu_stats.group(3))
        idle_cpu = float(re_cpu_stats.group(4))
        iowait_cpu = float(re_cpu_stats.group(5))
        irq_cpu = float(re_cpu_stats.group(6))
        softirq_cpu = float(re_cpu_stats.group(7))

        IdleTime_now = idle_cpu
        BusyTime_now = user_cpu + nice_cpu + system_cpu + iowait_cpu + irq_cpu + softirq_cpu

        cpu_usage = 100.0* (BusyTime_now - BusyTime_last)/((IdleTime_now + BusyTime_now) - (IdleTime_last + BusyTime_last))
        
        saveCPU(IdleTime_now, BusyTime_now)
    
    return round(cpu_usage, 2)

def parseEnvSetting(env_var, min_value):
    """
    Attempts to read env_var and parse its value as an integer. If the value is not a
    number or is less than min_value, min_value will be used.
    """
    value = min_value
    try:
        value = int(os.environ.get(env_var, min_value))
        if value < min_value:
           value = min_value
    except ValueError:
        syslog.syslog(syslog.LOG_WARNING, 'Idle shutdown configuration has an invalid idle timer; using default value of {} min'.format(min_value))
    return value

def getSettings():
    """
    Load settings for the service.
    """
    waitTime = parseEnvSetting('MinutesIdleBeforeShutdown', defaultIdleTime) * 60  # Convert idle time value to seconds
    cpuThreshold = parseEnvSetting('CPUUtilizationLimit', defaultCpuThreshold)
    
    return (cpuThreshold, waitTime)

def main():
    """
    Main function, monitor active sessions and CPU usage and shutdown when appropriate
    """
    cpuThreshold, waitTime = getSettings()

    if activeConnectionsExist():
        syslog.syslog("Session is active, not shutting down")
        clearStartTime()
    else:
        cpuUsage = getCPULoad()
        if cpuUsage < cpuThreshold:
            startTime = getStartTime()
            if not startTime:
                startTime = time.time()
                setStartTime(startTime)
            currentTime = time.time()
            elapsedTime = currentTime - startTime
            syslog.syslog("CPU usage is now {cpu}%, it is below idle threshold. CPU has been idle for at least {min} minutes".format(
                min=int(elapsedTime/60),
                cpu=cpuUsage
            ))
            if elapsedTime > waitTime:
                syslog.syslog("CPU has been idle for more than {} minutes, shutting down".format(
                    waitTime
                ))
                clearStartTime()
                subprocess.Popen(['/sbin/shutdown'])
        else:
            syslog.syslog("CPU usage is now {cpu}%, CPU is active".format(
                cpu=cpuUsage
            ))
            clearStartTime()

if __name__=="__main__":
    main()
EOF
}

function install() {
    echo "Installing"
    touch ${SERVICE_PATH}
    chmod 644 ${SERVICE_PATH}
    mkdir -p ${SERVICE_CONFIG_PATH}
    touch ${SERVICE_CONFIG}
    chmod 644 ${SERVICE_CONFIG}
    mkdir -p ${TIMER_CONFIG_PATH}
    touch ${TIMER_CONFIG}
    chmod 644 ${TIMER_CONFIG}
    create_monitor_script
    cat <<EOF> ${SERVICE_PATH}
[Unit]
Description=Teradici CAM Idle Shutdown monitoring service

[Service]
Type=simple
ExecStart=/usr/bin/python ${MONITOR_SCRIPT}
KillMode=process
EOF
    cat <<EOF> ${TIMER_PATH}
[Unit]
Description=Teradici CAM Idle Shutdown monitoring service

[Timer]
OnBootSec=30
Unit=${SERVICE}

[Install]
WantedBy=timers.target
EOF
    cat <<EOF> ${SERVICE_CONFIG}
[Service]
Environment="MinutesIdleBeforeShutdown=${IDLE_TIMER}"
Environment="CPUUtilizationLimit=20"
EOF
    cat <<EOF> ${TIMER_CONFIG}
[Timer]
OnUnitActiveSec=15min
EOF

    systemctl daemon-reload
    if [[ $IS_DISABLED -eq 0 ]]; then
        enable_service
    else
        disable_service
    fi
}

function enable_service() {
    echo "Starting auto-shutdown service"
    systemctl enable ${TIMER}
    systemctl start ${SERVICE}
    systemctl start ${TIMER}
}

function disable_service() {
    echo "Disabling auto shutdown"
    systemctl stop ${TIMER}
    systemctl stop ${SERVICE}
    systemctl disable ${TIMER}
}

function remove() {
    echo "Removing"
    disable_auto_shutdown
    rm -rf "/etc/systemd/system/${SERVICE_NAME}"*
    rm ${MONITOR_SCRIPT}
    systemctl daemon-reload
}

function should_be_root() {
    if [[ $EUID -ne 0 ]]; then
        die "You must be root for this operation"
    fi
}

function main() {
    should_be_root
    while :; do
        case $1 in
            "--remove" | "-remove" | "-r")
                remove
                exit 0
                ;;
            "--idle-timer" | "-idle-timer" | "-i")
                # This option is only necessary if you want to change the default idle timer
                # Here, we check if a value is given and that it's an integer
                if [[ -n "$2" && $2 == ?(-)+([0-9]) ]]; then
                    IDLE_TIMER=$2
                    shift
                else
                    die "ERROR: --idle-timer requires a numeric argument"
                fi
                ;;
            "--disabled" | "-disabled" | "-d")
                IS_DISABLED=1
                break
                ;;
            *)
            break
        esac

        shift
    done

    install
}

main $@
exit 0
