# ega-uav-slam — 机载无人机 SLAM + PX4 + mavros 部署项目

## 一句话

机载无人机 SLAM + PX4 EKF2 vision fusion 完整部署栈. 雷达 → SLAM → mavros → PX4, 上电自启.

## 架构

```
[ODIN1 雷达 (USB vendor 2207:0019)]    [Mid-360 / Velodyne (可选)]
        ↓                                       ↓
[ODIN SLAM driver / fast_lio]              [livox_ros_driver2]
        ↓ nav_msgs/Odometry                        ↓
        └─────────────┬─────────────────────────────┘
                      ↓
        [slam_to_mavros_node (自写, 带 vision_pose patch)]
                      ↓
        [/mavros/vision_pose/pose]
                      ↓ MAVLink
              [PX4 飞控]
                      ↓
            EKF2 vision fusion
                      ↓
            [PX4 飞控驱动电机]
```

**核心数据流**: ODIN SLAM 算位姿 → slam_to_mavros 重打包到 mavros → PX4 EKF2 vision fusion 跑飞机.

## 目录结构

```
rm_ws/
├── Dockerfile.uav              # 运行时镜像 (drone 用, runtime-only)
├── Dockerfile.uav.build        # build 镜像 (dev 端用, extends runtime)
├── .github/workflows/          # CI: 自动 build 两个镜像 → ghcr
├── src/                        # ROS workspace src
│   ├── mavros/                 # submodule, 带 vision_pose patch
│   ├── odin_ros_driver/        # ODIN SDK driver (host_sdk_sample)
│   ├── fast_lio/               # SLAM 引擎
│   ├── livox_ros_driver2/      # livox 雷达驱动
│   ├── slam_to_mavros/         # ⭐ 自写: SLAM odometry → mavros vision_pose bridge
│   ├── vision_msgs/            # std msgs
│   ├── Micro-XRCE-DDS-Agent/   # XRCE-DDS 桥 (备选通信, 当前链路不用)
├── scripts/                    # 启动 / 部署 / 验证
│   ├── build_install.sh        # ⭐ dev: 跑 build 镜像 colcon build 出 install/
│   ├── build_native.sh         # dev: build runtime 镜像
│   ├── start_uav_container.sh  # 容器启动器 (systemd 调)
│   ├── deploy_to_drone.sh      # dev: 打包镜像 + install/ 推 drone
│   ├── sync_to_drone.py        # dev: paramiko 推代码 + 重启
│   ├── verify_autostart.py     # 8 项自启验证 (drone 端全状态检查)
│   ├── rm_dep-{autostart,watchdog,stop}.sh  # systemd 自启链路
├── dockerfiles/                # 镜像 build 辅助
│   ├── mavros-patch.diff       # vision_pose subscription patch (humble rclcpp bug fix)
│   └── geographiclib-datasets/ # PX4 EKF2 vision fusion 必须
├── docker-compose.dev.yml      # dev 端调试容器 (mount + device + env)
├── .env.example                # .env 模板 (compose 参数覆盖, 不含敏感)
├── docs/                       # 详细文档 (按需看)
│   ├── UAV_DEPLOY.md           # 部署手册 (PX4 端 + 飞行前 checklist)
│   ├── PX4_ONLY_TEST.md        # 无雷达 + 有 PX4 时的测试手册
│   ├── AUTOSTART.md            # systemd 自启详解
│   ├── ARM64_BUILD.md          # arm64 (Jetson / Pi5) build 细节
│   └── ODIN_INTEGRATION_TEST.md # ODIN 真机集成测试
├── tests/                      # 烟雾测试
└── CLAUDE.md / HANDOVER.md     # 详细文档 (见下)
```

## 文档地图

- **[HANDOVER.md](./HANDOVER.md)** — 当前进度 + 卡点 + 下一步 (活文档, 看这个先)
- **[docs/UAV_DEPLOY.md](docs/UAV_DEPLOY.md)** — 部署/飞行前 checklist
- **[docs/PX4_ONLY_TEST.md](docs/PX4_ONLY_TEST.md)** — 无 ODIN 时怎么验证 PX4 链路
- **[docs/AUTOSTART.md](docs/AUTOSTART.md)** — systemd Type / watchdog 详解
- **[docs/ARM64_BUILD.md](docs/ARM64_BUILD.md)** — Jetson Orin Nano / Pi5 build 指南
- **[docs/ODIN_INTEGRATION_TEST.md](docs/ODIN_INTEGRATION_TEST.md)** — ODIN 真机测试流程

## Docker 镜像 (CI 自动 build → ghcr.io)

| Image | 用途 | Tag |
|---|---|---|
| `ega-uav-runtime` | drone 上跑的 runtime 镜像 | `runtime-v1.0-stable`, `latest`, `<sha>` |
| `ega-uav-build` | dev 端 build colcon 用 (FROM runtime + build tools + vendor) | `build-v1.0-stable`, `latest`, `<sha>` |

```bash
# drone 端
docker pull ghcr.io/${owner}/ega-uav-runtime:runtime-v1.0-stable

# dev 端
docker pull ghcr.io/${owner}/ega-uav-build:build-v1.0-stable
docker run --rm -v $(pwd):/opt/uav_ws ghcr.io/${owner}/ega-uav-build:build-v1.0-stable \
    bash scripts/build_install_inner.sh
```

CI workflow: `.github/workflows/docker-build.yml` (拆 2 job, dev depends on runtime)

## 一句话命令 cheat sheet

### dev 端 (arm64 主机)

```bash
# 1. build runtime image (改 Dockerfile 后)
bash scripts/build_native.sh --tag ega-uav:runtime-v1.0

# 2. 一次性 build + install/ (产物 ~/rm_ws/install/setup.bash)
bash scripts/build_install.sh

# 3. 推 drone (image + install + src)
bash scripts/deploy_to_drone.sh <user>@<drone-ip>

# 4. 修改 src/ 后只推代码 + 重启
python3 scripts/sync_to_drone.py <user>@<drone-ip> -k    # Python 改
python3 scripts/sync_to_drone.py <user>@<drone-ip> -r -k # 改 launch / setup.py
```

### dev 端用 docker-compose 调试

```bash
cp .env.example .env   # 可选, 改 LIDAR / FCU_URL / IP

# 后台起 (跟 systemd 等效)
docker compose -f docker-compose.dev.yml up -d

# 进容器调试
docker compose -f docker-compose.dev.yml exec rm_dep bash

# 看 watchdog + launch 日志
docker compose -f docker-compose.dev.yml logs -f

# 停
docker compose -f docker-compose.dev.yml down
```

`docker-compose.dev.yml` 把 mount / device / network / ROS env 集中声明了,
不用每次手写长 docker run 命令. drone 端 systemd 链路 (`rm_dep.service`) 不动.

### drone 端

```bash
sudo systemctl status rm_dep.service  # service active + container up
docker exec rm_dep bash -c "ros2 topic list | grep odin1"  # ODIN 数据
docker exec rm_dep bash -c "ros2 topic hz /mavros/vision_pose/pose"  # PX4 fusion
```

### 调试

```bash
# 进容器调试
docker exec -it rm_dep bash

# 看 watchdog 日志 (drone)
sudo tail -f /var/log/uav/watchdog-$(date +%Y%m%d).log

# 8 项自启验证
python3 scripts/verify_autostart.py <user>@<drone-ip>
```

## 关键技术决策

| 决策 | 原因 |
|---|---|
| **runtime 不装 mavros-extras** | apt 装的 mavros-extras 没 vision_pose patch; src build 的 mavros_extras 带 patch |
| **build image FROM runtime** | 复用 runtime layer 节省 build time (10-15min → 5min) |
| **mavlink / urdfdom / angles 用 apt** | apt 装的 vendor meta-pkg 自带 colcon `share/<pkg>/package.sh` marker |
| **build_install.sh 自动 touch COLCON_IGNORE** | src/mavros/{mavros,mavros_msgs,libmavconn}/ 加 ignore, 让 apt 版生效 |
| **`--build-base / --install-base` 显式指定** | colcon 默认写到容器内 `/install/`, 显式写到 host mount 的 `/opt/uav_ws/{build,install}` |
| **runtime entrypoint: install 缺失就 FATAL exit** | 不再尝试现场 build (无 cmake/gcc 必败), 错误信息明确 |
| **watchdog 跑在 host (drone 上 systemd 之外)** | setsid detach, 不依赖 systemd service lifecycle |
| **CI 拆 2 job (build-runtime + build-dev)** | dev depends on runtime, 并行 multi-arch build |

## 已知坑 (踩过, README-level)

1. **Tegra kernel 没 iptable_raw**: docker build/run 用 `--network=host`
2. **apt 装的 mavros-extras 跟 src build 重复**: 不要 apt install extras, 让 src build 出带 patch 版本
3. **colcon 写到容器内 `/install/`**: 必须 `--build-base /opt/uav_ws/build --install-base /opt/uav_ws/install`
4. **PX4 EKF2 拒收 vision_pose**: ODIN 时间戳 drift, 强制 `force_ros_stamp=true` (`slam_to_mavros_node`)
5. **mavros humble vision_pose 不 fire**: rclcpp humble bug, 构造函数直接 `create_subscription<...>(...)` 绕过（`dockerfiles/mavros-patch.diff`）

---

## GitHub Actions

`.github/workflows/docker-build.yml` —— push master 自动 build + push 两个 image 到 ghcr.io.

需要 repo Settings → Actions → General → Workflow permissions 选 "Read and write permissions" (workflow 已显式声明 `permissions: packages: write`, 这样够)

---

## 用户

- speaker (speaker@example.com)
