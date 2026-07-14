#!/usr/bin/env python3
"""sync_to_drone.py — 增量同步代码到机载电脑 (uavboard 无网场景)

用 paramiko (走 password), 不依赖 SSH key.

用法:
    python3 scripts/sync_to_drone.py <user>@<host> [options]
    python3 scripts/sync_to_drone.py ega-orin-nano-1@192.168.100.3 -k
    python3 scripts/sync_to_drone.py ega-orin-nano-1@192.168.100.3 -r -k
    python3 scripts/sync_to_drone.py ega-orin-nano-1@192.168.100.3 -s    # 同步 service 文件 (sudo cp)

行为 (按改的内容选 flag):
    -k     kill 远端节点 (launch 自动重启)  ← Python 改完必加 (内存 .pyc 缓存)
    -r     远端 colcon build                   ← 改 launch/setup.py/C++ 必加
    -s     sudo cp systemd service + reload  ← 改 rm_dep.service 必加

例子:
    # 改 slam_to_mavros_node.py (Python, 杀节点让 launch 重启)
    python3 scripts/sync_to_drone.py ega-orin-nano-1@192.168.100.3 -k

    # 改 launch file (要 rebuild + 杀节点)
    python3 scripts/sync_to_drone.py ega-orin-nano-1@192.168.100.3 -r -k

    # 改 service 文件 (sudo cp)
    python3 scripts/sync_to_drone.py ega-orin-nano-1@192.168.100.3 -s

    # 改 Dockerfile (重 build 镜像, 走 deploy_to_drone.sh 不是这个)
    bash scripts/deploy_to_drone.sh ega-orin-nano-1@192.168.100.3
"""
import sys
import os
import tarfile
import argparse
import paramiko


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('target', help='user@host (e.g. ega-orin-nano-1@192.168.100.3)')
    ap.add_argument('-k', '--kill', action='store_true', help='kill 远端节点 (Python 改完必加)')
    ap.add_argument('-r', '--rebuild', action='store_true', help='远端 colcon build')
    ap.add_argument('-s', '--service', action='store_true', help='sudo cp service 文件 + daemon-reload')
    ap.add_argument('-p', '--password', help='SSH password (默认用环境变量 DRONE_PASSWORD 或 prompt)')
    args = ap.parse_args()

    if '@' not in args.target:
        ap.error(f'target 格式错: {args.target} (应该是 user@host)')
    user, host = args.target.split('@', 1)

    # password
    password = args.password or os.environ.get('DRONE_PASSWORD')
    if not password:
        import getpass
        password = getpass.getpass(f'[{args.target}] password: ')

    # repo root (脚本所在 rm_ws)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(script_dir)

    # 1. SSH
    print(f'[1/4] SSH {user}@{host} ...')
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(host, username=user, password=password, timeout=30)
    client.get_transport().set_keepalive(30)
    print('    ✓ OK')

    # 2. tar 排除无用文件
    print(f'[2/4] 打包源码 (排除 .git/build/log/...)...')
    EXCLUDE = {'.git', '.colcon_ws', 'dist', 'build', 'log', '.vscode', '.idea', '.github'}
    tar_path = '/tmp/rm_ws_sync.tar.gz'
    if os.path.exists(tar_path):
        os.remove(tar_path)
    with tarfile.open(tar_path, 'w:gz') as tar:
        for root, dirs, files in os.walk(repo_root):
            dirs[:] = [d for d in dirs if d not in EXCLUDE]
            for f in files:
                full = os.path.join(root, f)
                rel = os.path.relpath(full, os.path.dirname(repo_root))
                tar.add(full, rel)
    size_mb = os.path.getsize(tar_path) // 1024 // 1024
    print(f'    ✓ {size_mb}MB tarball')

    # 3. sftp push + 远端解压
    print(f'[3/4] 推 + 解压 ...')
    sftp = client.open_sftp()
    sftp.put(tar_path, '/tmp/rm_dep_sync.tar.gz')
    sftp.close()
    # 远端解压 (保留原 ~/rm_ws/ 为 .bak, 失败可恢复)
    cmd = '''
cd ~ && \
  [ -d rm_ws ] && mv rm_ws rm_ws.bak.$(date +%Y%m%d_%H%M%S); \
  mkdir -p rm_ws && \
  tar -xzf /tmp/rm_dep_sync.tar.gz -C ~/ && \
  rm /tmp/rm_dep_sync.tar.gz && \
  echo "  ✓ 解压完成" && \
  ls ~/rm_ws/install/setup.bash && \
  echo "    install 在"
'''
    si, so, se = client.exec_command(cmd)
    print(so.read().decode().rstrip())

    # 4. 可选: rebuild + kill + service
    if args.rebuild:
        print('[4/4] 远端 colcon build (改 launch/setup.py 必加) ...')
        si, so, se = client.exec_command('''
cd ~/rm_ws && source /opt/uav_ws/install/setup.bash 2>/dev/null && \
  colcon build --symlink-install 2>&1 | tail -15
''')
        print(so.read().decode().rstrip())

    if args.kill:
        print('[4/4] 远端 kill 旧节点 (让 launch 重启) ...')
        si, so, se = client.exec_command('''
docker exec rm_dep bash -c "
    pkill -f slam_to_mavros_node 2>/dev/null
    pkill -f mavros_node 2>/dev/null
    pkill -f host_sdk_sample 2>/dev/null
    sleep 2
" 2>/dev/null; echo "    ✓ 旧节点已 kill"
''')
        print(so.read().decode().rstrip())

    if args.service:
        print('[4/4] 远端 sudo cp service + daemon-reload ...')
        si, so, se = client.exec_command(f'''
echo {password} | sudo -S bash -c "
    cp /home/{user}/rm_ws/scripts/rm_dep.service /etc/systemd/system/rm_dep.service
    systemctl daemon-reload
    systemctl restart rm_dep.service
" 2>&1 | tail -10
''')
        print(so.read().decode().rstrip())

    # 5. drone 端 git commit (如果 ~/rm_ws/.git 存在)
    print('[4/4] drone 端 git commit (留 history) ...')
    si, so, se = client.exec_command('''
cd ~/rm_ws
if [ -d .git ]; then
    git add -A
    if ! git diff --cached --quiet; then
        git -c user.email=drone@local -c user.name=drone commit -m "sync from dev $(date +%Y%m%d_%H%M%S)" 2>&1 | tail -3
        echo "    ✓ drone 端 commit 成功"
    else
        echo "    (无改动, 跳过 commit)"
    fi
    echo "    最近 5 个 commit:"
    git log --oneline -5 | sed 's/^/      /'
else
    echo "    (~/rm_ws 没有 .git, 跳过; 一次性 init: ssh ega-orin-nano-1@192.168.100.3 'cd ~/rm_ws && git init -b main && git add -A && git commit -m init')"
fi
''')
    print(so.read().decode().rstrip())

    client.close()
    print()
    print('='*60)
    print('✅ 同步完成')
    print('='*60)
    print('下次改代码就:')
    print(f'  python3 scripts/sync_to_drone.py {args.target} -k    # 改 Python')
    print(f'  python3 scripts/sync_to_drone.py {args.target} -r -k # 改 launch/C++')
    print(f'  python3 scripts/sync_to_drone.py {args.target} -s    # 改 service 文件')


if __name__ == '__main__':
    main()