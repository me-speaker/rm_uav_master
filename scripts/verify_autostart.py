#!/usr/bin/env python3
"""verify_autostart.py — 验证 uavboard 自启 + 全链路 work

用法:
    python3 scripts/verify_autostart.py ega-orin-nano-1@192.168.100.3

输出: 8 项检查, 全 ✅ = 成功
"""
import sys
import os
import time
import paramiko


def main():
    if len(sys.argv) < 2:
        print(f'用法: {sys.argv[0]} <user>@<host>')
        sys.exit(1)
    target = sys.argv[1]
    user, host = target.split('@', 1)

    import getpass
    password = os.environ.get('DRONE_PASSWORD') or getpass.getpass(f'[{target}] password: ')

    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(host, username=user, password=password, timeout=15)
    c.get_transport().set_keepalive(30)

    def run(cmd, sudo=False):
        if sudo:
            cmd = f'echo {password} | sudo -S -p "" bash -c "{cmd}" 2>&1'
        si, so, se = c.exec_command(cmd, get_pty=True)
        time.sleep(0.3)
        try:
            return so.channel.recv(8192).decode(errors='replace')
        except:
            return ''

    results = []
    def check(name, ok, detail=''):
        sym = '✅' if ok else '❌'
        results.append((sym, name, detail))

    # A. service active
    out = run('systemctl is-active rm_dep.service 2>&1', sudo=True)
    check('A. service active', 'active' in out, out.strip()[:50])

    # B. watchdog 进程
    si, so, se = c.exec_command('pgrep -af rm_dep-watchdog 2>&1 | head -3')
    out = so.read().decode()
    check('B. watchdog 在跑', 'rm_dep-watchdog' in out, out.strip()[:80])

    # C. 容器在
    si, so, se = c.exec_command('docker ps 2>&1 | grep rm_dep')
    out = so.read().decode()
    check('C. 容器在', 'rm_dep' in out and 'Up' in out, out.strip()[:80])

    # D. 3 节点
    si, so, se = c.exec_command(
        "docker exec rm_dep bash -c 'ps aux 2>/dev/null | grep -E \"host_sdk|mavros_node|slam_to_mavros\" | grep -v grep | wc -l'"
    )
    out_str = so.read().decode().strip().split('\n')[-1]  # 取最后一行 (数字)
    n_nodes = int(out_str or '0')
    check(f'D. 3 节点在容器内 (找到 {n_nodes})', n_nodes >= 3, '')

    # E. ODIN hz
    si, so, se = c.exec_command(
        "docker exec rm_dep bash -c 'source /opt/uav_ws/install/setup.bash 2>/dev/null && timeout 3 ros2 topic hz /odin1/odometry 2>/dev/null | tail -1'"
    )
    out = so.read().decode().strip().split('\n')[-1]  # 取最后一行
    hz = 0
    if 'average' in out:
        try:
            hz = float(out.split('average rate:')[1].split()[0])
        except: pass
    check(f'E. ODIN hz ≥ 10 ({hz:.1f} Hz)', hz >= 10, out[:80])

    # F. vision_pose hz
    si, so, se = c.exec_command(
        "docker exec rm_dep bash -c 'source /opt/uav_ws/install/setup.bash 2>/dev/null && timeout 3 ros2 topic hz /mavros/vision_pose/pose 2>/dev/null | tail -1'"
    )
    out = so.read().decode().strip().split('\n')[-1]
    hz = 0
    if 'average' in out:
        try:
            hz = float(out.split('average rate:')[1].split()[0])
        except: pass
    check(f'F. vision_pose hz ≥ 10 ({hz:.1f} Hz)', hz >= 10, out[:80])

    # G. PX4 跟 ODIN 距离
    si, so, se = c.exec_command(
        "docker exec rm_dep bash -c 'source /opt/uav_ws/install/setup.bash 2>/dev/null && timeout 5 python3 -c \""
        "import rclpy; from rclpy.node import Node; from rclpy.qos import QoSProfile, ReliabilityPolicy; "
        "from nav_msgs.msg import Odometry; import time, math; rclpy.init(); "
        "def get(t): n = Node(\\\"g\\\"); got = []; "
        "def cb(m): got.append((m.pose.pose.position.x, m.pose.pose.position.y, m.pose.pose.position.z)); "
        "qos = QoSProfile(reliability=ReliabilityPolicy.BEST_EFFORT, depth=10); "
        "n.create_subscription(Odometry, t, cb, qos); "
        "end = time.monotonic() + 2;"
        "while time.monotonic() < end and not got: rclpy.spin_once(n, timeout_sec=0.1); "
        "n.destroy_node(); return got[-1] if got else None; "
        "px4 = get(\\\"/mavros/local_position/odom\\\"); odin = get(\\\"/odin1/odometry\\\"); "
        "d = math.hypot(px4[0]-odin[0], px4[1]-odin[1]) if px4 and odin else -1; "
        "print(f\\\"{d*100:.1f}\\\")\" 2>/dev/null | tail -1'"
    )
    out = so.read().decode().strip()
    try:
        d_cm = float(out)
    except:
        d_cm = -1
    check(f'G. PX4 跟 ODIN 距离 ({"无数据" if d_cm < 0 else f"{d_cm:.1f} cm"})', 0 <= d_cm < 5, '')

    # H. vision_pose stamp
    si, so, se = c.exec_command(
        "docker exec rm_dep bash -c 'source /opt/uav_ws/install/setup.bash 2>/dev/null && "
        "timeout 3 ros2 topic echo /mavros/vision_pose/pose --once --field header.stamp.sec 2>/dev/null | tail -1'"
    )
    out = so.read().decode().strip()
    try:
        stamp = int(out)
        ok = stamp > 1_700_000_000  # 2023-11-15 后
    except:
        stamp = 0
        ok = False
    check(f'H. vision_pose stamp Unix ({stamp})', ok, '')

    c.close()

    # 输出
    print()
    print('='*60)
    print(f'  自启验证: {target}')
    print('='*60)
    for sym, name, detail in results:
        extra = f'  ({detail})' if detail and sym == '❌' else ''
        print(f'  {sym}  {name}{extra}')
    print()
    n_ok = sum(1 for s, _, _ in results if s == '✅')
    n_total = len(results)
    print(f'  {n_ok}/{n_total} 通过')
    if n_ok == n_total:
        print()
        print('  🎉 全部通过, 自启成功!')
    else:
        print()
        print('  ❌ 有失败项, 排查上面 ❌ 项')
    sys.exit(0 if n_ok == n_total else 1)


if __name__ == '__main__':
    main()