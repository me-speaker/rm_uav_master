# rm_ws — 机载无人机 SLAM+MAVROS 部署项目

> 本文档给未来的 Claude / 其他 AI 工具读, 用来快速理解项目.
> 用户: speaker (speaker@example.com)

## 一句话
无人机真机部署项目: Fast-LIO + ODIN/Mid-360 雷达 + PX4 飞控, 全部 docker 化.

## 项目位置
- 源码: `~/rm_ws/` (实际 `/mnt/sda/sjj_ws/rm_ws/`)
- 跟 sim_ws 并列, **独立项目**. sim_ws 是 SITL 仿真 (Gazebo), rm_ws 是真机

## 目录结构

```
rm_ws/
├── Dockerfile.uav           # 镜像构建 (v3.0 from-scratch, multi-arch)
├── src/                     # 运行时挂载到容器, 改代码即时生效
│   ├── fast_lio/            # C++ SLAM (~35MB)
│   ├── livox_ros_driver2/   # Mid-360 driver
│   ├── odin_ros_driver/     # ODIN1 driver (vendor 2207:0019 USB)
│   ├── slam_to_mavros/      # ⭐ 自写: /Odometry → /mavros/vision_pose/pose
│   └── vision_msgs/
├── scripts/                 # 主机跑
│   ├── build_native.sh      # ⭐ 同架构 build (amd64 host 跑出 amd64, arm64 host 跑出 arm64)
│   ├── build_arm64.sh       # 别名/历史 (== build_native.sh)
│   ├── build_multiarch.sh   # 跨平台 (需 qemu)
│   ├── start_uav_container.sh   # docker run 入口
│   ├── launch_slam.sh       # 纯 SLAM (livox + fast_lio)
│   ├── launch_odin.sh       # 纯 ODIN
│   ├── launch_uav.sh        # 全链路 (--lidar mid360|odin)
│   ├── launch_uav_gui.sh    # + 浏览器 noVNC
│   ├── launch_test_with_px4.sh  # ⭐ 无雷达时 fake odom, 验证 PX4 链路
│   ├── stop_launch.sh       # 停任意模式
│   ├── start_uav_gui.sh     # Xvfb + x11vnc + noVNC
│   ├── uav_bringup.launch.py   # ros2 launch 顶层 (lidar source + mavros + bridge)
│   └── uav_entrypoint.sh    # 容器 entrypoint (source ROS + 自动 build)
├── tests/                   # 验证脚本
│   ├── test_smoke.sh
│   ├── test_symlink.sh
│   └── test_endpoints.sh
├── docs/
│   ├── UAV_DEPLOY.md        # 部署手册 (PX4 端 + 飞行前 checklist)
│   ├── PX4_ONLY_TEST.md     # ⭐ 无雷达 + 有 PX4 时的测试手册
│   └── ARM64_BUILD.md       # arm64 build 文档
└── tests/test_*.sh          # smoke + symlink + endpoints 测试
```

## 关键设计决策 (必读)

### 1. v3.0 Dockerfile 从 0 编译
**不要用** `ros2:humble_mavros` 或 `osrf/ros:humble-desktop` 作 base (amd64 only).
v3.0 直接 `FROM ubuntu:22.04` (multi-arch 官方), 从 apt 装:
- ros-humble-desktop (~1.5GB)
- ros-humble-mavros + ros-humble-mavros-extras + geographiclib-tools
- SLAM/Odin deps (eigen, pcl, glog, gflags, libusb, OpenCV, ...)
- Livox-SDK2 v1.3.1 (git clone + cmake install 到 /usr/local)

清华源装 ROS (国内 10x 快): `ARG ROS_APT_MIRROR=tsinghua`

### 2. 挂载模式 (不 baked-in 源码)
- 容器 entrypoint 检测 `/opt/uav_ws/install/setup.bash`, 不存在就 `colcon build --symlink-install`
- `--symlink-install` 让 `install/` 里直接软链回 `src/`, 改 `.py` 不需要 rebuild
- 改 `fast_lio/*.cpp` 需要 `colcon build --packages-select fast_lio`

### 3. 三种 lidar source, 同一 launch
`uav_bringup.launch.py lidar:=` 三选一:
- `mid360` (默认): livox_ros_driver2 + fast_lio
- `odin`: host_sdk_sample (ODIN 自带 SLAM, /odin1/odometry)
- `fake`: fake_odom_publisher (无雷达验证 PX4 链路用)
都由 launch arg `--lidar` 控制, GroupAction 互斥.

### 4. 算法核心: `slam_to_mavros_node`
- 输入: `/Odometry` 或 `/odin1/odometry` (FAST-LIO / ODIN 输出)
- 输出: `/mavros/vision_pose/pose` + `/mavros/vision_speed/speed_twist`
- TF: 静态 `map → odom` (identity), 动态 `odom → base_link`
- 用 lidar_to_base 外参把 SLAM 输出 (云台坐标系) 转到机体坐标系
- 不引用 `tf_transformations` apt 包 (Ubuntu 22.04 没有), 自实现 `quaternion_from_euler` / `quaternion_multiply`

### 5. ODIN USB
- vendor 2207, product 0019 (Fuzhou Rockchip)
- udev rule `99-odin.rules` baked-in 镜像
- ODIN driver 自带 arm64 预编译库 `liblydHostApi_arm.a`, CMakeLists.txt 自动检测 arch
- 启动时 `--device=/dev/bus/usb/...` 或 `lsusb` 自动找

## Build & Run 一览

```bash
# 在 host 跑 (任意架构, 自动同架构 build)
bash scripts/build_native.sh
# 输出 uavsim:amd64-v3.0 (amd64 host) 或 uavsim:arm-v3.0 (arm64 host)

# 跨架构 (amd64 dev → arm64 image, 需 qemu, 30-60min)
bash scripts/build_multiarch.sh --arch arm64

# 启动容器 (idle 模式, 不跑 launch)
bash scripts/start_uav_container.sh

# 全链路 + Mid-360
bash scripts/start_uav_container.sh --bringup \
    --lidar mid360 --lidar-ip 192.168.1.150 \
    --fcu-url /dev/ttyUSB0:921600

# 全链路 + ODIN
bash scripts/start_uav_container.sh --bringup \
    --lidar odin --fcu-url /dev/ttyUSB0:921600

# PX4-only 测试 (无雷达)
bash scripts/launch_test_with_px4.sh --fcu-url /dev/ttyUSB0:921600

# 浏览器看 rviz (noVNC)
bash scripts/start_uav_container.sh --bringup-gui --lidar mid360 --lidar-ip 192.168.1.150
# 浏览器 http://<host-ip>:6080/vnc.html
```

## 迭代开发 (改代码 → 生效)

```bash
# 改 .py (slam_to_mavros / fake_odom_publisher)
vim src/slam_to_mavros/slam_to_mavros/slam_to_mavros_node.py
docker exec rm-uavsim pkill -f slam_to_mavros_node
docker exec -d rm-uavsim bash -c \
    'source /opt/uav_ws/install/setup.bash && \
     nohup ros2 run slam_to_mavros slam_to_mavros_node > /tmp/stm.log 2>&1 &'

# 改 fast_lio .cpp / .h
vim src/fast_lio/src/laserMapping.cpp
docker exec rm-uavsim bash -c \
    'cd /opt/uav_ws && colcon build --packages-select fast_lio'
docker exec rm-uavsim pkill -f fastlio_mapping
# (bringup 重启它, 或手动: ros2 launch fast_lio mapping.launch.py)

# 改 .yaml 配置
vim src/slam_to_mavros/config/slam_to_mavros.yaml
docker exec rm-uavsim pkill -f slam_to_mavros_node
# (同上重启节点, symlink 让改动立刻有效)
```

## PX4 端必设参数 (在 QGC)

```
SYS_HAS_GPS          0    # 室内
EKF2_AID_MASK        24   # bit 3 vision position, bit 4 vision yaw
EKF2_EV_CTRL         15   # vision_pose + vision_yaw
EKF2_HGT_REF         3    # Vision as height
MAV_USEHILGPS        0
```

## 网络/沙箱限制 (本机环境)

- `docker.io` 不通, 所以 DockerHub 的 multi-arch manifest 拉不到
- `sudo apt` 不让装 (sandbox 锁)
- 没有 `qemu-user-static`, 无法 cross-build
- 必须 **在 Jetson 上原生 build**, 或在能上网的 amd64 机器上 build
- 本机已有的镜像 (来自历史 build): `ros2:humble_mavros` (amd64), `ubuntu:22.04_base` (amd64)
- 本机刚 pull: `ubuntu:22.04-linuxarm64` (arm64)

## 已知坑

1. **apt 包冲突已解决**: ODIN 需要 libusb/libssl/OpenCV/visualization-msgs/message-filters/image-transport/cv-bridge/rosidl-default-generators, 全部已加到 Dockerfile
2. **boost 1.74 warning**: fast_lio / livox_ros_driver2 / odin_ros_driver build 时有 `[pragma message: ... Bind placeholders deprecated]`, 是 boost 自己打印的, 不是错误, colcon 把 stderr 出现就标了
3. **rclpy shutdown 警告**: slam_to_mavros_node 关掉时偶尔输出 `rcl_shutdown already called`, 因为 timeout 杀进程, 已知
4. **entrypoint 首次 build 慢**: 第一次启动容器要 1-2min colcon build (FAST_LIO 编译)
5. **ODIN SDK 预编译库**: `liblydHostApi_arm.a` 是 aarch64-linux-gnu, Jetson Orin / Pi5 都通用
6. **Livox-SDK2 网络**: Dockerfile 用 gh-proxy.com 镜像 fallback, 国内也能 clone

## 跟其他项目的关系

- `sim_ws/egg_ws/` - SITL 仿真 (PX4 SITL + Gazebo). `ros2:humble_mavros` 是 sim_ws 用的 base
- `uf_ws/` - 用户第三个项目, 与本项目无关 (UAVFormer)

## 验证清单 (改动后跑一遍)

```bash
# 1. 镜像 build OK
bash scripts/build_native.sh

# 2. 容器能起, entrypoint 自动 build
bash scripts/start_uav_container.sh
sleep 90  # 等 build
docker exec rm-uavsim test -f /opt/uav_ws/install/setup.bash && echo "✅ build done"

# 3. 节点注册
docker exec rm-uavsim bash -c 'source /opt/uav_ws/install/setup.bash && \
    ros2 pkg list | grep -E "slam_to_mavros|fast_lio|livox_ros_driver2|odin_ros_driver|mavros"'

# 4. slam_to_mavros 节点可独立启动
bash scripts/start_uav_container.sh exec bash -c \
    'source /opt/uav_ws/install/setup.bash && \
     timeout 4 ros2 run slam_to_mavros slam_to_mavros_node'

# 5. fake + slam_to_mavros 联动 (验证 PX4 链路)
docker exec -d rm-uavsim bash -c \
    'source /opt/uav_ws/install/setup.bash && \
     nohup ros2 run slam_to_mavros fake_odom_publisher --ros-args -p motion_mode:=circle > /tmp/fake.log 2>&1 &'
docker exec -d rm-uavsim bash -c \
    'source /opt/uav_ws/install/setup.bash && \
     nohup ros2 run slam_to_mavros slam_to_mavros_node > /tmp/sm.log 2>&1 &'
sleep 3
docker exec rm-uavsim bash -c 'source /opt/uav_ws/install/setup.bash && \
    timeout 2 ros2 topic echo /mavros/vision_pose/pose --field header.frame_id'
# 期望: map
```

## 一些 commit 时刻的纠错

- 之前几次我推荐 `ros2:humble_mavros` 或 `osrf/ros:humble-desktop` 当 base —— **都是 amd64 only**, 实测发现, 不能 arm build
- 推荐过 `ubuntu:22.04_base` 是 multi-arch —— **错**, 是你本地 4 年前的单架构 amd64
- 最终方案 v3.0: `FROM ubuntu:22.04` from-scratch, 任何架构同源

## 进一步扩展 (Roadmap)

未做, 按需:
- v3.1: 加 `point_fly` 航点飞行 (从 sim_ws 拷, 跟 `slam_to_mavros` 集成)
- v3.2: `slam_to_mavros_node` 加 aligned 模式 (用 IMU 重力对齐 + 磁力计 yaw 对齐)
- v3.3: ros2 bag 自动录制
- v3.4: systemd unit (小电脑上电自启)
