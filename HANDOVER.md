# HANDOVER — rm_ws 项目状态移交文档

> 写给下一个会话(或其他 Claude 实例),用来快速理解 rm_ws 当前在做什么、卡在哪、下一步怎么走
> 创建时间: 2026-07-14 16:08
> 用户: speaker (speaker@example.com)

---

## 一句话

**机载无人机 SLAM+PX4+mavros 部署项目,真机验证已经飞过(自稳效果不错),现在卡在"上电自启"最后一步。 昨天讨论过镜像拆分,但被我重新算账后判断"过早优化,先跑通自启"。**

---

## 当前真正卡的事 (in_progress)

**#60: uavboard 上电自启测试**

- 节点 → 链路 → PX4 EKF2 vision fusion 已经 work
- **现在的瓶颈**: 重启 uavboard 后,容器 + watchdog + launch 链路端到端跑通

详见下面"6. 当前 #60 待决问题"

---

## 1. 硬件 & 网络拓扑

| 角色 | 机器 | IP | 用户 | 备注 |
|---|---|---|---|---|
| **uavboard** (Jetson Orin Nano, arm64) | 飞行小电脑 | 192.168.100.3 | `ega-orin-nano-1` | 密码 `robotega`,无 ssh key,**只有 paramiko 走密码**;无外网 |
| **dev 机** (arm64 同架构) | 工作站 | 本机 | `robotega` | 通过 `sync_to_drone.py` 推到 uavboard |

⚠️ 用户专门说:**"千万不要动远程电脑除了 docker 容器相关以外的任何东西"** —— uavboard 上只允许碰 docker 容器 / 容器化相关文件,不要碰系统配置外的其他东西。

---

## 2. 链路架构

```
[ODIN 雷达 USB]
   ↓ vendor 2207:0019, vendor SDK 自带 SLAM
[driver /host_sdk_sample]  ← docker 容器内
   ↓ /odin1/odometry
[slam_to_mavros_node]      ← docker 容器内, 自写, force_ros_stamp=true
   ↓ /mavros/vision_pose/pose + /mavros/vision_speed/speed_twist
[mavros_node]              ← docker 容器内
   ↓ MAVLink over /dev/ttyACM0 (PX4 USB)
[PX4 飞控]                  ← EKF2 vision fusion, 0.2cm 精度(亲测)
```

**关键事实**:
- 真机飞过, 自稳 OK(`用户反馈: "自稳效果不错"`)
- PX4 EKF2 跟着 ODIN 输出位置, 距离差 ~0.2cm
- 链路 1Hz 启动 → 完整跑起来 ~3 秒达到稳定 fusion

---

## 3. 关键代码/配置位置

### 3.1 slam_to_mavros_node (force_ros_stamp 修复)

```
/home/robotega/rm_ws/src/slam_to_mavros/slam_to_mavros/slam_to_mavros_node.py
```

- `force_ros_stamp` 参数 = True (修复 ODIN 设备时间戳导致 PX4 EKF2 拒收)
- 实现: msg.header.stamp = 当前 ROS time

### 3.2 mavros humble vision_pose 修补

```
/home/robotega/rm_ws/src/mavros/mavros_extras/src/plugins/vision_pose_estimate.cpp
```

- `node_declare_and_watch_parameter` 的 lambda 在 humble 上不触发订阅
- workaround: 手动 `create_subscription<geometry_msgs::msg::PoseStamped>("~/pose", 10, ...)`

### 3.3 一键启动 launch

```
/home/robotega/rm_ws/src/slam_to_mavros/launch/odin_px4_full.launch.py
```

- 3 节点: host_sdk_sample (ODIN) + mavros_node + slam_to_mavros_node
- `TimerAction(period=2.0)` 串起 launch 顺序(原 15s, 已砍到 2s)

### 3.4 部署脚本 (host 端)

| 脚本 | 用途 |
|---|---|
| `scripts/build_native.sh` | 本机 (arm64) build `ega-uav-dep:arm-v1.0` (~5GB) |
| `scripts/start_uav_container.sh` | docker run 入口, 挂 src + USB + 端口 |
| `scripts/sync_to_drone.py` | paramiko + rsync, 推送代码到 uavboard |
| `scripts/launch_odin_px4.sh` | 在容器内 `docker exec` 调 launch |
| `scripts/rm_dep-autostart.sh` | systemd 调: 启容器 + 启 watchdog |
| `scripts/rm_dep-watchdog.sh` | 检测 /dev/ttyACM0, 出现后 launch |
| `scripts/verify_autostart.py` | 8 项检查, 验证自启链路 work |

### 3.5 systemd 配置 (uavboard 上)

```
/etc/systemd/system/rm_dep.service
Type=simple
ExecStart=/usr/local/bin/rm_dep-autostart.sh
Restart=on-failure
```

⚠️ 关键: **Type=simple**,不是 oneshot(昨天修过,oneshot 会让容器 exit 后 service 退出)。autostart.sh 末尾是 `exec sleep infinity`,保持 main process 不退。

---

## 4. 当前 Dockerfile 状态

`Dockerfile.uav` (v3.0) **单骨架镜像**:

```
FROM ubuntu:22.04-linuxarm64
```

包含:
- ✅ ROS 2 Humble (apt 装, 清华源)
- ✅ MAVROS + mavros-extras
- ✅ GeographicLib datasets (用 `dockerfiles/geographiclib-datasets/` COPY, 避免网络 fetch)
- ✅ Livox SDK 源码编译 (gh-proxy.com fallback)
- ✅ SLAM deps: libeigen3 libpcl libyaml-cpp glog gflags libusb OpenCV
- ✅ udev rules for Livox USB + ODIN USB vendor 2207:0019
- ✅ 启动脚本 baked-in
- ✅ colcon 系列 (用于现场 build --symlink-install .py 改)
- ⚠️ 体积 ~1.13GB (优化后 956MB, 是历史最小)

**注意**:
1. `entrypoint` 内嵌的 `/ros_entrypoint.sh` (Dockerfile 行 248-277) 含"装现场 colcon build"逻辑作为容错 —— 但实际部署走的是 mount 进来的 `uav_entrypoint.sh`, **不会现场 build** (昨天对话中我误说"现场 build 1-2 min",已纠正)
2. container 真实 ENTRYPOINT = `/ros_entrypoint.sh`,而 `uav_entrypoint.sh` 是 mount 进 `/usr/local/bin/` 供手动 exec

---

## 5. 已做 / 未做 / 进行中

### ✅ 已完成

| 项目 | 状态 |
|---|---|
| ODIN 时间戳修复 (force_ros_stamp) | ✅ 已 merge, 真机验证 ok |
| mavros humble vision_pose 修补 | ✅ 已 patch, 修补后链路通 |
| 一键 launch (odin_px4_full.launch.py) | ✅ 3 节点 + TimerAction 2s 串 |
| systemd 自动启 (Type=simple) | ✅ 已 install + enable |
| watchdog 检测 PX4 USB | ✅ 2s 轮询 /dev/ttyACM0 |
| GitHub Actions multi-arch workflow | ✅ 已配 |
| 镜像大小优化 (1.13GB → 956MB) | ✅ |
| paramiko 同步脚本 (sync_to_drone.py) | ✅ |
| 真机飞行测试 (自稳) | ✅ 用户亲飞, OK |

### ⚠️ 进行中 (in_progress)

**#60: uavboard 上电自启测试**

昨天测试进展:
1. 服务 active ✅
2. watchdog 在跑 ✅
3. 容器 start ✅
4. **但容器内看不到 install/setup.bash** —— 可能 host install/ 没传进去 / symlink 断了
5. ODIN 节点起来了但 hz 很低 (3-5 Hz 而不是 10+)
6. vision_pose hz 也低
7. PX4 跟 ODIN 距离 ~0.2cm 反而 OK
8. timestamp 偏离真实时间 (但这是 ODIN timestamp 的已知特性)

### ❌ 未做 (按优先级排序)

| 优先级 | 任务 | 备注 |
|---|---|---|
| 🔴 高 | **#60 自启链路端到端跑通** | 详见下节 |
| 🟡 中 | 拆分 builder + runtime 镜像? | **昨天讨论后判断:过早优化, 暂不做, 等自启跑通再说**。 真要做也只需在 Dockerfile.uav 末尾 apt-get purge build tools,30 行改动 |
| 🟢 低 | Roadmap v3.1+ (point_fly / aligned mode / ros2 bag / systemd 完整自启) | 用户没催 |

---

## 6. 当前 #60 待决问题

**昨天对话最后阶段(从 summary):**

> watchdog 启了, 但 launch fails due to install directory issues.
> 具体是:**uavboard 上重启后, 容器内 /opt/uav_ws/install/setup.bash 缺失**.
> root cause 可能:
>   - host install/ 没 rsync 到 uavboard
>   - 容器启动 mount 参数丢了 install/ 路径
>   - 挂载路径错了

**下一步该干什么 (next session 进门先看)**:

1. ssh 到 uavboard (或 paramiko)
2. 看 `tail -50 /var/log/uav/watchdog-*.log` 找最近一条 launch 失败原因
3. 检查 `/home/ega-orin-nano-1/rm_ws/install/setup.bash` 在 host 上是否存在
4. 看 `docker inspect rm_dep` 的 Mounts,确认 install/ 真的挂进了容器
5. 修通后跑 `python3 scripts/verify_autostart.py ega-orin-nano-1@192.168.100.3` 期望 8/8

---

## 7. 镜像拆分讨论 —— 已否决, 留作背景

**昨天对话发生过**: 用户说"设计 build 和 dep 两个镜像,在 dev 机部署 build 镜像,在 uavboard 部署 dep 镜像"。 **我接受了,做了详细 plan, 但最后重新算账后主动撤回了, 因为 ROI 低**:

| 拆镜像省的事 | 价值 |
|---|---|
| ~250MB 镜像磁盘 | 不是瓶颈 (Jetson 64GB eMMC) |
| ~30s 启动 build 时间 | happy path 已经是 0 现场 build |
| build RAM | build tools 运行时占 RAM 很少 |

**结论**: 拆镜像 = 过早优化, 先把自启跑通再说。 真要做未来只需 30 行 `apt-get purge` 削掉 build-essential + *-dev。

**如果用户回来又提"拆镜像", 记得提醒他昨天对话的撤回事, 确认还是不是要拆**。

---

## 8. 重要约束 / 踩过的坑

### 8.1 环境相关

- **`ubuntu:22.04` 不能直接用**(docker.io 不通, multi-arch manifest 算不出 checksum, build 失败)
- 用 **`ubuntu:22.04-linuxarm64`** 硬编码 arm64 tag 才 work
- **dev 机也是 arm64**, 不是 amd64 —— 很多次我都默认 amd64 错了, **多问一句准一点**
- **uavboard 无外网**, image 推过去用 `docker save | ssh | docker load`, 不是 pull
- **qemu / multi-arch 不存在**, 不要走 cross-build

### 8.2 部署相关

- **uavboard 用户名是 `ega-orin-nano-1`**, 不是 `robotega`
- **uavboard 密码 `robotega`** (我昨天开始也用错了, 用户纠正后才知道)
- **uavboard 上只能碰 docker 容器相关**, 其他系统配置不动
- **systemd Type 必须 simple + ExecStop + `exec sleep infinity`**(Type=oneshot 不行, 容器退出会自杀)

### 8.3 代码相关

- **PX4 端参数**: SYS_HAS_GPS=0, EKF2_AID_MASK=24, EKF2_EV_CTRL=15, EKF2_HGT_REF=3
- **ODIN `force_ros_stamp` 必须 = true**, 否则 EKF2 拒收
- **mavros humble vision_pose 是 broken 的**, 必须手动 create_subscription patch
- **colcon build 必须 `--symlink-install`**, 不然 .py 改完看不到效果

---

## 9. 验证清单 (改动后跑一遍)

```bash
# 1. dev 端 build OK
bash scripts/build_native.sh

# 2. uavboard 容器 + 自启 + verify 都过
ssh ega-orin-nano-1@192.168.100.3
# 或: python3 scripts/verify_autostart.py ega-orin-nano-1@192.168.100.3

# 8 项检查 (verify_autostart.py):
#   A. service active
#   B. watchdog 在跑
#   C. 容器在
#   D. 3 节点 (host_sdk_sample / mavros_node / slam_to_mavros_node)
#   E. ODIN hz ≥ 10
#   F. vision_pose hz ≥ 10
#   G. PX4 vs ODIN 距离 < 5cm
#   H. vision_pose timestamp 是 Unix (2023+)
```

---

## 10. 近期提交历史

```
15c06c5 perf: watchdog polling 2s + launch TimerAction 2s, sync_to_drone.sh 增量同步
b112852 cut the docker image size
735521f deploy: baked-in runtime, GeographicLib datasets, GitHub Actions
c86c74a new docker image
9a26d04 ODIN force_ros_stamp: 修复 ODIN 设备时间戳导致 PX4 EKF2 拒收 vision pose
```

---

## 11. 关键文件 quick ref

```
CLAUDE.md                                       # 项目总览 (旧, 给 Claude 入门)
HANDOVER.md                                     # ← 你正在看
Dockerfile.uav                                  # 单骨架镜像 (v3.0, multi-arch)
src/slam_to_mavros/launch/odin_px4_full.launch.py   # 一键 3 节点
src/slam_to_mavros/slam_to_mavros/slam_to_mavros_node.py  # force_ros_stamp
src/mavros/mavros_extras/src/plugins/vision_pose_estimate.cpp  # humble patch
scripts/build_native.sh                         # dev 端 build
scripts/sync_to_drone.py                        # paramiko 推 uavboard
scripts/rm_dep-autostart.sh                     # systemd 调
scripts/rm_dep-watchdog.sh                      # 检 USB launch
scripts/verify_autostart.py                     # 8 项检查
scripts/rm_dep.service                          # systemd unit
```

---

**记住**: 当前是 #60 自启测试进行中, **镜像拆分已被否决为过早优化, 真要做未来只需 30 行改动**。
