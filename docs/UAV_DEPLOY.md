# rm_ws 机载部署说明 — SLAM + MAVROS 一体化镜像 (v1.0, 挂载模式)

> 适用 `Dockerfile.uav` + `start_uav_container.sh` 整套。
> **跟 sim_ws 独立** — 这里是机载部署的独立项目, 源码从 sim_ws 拷过来, 之后只在这迭代.
> **挂载模式**: 源码不进镜像, 运行时 `-v rm_ws/src:/opt/uav_ws/src` 挂进去. 改代码 → 重启节点 → 生效.

## 1. 目录结构

```
rm_ws/
├── Dockerfile.uav                # 镜像: 系统依赖 + Livox-SDK2 (源码不 COPY)
├── src/                          # 运行时挂载进容器
│   ├── fast_lio/                 #   (宿主机改 → 容器内 symlink 立刻生效)
│   ├── livox_ros_driver2/
│   ├── slam_to_mavros/           # 自写的坐标转换节点
│   └── vision_msgs/
├── scripts/
│   ├── start_uav_container.sh    # docker run 入口 (自动挂 rm_ws/src)
│   ├── start_uav_gui.sh          # 容器内 Xvfb + x11vnc + noVNC
│   ├── uav_bringup.launch.py     # 顶层 launch (livox → fast_lio → 桥 → mavros)
│   ├── uav_entrypoint.sh         # 容器内 entrypoint 辅助
│   └── udev/99-livox.rules
└── docs/UAV_DEPLOY.md            # 本文档
```

## 2. 架构

```
Mid-360 ──网线──┐
                 ├── 小电脑 (host) ── Docker 容器 (--net host, -v rm_ws/src:/opt/uav_ws/src)
PX4 ──USB 串口──┘                          │
                                          ├─ livox_ros_driver2   : UDP 56301-56304 in
                                          ├─ fast_lio            : /Odometry
                                          ├─ slam_to_mavros      : /mavros/vision_pose/pose
                                          └─ mavros (px4.launch) : /dev/ttyUSB0 921600 out

地面站 ──WiFi/4G/Tailscale──→ 小电脑 (noVNC http://<ip>:6080/vnc.html)
```

## 3. 硬件接线

| 设备 | 接小电脑的什么口 | 备注 |
|------|-----------------|------|
| Mid-360 | 网线 (RJ45) | 默认 IP 192.168.1.1xx, 用 Livox Viewer 改 |
| PX4 FMU | USB 数据口 | `/dev/ttyUSB0` 默认, 921600 baud |
| (可选) 数传 | 另一 USB | 给地面站 QGC 用, 不进容器 |

> Mid-360 出厂默认 192.168.1.1xx (后两位随机)。先用 Livox Viewer 连上确认。

## 4. 一次性 build 镜像

在 dev 机上:

```bash
cd ~/rm_ws
docker build -f Dockerfile.uav -t uavsim:uav-v1.0 .
# 不需要 GUI (纯机载生产模式):
docker build -f Dockerfile.uav --build-arg WITH_GUI=no -t uavsim:uav-v1.0-nogui .
```

首次 build ~5-10min (拉 apt + 编译 Livox-SDK2, 不会再编 fast_lio 因为源码是 mount 的)。

> 国内网络如果下不动 GitHub, 给 docker build daemon 加代理或在 Dockerfile Livox-SDK clone 那行加 `https://gh-proxy.com/` 前缀。

## 5. 部署到小电脑

### 5.1 把源码 + 启动脚本同步到小电脑

把整个 `rm_ws/` 目录同步上去 (脚本会自动用 `$REPO_ROOT/src` 挂载):

```bash
rsync -avz --exclude='.git' --exclude='build' --exclude='install' --exclude='log' \
    ~/rm_ws/ uav@drone-host:~/rm_ws/
```

### 5.2 或者 docker save/load 镜像 (源码不依赖)

```bash
# dev 机
docker save uavsim:uav-v1.0 | gzip > uavsim-uav-v1.0.tar.gz
scp uavsim-uav-v1.0.tar.gz uav@drone-host:~/

# 小电脑
docker load < uavsim-uav-v1.0.tar.gz
# 注意: 还要把 rm_ws/src 也同步过去, 不然容器挂载空目录会 build 失败
```

## 6. 启动

### 6.1 基础启动 (前台)

```bash
cd ~/rm_ws
bash scripts/start_uav_container.sh --bringup \
    --lidar-ip 192.168.1.150 \
    --fcu-url /dev/ttyUSB0:921600
```

首次启动会看到 `[uav_entrypoint] first run, colcon build (this may take 5-10 min)` — 因为源码是 mount 进来的, 没有 `install/setup.bash`, entrypoint 自动 build.

启动后:
1. livox_ros_driver2 起来, `/livox/lidar` `/livox/imu` 有数据
2. fast_lio 起来, `/Odometry` `/cloud_registered` 有数据 (~2-3s 收敛)
3. slam_to_mavros 把 `/Odometry` 翻译成 `/mavros/vision_pose/pose`
4. mavros (px4.launch) 起来, 跟 PX4 握手成功 → `/mavros/state` 显示 `connected: true`

### 6.2 带 GUI (开发/调试, 浏览器看 rviz)

```bash
bash scripts/start_uav_container.sh --bringup-gui \
    --lidar-ip 192.168.1.150
```

容器内自动起 Xvfb + x11vnc + noVNC。在另一终端:

```bash
docker exec -it rm_dep \
    bash -lc "DISPLAY=:99 ros2 launch /opt/uav_ws/uav_bringup.launch.py with_rviz:=true"
```

浏览器打开 `http://<小电脑IP>:6080/vnc.html`，就能看到 rviz。

### 6.3 只启容器, 手动进

```bash
bash scripts/start_uav_container.sh
docker exec -it rm_dep bash
# 容器内手动:
ros2 launch /opt/uav_ws/uav_bringup.launch.py
```

### 6.4 停 / 看日志 / 看状态

```bash
bash scripts/start_uav_container.sh status
bash scripts/start_uav_container.sh logs -f
bash scripts/start_uav_container.sh stop
```

`status` 输出会包含 `/opt/uav_ws/src/` 挂载检查 + ROS topic 列表.

## 7. 迭代开发 (核心场景)

由于源码是 mount 进去的, 改代码几乎零成本:

### 7.1 改 .py 文件 (slam_to_mavros 等)

```bash
# 主机改 ~/rm_ws/src/slam_to_mavros/slam_to_mavros/slam_to_mavros_node.py
# 因为 --symlink-install, install 里直接软链回 src, .py 改动立刻生效
docker exec rm_dep bash -c \
    "pkill -f slam_to_mavros_node; sleep 1; \
     ros2 run slam_to_mavros slam_to_mavros_node &"
```

### 7.2 改 .yaml (外参等)

```bash
# 主机改 ~/rm_ws/src/slam_to_mavros/config/slam_to_mavros.yaml
# 因为 --symlink-install, 改动立刻生效, 重启节点即可
```

### 7.3 改 fast_lio 的 .cpp / .h

```bash
# 主机改 ~/rm_ws/src/fast_lio/src/laserMapping.cpp
# 需要在容器内 rebuild:
docker exec rm_dep bash -c \
    "cd /opt/uav_ws && colcon build --packages-select fast_lio --symlink-install"
# 然后重启 fast_lio 节点
```

### 7.4 改 launch / 新增节点

```bash
# 主机改 ~/rm_ws/scripts/uav_bringup.launch.py
# 因为 baked-in 到镜像了 (COPY 到 /opt/uav_ws/uav_bringup.launch.py)
# 改完只需重启 container:
bash scripts/start_uav_container.sh stop
docker build -f Dockerfile.uav -t uavsim:uav-v1.0 .   # 重 build 镜像
bash scripts/start_uav_container.sh --bringup
# 或: 临时用 docker cp 直接覆盖 (避免重 build):
docker cp scripts/uav_bringup.launch.py rm_dep:/opt/uav_ws/uav_bringup.launch.py
```

## 8. PX4 端参数 (必设)

> 用 QGroundControl → Vehicle Setup → Parameters 改, 改完 reboot。

```
SYS_HAS_GPS          0    # 室内, 没 GPS
EKF2_AID_MASK        24   # bit 3=vision position, bit 4=vision yaw
EKF2_EV_CTRL         15   # enable vision_pose + vision_yaw
EKF2_HGT_REF         3    # Vision as height reference
MAV_USEHILGPS        0
MAV_ODOM_LPF         0
```

如果用 PX4 v1.14+ 还要 (SERIAL 端口配置, 跟飞控型号有关):
```
MAV_1_CONFIG         TELEM 2   # 看你飞控接哪个口, USB 不需要这步
```

## 9. 飞行前 checklist

| # | 检查项 | 命令 / 现象 |
|---|--------|------------|
| 1 | Mid-360 上电, 网线灯亮 | — |
| 2 | `ping 192.168.1.150` 通 | 在小电脑 host 上 |
| 3 | PX4 USB 接好 | `ls /dev/ttyUSB*` |
| 4 | 容器起来 | `status` 子命令 |
| 5 | `/mavros/state` connected=true | `docker exec ... ros2 topic echo /mavros/state` |
| 6 | `/mavros/vision_pose/pose` 有数据 (50Hz) | `ros2 topic hz /mavros/vision_pose/pose` |
| 7 | QGC 显示 drone 在地图上, 不漂 | — |
| 8 | rviz 看到 SLAM 地图成形 | fast_lio `/cloud_registered` |
| 9 | 起飞前 drone 在地面静止 2-3 秒 | 让 EKF2 收敛 |
| 10 | 切 OFFBOARD, throttle stick 不动 drone 不掉 | 第一次试用手感 |

## 10. 故障排查

| 现象 | 排查 |
|------|------|
| mavros `connected: false` | 查 `dmesg \| grep tty`, USB 线/串口; 查 PX4 是否开机; `ros2 topic echo /mavros/state` |
| `/Odometry` 没数据 | `/livox/lidar` 有没有 → 没就是 Mid-360 IP 不对; 有就是 fast_lio 没收敛, 等 5s 或重启 |
| `/mavros/vision_pose/pose` 没数据 | `slam_to_mavros` 节点日志; `/Odometry` 有没有 |
| 容器启动后 entrypoint 报"colcon build failed" | 容器内 `cd /opt/uav_ws && colcon build` 看详细报错; 常见: apt 缺包 → 改 Dockerfile 加依赖 |
| rviz 黑屏 | noVNC URL 是 `/vnc.html` 不是 `/`; 端口 6080 docker run 时 `-p 6080:6080` 加了没 |
| fast_lio 漂 | 检查 `/livox/imu` 有没有; 检查 mid360.yaml 的 `extrinsic_T/R`; 检查 IMU 安装方向 |
| PX4 不接 vision pose | EKF2_AID_MASK 是不是 24; 重启 PX4 让参数生效 |
| 改了 .py 不生效 | 确认是 `--symlink-install` (Dockerfile 里已开); `ls -la /opt/uav_ws/install/slam_to_mavros/lib/slam_to_mavros/slam_to_mavros_node.py` 看是不是软链回 src/ |

## 11. 跟 sim_ws 的关系

rm_ws 跟 sim_ws 是两个独立项目:
- sim_ws/egg_ws: PX4 SITL 仿真, 主要用 Gazebo Harmonic 跑模拟飞行
- rm_ws: 真机部署, 用真实的 Mid-360 + PX4

两边都会引用 fast_lio / livox_ros_driver2 / slam_to_mavros, 但版本可独立演进. 当前 v1.0 的 rm_ws 直接从 sim_ws 拷贝 (git history 截止那一刻), 之后两边各自迭代.

## 12. 进一步扩展 (Roadmap)

- v1.1: 加 `point_fly/px4_offboard_bridge.py` (从 sim_ws 拷), 自动从 YAML 读航点起飞
- v1.2: 加 `slam_to_mavros` 的 aligned 模式 (用 IMU 做重力对齐 + 用磁力计做 yaw 对齐)
- v1.3: 加 ros2 bag 自动录制 (类似 `scripts/record_session.sh`)
- v1.4: 加 systemd unit, 小电脑上电自启