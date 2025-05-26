from dotenv import load_dotenv
from datetime import datetime
import os
import psutil
import requests
import re
import socket
import subprocess
import glob
import time

# Load environment variables from .env file
load_dotenv()

DEBUG = int(os.getenv("DEBUG", "0"))
INTERVAL = int(os.getenv("INTERVAL", "600"))

# Telegram bot settings (from environment)
BOT_API_TOKEN     = os.getenv('BOT_API_TOKEN')
CHAT_ID           = os.getenv('CHAT_ID')
try:
    MESSAGE_THREAD_ID = int(os.getenv('MESSAGE_THREAD_ID', '0'))
except ValueError:
    MESSAGE_THREAD_ID = None

# Thresholds

DISK_THRESHOLD         = int(os.getenv("DISK_THRESHOLD", "50"))                # % usage for NVMe alerts     
RAM_FREE_THRESHOLD     = int(os.getenv("RAM_FREE_THRESHOLD", "8"))             # % free RAM                  
RAMDISK_FREE_THRESHOLD = int(os.getenv("RAMDISK_FREE_THRESHOLD", "8"))         # % free ramdisk              
IO_WAIT_THRESHOLD      = int(os.getenv("IO_WAIT_THRESHOLD", "4"))              # % IO wait alerts            
SWAP_THRESHOLD         = int(os.getenv("SWAP_THRESHOLD", "10"))                # % swap usage alerts         
CPU_TEMP_CRIT          = int(os.getenv("CPU_TEMP_CRIT", "90"))                 # �C critical CPU temp alerts 
NVME_TEMP_CRIT         = int(os.getenv("NVME_TEMP_CRIT", "60"))                # �C critical NVMe temp alerts

TELEGRAF_CONF = '/etc/telegraf/telegraf.conf'

# Emoji definitions
EMOJI_HOST           = '\U0001F50D'  # ??
EMOJI_NVME           = '\U0001F4BD'  # ??
EMOJI_RAMDISK        = '\U0001F5C4'  # ??
EMOJI_RAM            = '\U0001F4BE'  # ??
EMOJI_SWAP           = '\U0001F4BF'  # ??
EMOJI_IOWAIT         = '\u26A0\uFE0F' # ??
EMOJI_CPU            = '\U0001F321'  # ??
EMOJI_OK             = '\U0001F7E2'  # ??
EMOJI_CRIT           = '\U0001F534'  # ??
EMOJI_SERVICE_ALERT  = '\U0001F6A8'  # ??
EMOJI_SERVICE_UP     = '\u2705'      # ?


def get_node_name_and_ip():
    node = 'unknown'
    try:
        with open(TELEGRAF_CONF, 'r', encoding='utf-8') as f:
            content = f.read()
        m = re.search(r"^\s*hostname\s*=\s*\"(.+?)\"", content, re.MULTILINE)
        if m:
            node = m.group(1)
    except:
        pass
    ip = '0.0.0.0'
    for iface, addrs in psutil.net_if_addrs().items():
        for addr in addrs:
            if addr.family == socket.AF_INET and not addr.address.startswith('127.'):
                ip = addr.address
                break
        if ip != '0.0.0.0':
            break
    return node, ip


def get_nvme_metrics():
    metrics = []
    for idx, dev in enumerate(sorted(glob.glob('/dev/nvme*n1')), 1):
        pct = temp = None
        try:
            out = subprocess.check_output(['nvme', 'smart-log', dev], stderr=subprocess.DEVNULL).decode('utf-8')
            m_pct = re.search(r'percentage_used\s*:\s*(\d+)%', out)
            m_tmp = re.search(r'temperature\s*:\s*(\d+)', out)
            pct = int(m_pct.group(1)) if m_pct else None
            temp = int(m_tmp.group(1)) if m_tmp else None
        except:
            pass
        metrics.append((f'per{idx}', pct, temp))
    return metrics


def get_cpu_temp():
    temps = psutil.sensors_temperatures()
    for key in ('k10temp', 'coretemp', 'acpitz'):
        if key in temps:
            vals = [e.current for e in temps[key] if e.current is not None]
            if vals:
                return max(vals)
    fallback = [e.current for lst in temps.values() for e in lst if e.current is not None]
    return max(fallback) if fallback else None


def check_service(name='solana.service'):
    try:
        r = subprocess.run(['systemctl', 'is-active', name], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return r.stdout.decode().strip() == 'active'
    except:
        return False


def get_service_uptime(name='solana.service'):
    try:
        out = subprocess.check_output(['systemctl', 'show', '-p', 'ActiveEnterTimestamp', name], stderr=subprocess.DEVNULL).decode()
        m = re.search(r'ActiveEnterTimestamp=(.+)', out)
        if m:
            started_str = m.group(1).strip()
            started_time = datetime.strptime(started_str, "%a %Y-%m-%d %H:%M:%S %Z")
            uptime_sec = (datetime.utcnow() - started_time).total_seconds()
            hours = int(uptime_sec // 3600)
            minutes = int((uptime_sec % 3600) // 60)
            return f'{hours}h {minutes}m'
    except:
        pass
    return 'N/A'


def get_metrics():
    # Ramdisk (largest tmpfs/ramfs)
    ramdisks = []
    for part in psutil.disk_partitions(all=True):
        if part.fstype in ('tmpfs', 'ramfs'):
            try:
                u = psutil.disk_usage(part.mountpoint)
                ramdisks.append((part.mountpoint, u.total, u.used))
            except:
                pass
    ramdisk = max(ramdisks, key=lambda x: x[1]) if ramdisks else None

    mem = psutil.virtual_memory()
    swap = psutil.swap_memory()
    io_wait = psutil.cpu_times_percent(interval=1).iowait
    cpu_temp = get_cpu_temp()
    return ramdisk, mem, io_wait, swap.total, swap.percent, cpu_temp


def build_message(node, ip, nvme_metrics, ramdisk, mem, io_wait, swap_total, swap_pct, cpu_temp, service_ok):
    alert = False
    lines = [f'[{EMOJI_HOST}] *{node}* | `{ip}`']

    # NVMe
    if nvme_metrics:
        lines.append(f'{EMOJI_NVME} NVMe:')
        for name, pct, temp in nvme_metrics:
            parts = []
            if pct is not None:
                e = EMOJI_OK if pct < DISK_THRESHOLD else EMOJI_CRIT
                if pct >= DISK_THRESHOLD:
                    alert = True
                parts.append(f'{pct}% {e}')
            if temp is not None:
                e = EMOJI_OK if temp < NVME_TEMP_CRIT else EMOJI_CRIT
                if temp >= NVME_TEMP_CRIT:
                    alert = True
                parts.append(f'{temp}\u00B0C {e}')
            lines.append(f'  {name}: ' + ' | '.join(parts))

    # Ramdisk
    if ramdisk:
        mnt, tot, used = ramdisk
        tg = tot / 2**30
        ug = used / 2**30
        free = (tot - used) / tot * 100
        e = EMOJI_OK if free > RAMDISK_FREE_THRESHOLD else EMOJI_CRIT
        if free <= RAMDISK_FREE_THRESHOLD:
            alert = True
        lines.append(f'{EMOJI_RAMDISK} Ramdisk ({mnt}): {ug:.1f}/{tg:.1f} GB, free {free:.0f}% {e}')
    else:
        lines.append(f'{EMOJI_RAMDISK} Ramdisk: N/A')

    # RAM
    free_ram = mem.available / mem.total * 100
    ug = mem.used / 2**30
    tg = mem.total / 2**30
    e = EMOJI_OK if free_ram > RAM_FREE_THRESHOLD else EMOJI_CRIT
    if free_ram <= RAM_FREE_THRESHOLD:
        alert = True
    lines.append(f'{EMOJI_RAM} RAM: {ug:.1f}/{tg:.1f} GB, free {free_ram:.0f}% {e}')

    # Swap
    e = EMOJI_OK if swap_pct < SWAP_THRESHOLD else EMOJI_CRIT
    if swap_pct >= SWAP_THRESHOLD:
        alert = True
    stg = swap_total / 2**30
    lines.append(f'{EMOJI_SWAP} Swap: {stg:.0f} GB used {swap_pct:.0f}% {e}')

    # IOWait
    e = EMOJI_OK if io_wait < IO_WAIT_THRESHOLD else EMOJI_CRIT
    if io_wait >= IO_WAIT_THRESHOLD:
        alert = True
    lines.append(f'{EMOJI_IOWAIT} IOWait: {io_wait:.0f}% {e}')

    # CPU Temp
    if cpu_temp is not None:
        e = EMOJI_OK if cpu_temp < CPU_TEMP_CRIT else EMOJI_CRIT
        if cpu_temp >= CPU_TEMP_CRIT:
            alert = True
        lines.append(f'{EMOJI_CPU} CPU Temp: {cpu_temp:.0f}\u00B0C {e}')

    # Service
    if not service_ok:
        alert = True
        lines.append(f'{EMOJI_SERVICE_ALERT} solana.service: {EMOJI_CRIT} DOWN')
    else:
        uptime_str = get_service_uptime()
        lines.append(f'{EMOJI_SERVICE_UP} solana.service: {EMOJI_OK} UP ({uptime_str})')

    # ✅ Вот здесь возвращаем результат!
    return '\n'.join(lines), alert




def send_to_telegram(text):
    payload = {
        'chat_id': CHAT_ID,
        'text': text,
        'parse_mode': 'Markdown',
        'message_thread_id': MESSAGE_THREAD_ID
    }
    requests.post(f'https://api.telegram.org/bot{BOT_API_TOKEN}/sendMessage', json=payload)


def main():
    node, ip = get_node_name_and_ip()
    nvme_metrics = get_nvme_metrics()
    ramdisk, mem, io_wait, swap_total, swap_pct, cpu_temp = get_metrics()
    service_ok = check_service()
    msg, alert = build_message(node, ip, nvme_metrics, ramdisk, mem, io_wait, swap_total, swap_pct, cpu_temp, service_ok)
    if alert or DEBUG:
        send_to_telegram(msg)


if __name__ == '__main__':
    while True:
        main()
        time.sleep(INTERVAL)
