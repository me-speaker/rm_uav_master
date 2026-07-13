# 机载电脑开机自启 (ODIN + PX4 + mavros)

> 适用: Jetson (Orin / NX / Nano) 或类似小电脑, 上电后自动跑完整外部定位链路.
> systemd 启容器, 容器内 watchdog 启节点.

## 架构

```
小电脑上电
    ↓
systemd 启动 rm_dep.service
    ↓
/usr/local/bin/rm_dep-autostart.sh
    ↓
docker rm/start 容器 (挂 ODIN USB, idle)
    ↓
容器内 watchdog (rm_dep-watchdog.sh)
    ↓ 循环检测 /dev/ttyACM0
    ↓
PX4 飞控上电 → USB 出现 → watchdog 调 launch_odin_px4.sh
    ↓
launch_odin_px4.sh
    ↓ 启 ODIN driver (12s SDK init)
    ↓ 启 mavros (8s 连接)
    ↓ 启 slam_to_mavros (force_ros_stamp=true)
    ↓ 验证 4 个核心 topic
    ↓
PX4 EKF2 fusion 开始工作
```

**关键设计**:
- PX4 飞控上电时间晚于小电脑 (常见) → watchdog 等 USB 出现才启节点
- PX4 断电 / 重启 → watchdog 健康检查发现 mavros 死了 → 自动重启 launch
- 容器先 idle, watchdog 决定何时 launch

## 安装 (在机载电脑上一次性)

```bash
# 1. 假设 rm_ws 已 git clone 到 ~/rm_ws
cd ~/rm_ws

# 2. 拷 systemd 调用脚本到 /usr/local/bin
sudo cp scripts/rm_dep-autostart.sh /usr/local/bin/
sudo cp scripts/rm_dep-stop.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/rm_dep-*.sh

# 3. 装 systemd unit
sudo cp scripts/rm_dep.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable rm_dep.service   # 开机自启

# 4. (可选) 立即试一次 (不重启)
sudo systemctl start rm_dep.service
sudo systemctl status rm_dep.service
```

## 卸载

```bash
sudo systemctl disable rm_dep.service
sudo rm /etc/systemd/system/rm_dep.service
sudo rm /usr/local/bin/rm_dep-*.sh
sudo systemctl daemon-reload
```

## 日常使用

### 自动模式 (上电就启)
小电脑上电 → 自动:
1. docker run 容器
2. 等 PX4 USB 出现 (可能几秒到几分钟)
3. 启 ODIN + mavros + slam_to_mavros
4. PX4 EKF2 fusion 跑起来

### 手动模式 (不开机自启,调试用)
```bash
# 启容器 (idle, 挂 USB)
bash scripts/start_uav_container.sh --lidar odin

# 启节点 (一键)
bash scripts/launch_odin_px4.sh

# 停节点 (容器保留)
docker exec rm_dep pkill -f slam_to_mavros_node
docker exec rm_dep pkill -f mavros_node
docker exec rm_dep pkill -f host_sdk_sample

# 完全停
sudo systemctl stop rm_dep.service
```

### 看 watchdog 状态
```bash
# 当前在做什么
docker exec rm_dep tail -f /tmp/rm_dep-watchdog.log

# systemd 状态
sudo systemctl status rm_dep.service
sudo journalctl -u rm_dep.service -f
```

## systemd service 说明

```ini
[Service]
Type=oneshot             # 跑完脚本就退
RemainAfterExit=yes      # 退完后 service 仍是 "active"
ExecStart=rm_dep-autostart.sh
ExecStop=rm_dep-stop.sh
Restart=on-failure       # 失败自动重启 (但 watchdog 在容器内自己循环)
RestartSec=30
TimeoutStartSec=600      # 首次启动 build 给 10 分钟
```

`Type=oneshot` + `RemainAfterExit=yes` 是这种"主进程跑完就退,但后台逻辑继续"的场景的标准做法。systemd 不直接管容器和 watchdog,而是管"启动逻辑",watchdog 在容器内 fork 后独立跑。

## 故障排查

### systemd 起不来
```bash
sudo journalctl -u rm_dep.service -n 100
```

### 容器起不来
```bash
docker logs rm_dep  # 容器内 entrypoint 输出
# 或
docker exec rm_dep bash -c "test -f /opt/uav_ws/install/setup.bash && echo OK || echo MISSING"
```

### watchdog 找不到 PX4 USB
```bash
# 主机端
lsusb | grep -iE "PX4|1206"
ls -la /dev/ttyACM* /dev/ttyUSB* 2>/dev/null

# 容器内
docker exec rm_dep ls -la /dev/ttyACM* /dev/ttyUSB* 2>/dev/null

# 容器启动时没 --device=$PX4_DEV,容器内看不到
# 解决: 重启容器时加 --device=/dev/ttyACM0
```

### watchdog log 不更新
```bash
docker exec rm_dep ps aux | grep rm_dep-watchdog
docker exec rm_dep cat /tmp/rm_dep-watchdog.log
```

### slam_to_mavros 时间戳不对 (PX4 LOCAL_POSITION 不跟 ODIN)
见 `docs/ODIN_INTEGRATION_TEST.md` 章节 0 "必读:ODIN 时间戳问题". 必加 `-p force_ros_stamp:=true`, launch_odin_px4.sh 已经默认加了.

### watchdog 启了 launch 但 PX4 LOCAL_POSITION 仍不动
最常见原因:**ODIN USB 还没挂进容器** (看 docker exec lsusb | grep 2207),重启容器时加 `--lidar odin` 自动挂.

## 文件清单

| 文件 | 位置 | 作用 |
|---|---|---|
| `scripts/launch_odin_px4.sh` | repo | 一键启动 (手动调试) |
| `scripts/rm_dep-autostart.sh` | repo + `/usr/local/bin/` | systemd 调,启容器 + 启 watchdog |
| `scripts/rm_dep-watchdog.sh` | repo + 容器内 `/opt/uav_ws/scripts/` | 容器内检测 PX4 USB 出现后调 launch |
| `scripts/rm_dep-stop.sh` | repo + `/usr/local/bin/` | systemd 调,停一切 |
| `scripts/rm_dep.service` | repo + `/etc/systemd/system/` | systemd unit file |