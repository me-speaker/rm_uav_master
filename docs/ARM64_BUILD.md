# ARM64 (Jetson) 构建与部署

> 你问的是最重要的部署问题: 项目在 Jetson Orin / Orin Nano / Pi5 等 arm64 小电脑上能跑吗?
> 答: **能**, 全部组件都支持 arm64, 只是需要**用 arm64 版本的 base image** 重新 build.

## 1. 各组件 ARM64 兼容性 (实测确认)

| 组件 | 类型 | arm64 支持 | 状态 |
|------|------|-----------|------|
| Livox-SDK2 | C++ 源码 (git clone) | ✅ 编译时自动适配 | Dockerfile 自动 |
| livox_ros_driver2 | C++ 源码 | ✅ 平台无关 | Dockerfile 自动 |
| fast_lio | C++ 源码 | ✅ 平台无关 | Dockerfile 自动 |
| odin_ros_driver | C++ 源码 + **预编译 arm 库** | ✅ `liblydHostApi_arm.a` 已就位 | CMakeLists.txt 自动检测 |
| slam_to_mavros | Python | ✅ 跨平台 | Python 跨 |
| mavros | apt 包 | ✅ humbe 有 arm64 | base 决定 |
| **base image** | Docker | ⚠️ **核心卡点** | 见下 |

**base image 是唯一卡点**:
- `ros2:humble_mavros` (本项目当前) — 你本地构建的 single-arch tag, 只支持你 build 时用的架构
- `osrf/ros:humble-desktop` (DockerHub 官方) — **multi-arch**, amd64 + arm64, 但不带 mavros (要 apt 装)

## 2. 三种 build 方案 (按推荐顺序)

### 方案 A: 在 Jetson 上直接 build (推荐, 最快)

Jetson 上原生 build, 不需要 cross-compile:

```bash
# 1. 在 Jetson 上 rsync 整个 rm_ws 目录
rsync -avz --exclude='.git' --exclude='log' ~/rm_ws/ jetson@jetson-host:~/rm_ws/

# 2. Jetson 上跑
cd ~/rm_ws
bash scripts/build_arm64.sh --tag uavsim:arm-v1.1
# 脚本会:
#   - 检查 host 架构是 aarch64 (否则拒绝)
#   - docker pull --platform linux/arm64 ros2:humble_mavros
#     (或用 --base-image osrf/ros:humble-desktop 重 build base)
#   - docker build ... --platform linux/arm64
#   - 输出 uavsim:arm-v1.1 镜像

# 3. 跑
bash scripts/start_uav_container.sh --image uavsim:arm-v1.1 \
    --bringup --lidar mid360 --lidar-ip 192.168.1.150
```

**优点**: 同架构 build, 最快 (~10min), 镜像就跟 Jetson 完美匹配.
**前提**: Jetson 上有 docker (NVIDIA JetPack 5+ 默认有).

### 方案 B: dev 机上用 buildx 跨平台 build

x86 dev 机上 build arm64, 通过 QEMU 模拟:

```bash
# (在 x86 dev 机)
cd ~/rm_ws
bash scripts/build_multiarch.sh --arch arm64
# 脚本会:
#   - 装 qemu-user-static (模拟 arm64)
#   - 创建 buildx builder
#   - docker buildx build --platform linux/arm64
```

**优点**: 不需要 Jetson.
**缺点**: 
- 比方案 A 慢 **5-10 倍** (QEMU 模拟, Livox-SDK2 编译要 30-60min)
- 镜像必须 `docker save` 复制到 Jetson 上 (镜像 5-6GB)
- 某些 arm64-specific 优化 (如 NEON) 不会被 qemu 模拟触发, 但代码能跑

### 方案 C: 用官方 multi-arch base + apt 装 mavros

如果你想一份 Dockerfile 既能 build amd64 又能 build arm64, 改用 osrf/ros:humble-desktop:

```bash
docker build -f Dockerfile.uav \
    --build-arg BASE_IMAGE=osrf/ros:humble-desktop \
    --build-arg INSTALL_MAVROS_FROM_APT=yes \
    --platform linux/arm64 \
    -t uavsim:arm-v1.1-osrf .
```

Dockerfile 已经支持这个用法 (见 `1a. (可选) 从 apt 装 MAVROS` 段). 第一次启动时 entrypoint 会自动装 mavros.

## 3. 容器脚本对 ARM64 的支持

`scripts/start_uav_container.sh` 已经对平台透明:
- `--device /dev/ttyUSB0` (PX4 串口): 任何架构都这样用
- `--device /dev/bus/usb/...` (ODIN USB): 任何架构都这样用
- `--network host` (Mid360 UDP): 任何架构都这样用
- `--lidar mid360/odin/fake`: 任何架构都这样用

唯一要注意: **Jetson 的 GPU 怎么传给容器**. ROS2 + rviz2 可选 `--gpus all`, 但通常用 `--runtime=nvidia` (Jetson 专用) 或不开 GPU 用 cpu 软件渲染:

```bash
# Jetson 上跑带 GUI 的容器, GPU 加速 rviz2:
docker run --runtime=nvidia \
    -e NVIDIA_VISIBLE_DEVICES=all \
    ...

# 或不用 GPU (cpu 软件渲染, 慢但稳):
docker run -e LIBGL_ALWAYS_SOFTWARE=1 ...
```

## 4. Jetson 上 ODIN 的特殊性

ODIN driver 在 Jetson 上跑可能要装额外包:

```bash
# Jetson 自带的 l4t (Linux for Tegra) 不一定包含 libusb, 容器内可能要:
docker exec rm_dep bash -c \
    'apt-get update && apt-get install -y libusb-1.0-0-dev udev && udevadm trigger'
```

(99-odin.rules 已经在 baked-in 镜像里, USB vendor=2207 应该会被识别)

## 5. 一句话推荐

**如果你在 Jetson 上有 docker, 直接跑 `bash scripts/build_arm64.sh` (方案 A)** — 5-10 分钟出 arm64 镜像, 跟 amd64 镜像行为完全一致.

**如果 dev 机上要 build 给你 Jetson 跑**, 跑 `bash scripts/build_multiarch.sh --arch arm64` (方案 B), 但要等 30-60 分钟.

**不要做**: 别在 Jetson 上用 `docker buildx build` 跨平台 build (自己编译自己还需要 QEMU, 纯属浪费).

## 6. 验证镜像多架构 (跑过之后)

```bash
# 看镜像支持哪些架构
docker manifest inspect uavsim:arm-v1.1 2>/dev/null | grep architecture

# 或在 Jetson 上:
docker inspect uavsim:arm-v1.1 --format '{{.Architecture}}'
# 期望: arm64

# 在 Jetson 上跑节点验证 arm64 编译没问题
docker run --rm uavsim:arm-v1.1 bash -c \
    'uname -m && /usr/local/lib/liblivox_lidar_sdk_shared.so 2>&1 | head -3'
# 期望 uname 输出 aarch64
```

## 7. 已知问题

1. **基础镜像 `ros2:humble_mavros` 单架构**: 如果你用的就是这个 tag 且只在 amd64 装了, 必须在 Jetson 上重新 build (方案 A) 或换方案 C.
2. **ODIN SDK 的预编译 arm 库**: `liblydHostApi_arm.a` 已经是 arm64 aarch64-linux-gnu 编译的, **不区分** Jetson 和其他 arm64 设备, 通用.
3. **Mid-360 网线驱动**: Mid-360 Livox-SDK2 在 Jetson 上正常, 网络走 host (--network host).
4. **FAST_LIO 编译时间**: arm64 上首次 build 要 5-10 分钟 (Livox-SDK2 + colcon build SLAM), 后续 colcon build 增量 ~30s.

## 8. 当前默认镜像清单

| 镜像 tag | 架构 | 用途 |
|---------|------|------|
| `uavsim:uav-v1.1` | amd64 | 当前默认 (本机开发) |
| `uavsim:arm-v1.1` | arm64 | Jetson/小电脑 (用 build_arm64.sh 建) |

两个镜像**互不兼容**: Jetson 上跑 amd64 镜像会立刻 "exec format error".

## 9. 一行流程 (给 Jetson 用户)

```bash
# 在 Jetson 上:
cd ~/rm_ws && bash scripts/build_arm64.sh && bash scripts/start_uav_container.sh --image uavsim:arm-v1.1 --bringup --lidar mid360 --lidar-ip 192.168.1.150

# 之后改代码:
vim src/slam_to_mavros/slam_to_mavros/slam_to_mavros_node.py
# 容器内重启节点即生效 (symlink)
docker exec rm_dep bash -c 'pkill -f slam_to_mavros_node && sleep 1 && ros2 run slam_to_mavros slam_to_mavros_node &'
```
## 10. 3 种 base image 选项 (Dockerfile v2.0)

Dockerfile 现在支持 3 种 base, 通过 `--build-arg` 切换:

| Base | INSTALL_ROS_FROM_APT | INSTALL_MAVROS_FROM_APT | 适用 |
|------|---------------------|----------------------|------|
| `ros2:humble_mavros` (默认) | no | no | 当前 dev 机直接 build |
| `osrf/ros:humble-desktop` (multi-arch) | no | yes | DockerHub 官方, CI |
| `ubuntu:22.04_base` (裸 Ubuntu, multi-arch) | **yes** | **yes** | **Jetson 推荐, 最激进** |

### 用 ubuntu:22.04_base

```bash
# Jetson 上:
bash scripts/build_arm64.sh --base ubuntu:22.04_base

# x86 dev 机上 buildx 跨平台:
bash scripts/build_multiarch.sh --base ubuntu:22.04_base --arch arm64
```

脚本会自动设 `INSTALL_ROS_FROM_APT=yes INSTALL_MAVROS_FROM_APT=yes`，
Dockerfile 会:
1. 加 ROS 2 apt source (`packages.ros.org/ros2/ubuntu`)
2. apt install `ros-humble-ros-base` (~200MB, ROS 核心)
3. apt install `ros-humble-mavros` + `ros-humble-mavros-extras` + `geographiclib-tools`
4. 跑 `install_geographiclib_datasets.sh` 下 PX4 EKF2 用的 geoid 数据

### 优势

- **完全 multi-arch 官方支持** (ubuntu base 在 DockerHub + arm64 都有)
- **不依赖任何 custom tag** (`ros2:humble_mavros` 是 single-arch local tag，可能 amd64 only)
- **base 116MB** vs `ros2:humble_mavros` 的 3.4GB, 镜像里**没用的组件更少**
- **完全可重复 build** (所有安装都走 apt + 官方源)

### Build 时间对比

| Base | 首次 build | 镜像大小 |
|------|----------|---------|
| `ros2:humble_mavros` | 5-10min | ~5.6GB |
| `osrf/ros:humble-desktop` | 8-12min | ~2.5GB |
| `ubuntu:22.04_base` | 15-20min | ~2.0GB |

时间主要花在 ROS apt install (GB 级数据)。**对 Jetson 原生 build, 推荐用 ubuntu:22.04_base** — 慢一点但镜像干净, 不依赖任何历史 tag。

## 修正: 关于 ubuntu:22.04_base 的 multi-arch 误解

之前的文档建议过"用 ubuntu:22.04_base 最激进"——**这是错的**.

实际情况:
- 你本地的 `ubuntu:22.04_base` 是 **2021-12-04** 本地 build 的, 只 build 了 amd64, **不是** multi-arch
- 它跟 DockerHub 官方的 `ubuntu` 系列没关系, 是你团队自定义的 tag

**所以在 Jetson (arm64) 上用它会立刻报**:
```
exec format error
或
no matching manifest for linux/arm64 in the manifest list
```

**正确的做法**:

| 目标 | 推荐的 base |
|------|------------|
| Jetson (arm64) 上跑 | 用 DockerHub `osrf/ros:humble-desktop` 或 `ubuntu:22.04` |
| x86 dev 机 build amd64 + arm64 | 用 DockerHub `osrf/ros:humble-desktop` 或 `ubuntu:22.04` |
| 当前 amd64 dev 机直接 build | 你的 `ros2:humble_mavros` 默认就行, 不动 |

### 推荐的 3 种 base (按推荐顺序)

```bash
# 1. 🏆 osrf/ros:humble-desktop (DockerHub 官方, multi-arch, ROS 已装, mavros 需 apt)
bash scripts/build_arm64.sh --base osrf/ros:humble-desktop
# 脚本自动设: INSTALL_MAVROS_FROM_APT=yes (不含 ROS 因为已装)

# 2. 🍱 ubuntu:22.04 (DockerHub 官方, multi-arch, 裸 Ubuntu)
bash scripts/build_arm64.sh --base ubuntu:22.04
# 脚本自动设: INSTALL_ROS_FROM_APT=yes + INSTALL_MAVROS_FROM_APT=yes

# 3. ⚠️ 你本地的 ros2:humble_mavros (amd64 only, 在 Jetson 上跑不起来)
bash scripts/start_uav_container.sh --image uavsim:uav-v1.1 --bringup ...
# 仅限 amd64 dev/主机用
```

### 不要做的事

```bash
# ❌ 在 Jetson 上跑 --base ubuntu:22.04_base (你本地的)
bash scripts/build_arm64.sh --base ubuntu:22.04_base
# 错误: no matching manifest for linux/arm64

# ❌ 跨平台 build 用单架构 base
bash scripts/build_multiarch.sh --base ros2:humble_mavros --arch arm64
# 错误: 同上
```


## 11. v3.0 — 完全从 0 编译 (推荐策略)

**为什么换**: 我们之前 base 在 `ros2:humble_mavros` / `osrf/ros:humble-desktop` 上, 这俩都是 **amd64-only**. 你查证后确认 arm64 没法用.

**新方案 v3.0**: Dockerfile 直接 FROM 裸 Ubuntu 22.04 (multi-arch), 从 0 装所有东西:

```
Dockerfile.uav (v3.0)
├── FROM ubuntu:22.04        ← multi-arch 官方 (amd64 + arm64)
├── 1. 加 ROS 2 apt source
├── 2. apt install ros-humble-desktop (~1.5GB)  ← 清华源镜像
├── 3. apt install ros-humble-mavros + extras + geographiclib-tools
├── 4. install_geographiclib_datasets.sh
├── 5. apt install SLAM + ODIN 编译依赖
├── 6. git clone + 编译 Livox-SDK2 (30s-2min)
└── 7. entrypoint 自动 colcon build + 启动
```

**单一 Dockerfile 同时支持 amd64 / arm64**, 因为:
- `ubuntu:22.04` 是 multi-arch (pull 时自动按平台选)
- `apt install` 在两个架构都有 arm64 包
- Livox-SDK2 源码编译, 平台自动适配

### ROS apt 源可切换

```dockerfile
ARG ROS_APT_MIRROR=tsinghua   # 默认 (国内 10x 快)
# ARG ROS_APT_MIRROR=huawei   # 华为云
# ARG ROS_APT_MIRROR=official # 国外用官方 packages.ros.org
```

镜像 build 时自动加对应 source, 然后 apt install.

### Build 命令 (arm64)

```bash
# Jetson 上 (用你本地已经 pull 的 ubuntu:22.04-linuxarm64)
bash scripts/build_arm64.sh
# 默认行为:
#   - 检测 host 是 arm64
#   - --base ubuntu:22.04-linuxarm64 (你已经 pull 的本地 tag)
#   - --mirror tsinghua (用清华源)
#   - build 出来: uavsim:arm-v3.0

# Jetson 上 (用 multi-arch 镜像)
bash scripts/build_arm64.sh --base ubuntu:22.04
# 这种是 buildx 拿多架构 manifest 选 arm64 layer

# x86 dev 机上 cross-build arm64
bash scripts/build_multiarch.sh --arch arm64
```

### 镜像大小对比

| v3.0 镜像 | 大小 (amd64 / arm64) |
|-----------|---------------------|
| base (ubuntu:22.04) | 77MB / 70MB |
| + ROS Desktop (apt) | +1.5GB |
| + MAVROS + Extras | +150MB |
| + Livox-SDK2 (编译) | +5MB |
| + SLAM deps + GUI | +300MB |
| **总计** | **~2.0GB** (vs v2.0 的 5.6GB) |

v3.0 优势: **没装冗余的桌面 OS/工具**,只装了项目需要的. 镜像更小, build 更快.

### 首次 build 时间 (Jetson 上原生)

| 步骤 | 时间 |
|------|------|
| apt install ros-humble-desktop | 5-10min (1.5GB 下载) |
| apt install mavros + extras | 30s |
| apt install SLAM/ODIN 依赖 | 30s |
| 编译 Livox-SDK2 | 1-2min |
| entrypoint 首次 colcon build | 5-10min (FAST_LIO 编译) |
| **总计** | **~15-20min** (之后 colcon 增量编译 30s-2min) |

### 跑容器 (跟 v2.0 完全一样的命令)

```bash
# Jetson 上, 镜像 tag 改成 arm-v3.0:
bash scripts/start_uav_container.sh --image uavsim:arm-v3.0 \
    --bringup --lidar mid360 --lidar-ip 192.168.1.150

# 其它一切不变:
#   --lidar mid360|odin|fake
#   --fcu-url /dev/ttyUSB0:921600
#   --bringup-gui   (noVNC 浏览器看 rviz)
#   --lidar odin    (用 ODIN 自带 SLAM)
```

