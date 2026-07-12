# ODIN 真机集成测试 (有 PX4 + ODIN1)

> 适用: PX4 飞控 + ODIN1 雷达都已就位, 第一次跑真机 SLAM 上链测试.
> 验证: `ODIN1 SLAM → PX4 EKF2 vision fusion → /mavros/local_position/pose`.
>
> 数据流:
> ```
> ODIN1 (USB 2207:0019)
>     ↓ host_sdk_sample driver (5-10s SDK init)
> /odin1/cloud_raw, /odin1/cloud_slam, /odin1/imu, /odin1/odometry ⭐
>     ↓ slam_to_mavros (订阅 /odin1/odometry, force_ros_stamp=true ⭐)
> /mavros/vision_pose/pose
>     ↓ mavros → MAVLink → PX4 EKF2
> /mavros/local_position/pose
> ```

## ⚠️ 必读:ODIN 时间戳问题 (调试血泪教训)

**ODIN 默认用设备开机时间做时间戳** (`use_host_ros_time=0`, `header.stamp.sec = 设备开了多少秒`). mavros 把这个时间戳直接转发给 PX4 VISION_POSITION_ESTIMATE.usec, PX4 EKF2 看到 usec 跟 PX4 内部时间基准差 ~1.78e9 倍, **EKF2_EVP_GATE 直接拒收整个 vision pose**.

**症状**: fake 测试完美, 切到 ODIN 后 PX4 LOCAL_POSITION 起点 (0,0,0) 不收敛到 ODIN 位置, 完全不动.

**修复 (二选一, 推荐方案 A)**:

### 方案 A: ODIN config 改 `use_host_ros_time: 2` (推荐)

改 `src/odin_ros_driver/config/control_command.yaml`:
```yaml
use_host_ros_time: 2  # align odin1 time to host time
```

重启 ODIN driver 生效. SDK 会做 NTP-like 4 次握手同步时间.

### 方案 B: slam_to_mavros 加 `force_ros_stamp:=true` (快速)

`force_ros_stamp` 参数已经在 slam_to_mavros_node.py 实现 (2026-07-12), 转发时用 ROS 当前时间覆盖 ODIN 时间戳. 启动命令加:
```bash
-p force_ros_stamp:=true
```

不依赖 ODIN config, 不用重启 ODIN driver, **调试时优先用这个**.

---

## 0. 跟 fake 测试的关键区别

| 项 | fake 测试 | ODIN 真机 |
|---|---|---|
| 容器启动 | idle 即可 | **必须 `--lidar odin`** (挂 USB) |
| SLAM 来源 | fake_odom_publisher | ODIN 自带 (host_sdk_sample) |
| odom topic | `/Odometry` | **`/odin1/odometry`** ⭐ |
| slam_to_mavros 启动 | 默认参数 | **必须显式 `-p odom_topic:=/odin1/odometry`** ⭐ |
| 时间戳 | ROS 系统时间 | **ODIN 设备时间** → **必加 `-p force_ros_stamp:=true`** ⭐⭐ |
| 启动时间 | 即时 | driver 需 5-10s SDK init |
| 是否需要建图 | 不需要 | **新环境需要建图** (步骤 5) |

---

## 1. 硬件接线

| 设备 | 接什么 | 备注 |
|------|--------|------|
| PX4 FMU | USB → 小电脑 | `/dev/ttyUSB0` 或 `/dev/ttyACM0` |
| ODIN1 雷达 | USB 3.0 → 小电脑 | **必须是 USB 3.0 口** (蓝色接口) |
| ODIN 上电 | 12V | ODIN 单独供电, 不要从 USB 取电 |

### 1.1 验证 ODIN USB 在主机上识别

```bash
lsusb | grep -i 2207
# 期望: Bus 00x Device 00x ID 2207:0019 Fuzhou Rockchip ...
```

**没看到?** 检查:
- USB 线是否插紧 (ODIN 用的 USB 3.0 线, 蓝色口)
- ODIN 是否上电 (12V)
- 主机 `dmesg | tail -20` 看是否有 USB 报错

---

## 2. PX4 端参数 (跟 fake 测试完全一样)

> **用户在 QGC 里改, 我不动.**

QGC → Vehicle Setup → Parameters:

```
SYS_HAS_GPS          0    # 室内, 无 GPS
EKF2_AID_MASK        24   # bit 3 vision pos + bit 4 vision yaw
EKF2_EV_CTRL         15   # vision_pose + vision_yaw 全开 (兼容 11)
EKF2_HGT_REF         3    # Vision as height source
MAV_USEHILGPS        0
EKF2_BARO_CTRL       0    # 关 baro, 避免室内气压扰动
EKF2_EVP_GATE        3.0  # 3σ 门限 (跳变保护)
```

---

## 3. 容器重启 (⚠️ 必做, ODIN USB 必须在 docker run 时挂)

**绝对不能在已起的容器里 `ros2 launch odin_ros_driver`** — 容器没 USB 设备, driver 会立即退出。

```bash
# (1) 清理: 杀掉之前 fake 测试残留
docker exec rm-uavsim pkill -f fake_odom_publisher 2>/dev/null
docker exec rm-uavsim pkill -f slam_to_mavros_node 2>/dev/null

# (2) 停掉旧容器
docker rm -f rm-uavsim

# (3) 重启, 自动检测 ODIN USB 并挂入
cd ~/rm_ws
bash scripts/start_uav_container.sh --lidar odin
```

> `--lidar odin` 不是启 driver, 只是让启动脚本知道"我要用 ODIN, 自动 lsusb 找 2207:0019 挂载整 USB bus".

### 3.1 验证 ODIN USB 已进容器

```bash
docker exec rm-uavsim lsusb | grep -i 2207
```

期望:`Bus 00x Device 00x ID 2207:0019 Fuzhou Rockchip ...`

**没看到?** 检查 `start_uav_container.sh` 的输出, 应该有 `[warn] --lidar odin 但找不到 ODIN USB`. 手动指定:
```bash
lsusb | grep 2207 | sed -n 's/.*Bus \([0-9]\+\) Device \([0-9]\+\).*/\1\/\2/p'
# 拿到 bus/device 后: bash scripts/start_uav_container.sh --lidar odin --odin-usb <bus>/<dev>
```

---

## 4. 单独启动 ODIN driver (不带 slam_to_mavros/mavros)

先单独验证 ODIN 本身能输出 `/odin1/odometry`:

```bash
docker exec -d rm-uavsim bash -lc "source /opt/uav_ws/install/setup.bash && \
  ros2 launch odin_ros_driver odin1_ros2.launch.py > /tmp/odin.log 2>&1 &"
```

**等 10s** 让 host_sdk_sample 完成 SDK 初始化.

### 4.1 验证 driver 起来了

```bash
docker exec rm-uavsim bash -c "source /opt/uav_ws/install/setup.bash && \
  ros2 topic hz /odin1/odometry"
```

期望: **10-50Hz** 稳定输出.

**没数据?** 看 driver 日志:
```bash
docker exec rm-uavsim tail -80 /tmp/odin.log
```

常见错误:
- `failed to open device` → USB 没挂 (回 步骤 3.1)
- `SDK init timeout` → ODIN 上电不稳, 检查 12V 电源
- `no IMU data` → ODIN 固件问题, 不在本文范围

### 4.2 验证 SLAM 输出本身在变

```bash
docker exec rm-uavsim bash -c "source /opt/uav_ws/install/setup.bash && \
  ros2 topic echo /odin1/odometry --field pose.pose.position"
```

**手持 ODIN 缓慢移动**, 看 x/y/z 是否变化. 静止时小幅漂移 (0.01-0.1m) 是正常的.

---

## 5. (⚠️ 推荐) 建图 — ODIN 是地图相对定位

ODIN SLAM 输出依赖地图. **新环境** 必须先建图, 否则静止时漂移会累积到米级.

### 5.1 建图流程

```bash
# (1) 开启建图
docker exec rm-uavsim bash -c "echo 'set save_map 1' > /tmp/odin_command.txt"

# (2) 手持 ODIN (或装在飞机上) 绕场地走一圈, 速度 < 0.5 m/s
#     覆盖主要区域 + 转弯处. 大约 30-60s.

# (3) 停止建图, .bin 文件会被保存
docker exec rm-uavsim bash -c "echo 'set save_map 0' > /tmp/odin_command.txt"

# (4) 找地图文件
docker exec rm-uavsim find / -name "*.bin" 2>/dev/null | grep -i odin | head -5
```

> 跳过此步 ODIN 也能输出 odom, 但只适合短期 (< 30s) 测 PX4 fusion. 长期跑必须建图.

---

## 6. 启动 slam_to_mavros 桥 (订阅 /odin1/odometry, ⭐ force_ros_stamp)

```bash
docker exec -d rm-uavsim bash -lc "source /opt/uav_ws/install/setup.bash && \
  ros2 run slam_to_mavros slam_to_mavros_node --ros-args \
    -p odom_topic:=/odin1/odometry \
    -p force_ros_stamp:=true \
  > /tmp/sm.log 2>&1 &"
```

> ⭐⭐ **必加 `-p force_ros_stamp:=true`** (除非 ODIN config 已改 `use_host_ros_time=2` 且 ODIN driver 已重启).
> ⭐ **必显式 `-p odom_topic:=/odin1/odometry`**, 默认是 `/Odometry`, 收不到 ODIN 数据.

### 6.1 验证转发通了

```bash
# /mavros/vision_pose/pose 频率应该跟 /odin1/odometry 一致
docker exec rm-uavsim bash -c "source /opt/uav_ws/install/setup.bash && \
  ros2 topic hz /mavros/vision_pose/pose"
```

期望: **10-50Hz**.

### 6.2 (推荐) 验证 mavros 发给 PX4 的 usec 字段是 Unix 时间

订阅 `/uas1/mavlink_sink`, 过滤 msgid=102 (VISION_POSITION_ESTIMATE), 解 payload 前 8 字节 (usec).

```bash
docker exec rm-uavsim bash -lc "source /opt/uav_ws/install/setup.bash && \
  timeout 5 ros2 topic echo /mavros/vision_pose/pose --once --field header"
# 看 stamp.sec 是不是 ~1783855298 (Unix 时间), 不是 608 (设备时间)
```

期望: `stamp.sec ≈ 1783855298` (Unix 时间). 如果还是几百秒, force_ros_stamp 没生效, 回去查步骤 6.

---

## 7. 启动 mavros (如果还没启)

如果容器是 `--bringup` 启的, mavros 已经自动起; 否则手动启:

```bash
docker exec -d rm-uavsim bash -lc "source /opt/uav_ws/install/setup.bash && \
  ros2 launch /opt/uav_ws/scripts/px4.launch.py fcu_url:=/dev/ttyACM0:921600 > /tmp/mavros.log 2>&1 &"

# 等 5s
sleep 5

# 验证
docker exec rm-uavsim bash -c "source /opt/uav_ws/install/setup.bash && \
  ros2 topic echo /mavros/state --once" | grep connected
# 期望: connected: true
```

---

## 8. 监控 4 个核心话题

| Topic | 来源 | 检查点 |
|---|---|---|
| `/odin1/odometry` ⭐ | ODIN SLAM | 频率 ≥10Hz, 静止漂移 <0.1m (建图后) |
| `/mavros/vision_pose/pose` | slam_to_mavros 转发 | = /odin1/odometry 同步, **stamp.sec ≈ Unix 时间** ⭐ |
| `/mavros/local_position/pose` | **PX4 EKF2 输出** | 跟随 ODIN, lag < 0.1s |
| `/mavros/state` | PX4 连接状态 | `connected: true` |

### 8.1 看 EKF2 是否真的在用 vision

```bash
docker exec rm-uavsim bash -c "source /opt/uav_ws/install/setup.bash && \
  ros2 topic echo /mavros/estimator/status"
```

输出里 `flags` 字段的 `pos_h_rel` 位 (bit 3) 应该是 1. 在 QGC → MAVLink Inspector → ESTIMATOR_STATUS 也能看.

> ⚠️ PX4 v1.13+ 部分固件默认不发 ESTIMATOR_STATUS, 如果 echo 没数据就用 PX4 LOCAL_POSITION 是否跟随 ODIN 间接验证.

### 8.2 看 PX4 跟随

```bash
docker exec rm-uavsim bash -c "source /opt/uav_ws/install/setup.bash && \
  ros2 topic echo /mavros/local_position/pose --field pose.position"
```

**手持飞机**, 看 PX4 估计位置是否跟着你手移动.

---

## 9. 静态 + 动态验证

### 9.1 静态 (飞机不动, 5s)

期望:
- `/odin1/odometry` 漂移 < 0.1m (建图后) / < 0.5m (未建图)
- `/mavros/local_position/pose` 收敛后稳定, 漂移 < 0.2m
- **两者数值一致, 误差 < 5cm** ⭐ (验证 EKF2 fusion 工作)

### 9.2 动态 stop-and-go (手拿飞机做, 跟 fake 测试一样)

| 步骤 | 位置 | 停稳时间 |
|---|---|---|
| 起点 | (0, 0) | 3s |
| 走到 | (1, 0) | 3s |
| 走到 | (1, 1) | 3s |
| 走到 | (0, 1) | 3s |
| 回到 | (0, 0) | 3s |

每段停稳后, 看 `/mavros/local_position/pose` 的 (x, y):
- 期望: 跟手拿位置一致 (允许 ±0.2m 误差)
- 期望: 切段后 1s 内跟到, lag ≈ 50ms

### 9.3 Pass 条件

- ✅ **链路通**: `/mavros/vision_pose/pose` 频率跟 ODIN 一致
- ✅ **时间戳对齐**: `/mavros/vision_pose/pose.header.stamp.sec` ≈ Unix 时间 (1.78e9 量级)
- ✅ **PX4 在用 vision**: `/mavros/local_position/pose` 跟 ODIN, 误差 < 5cm
- ✅ **静态稳**: 5s 静止后 PX4 漂移 < 0.2m
- ✅ **动态跟**: stop-and-go 每段 (x, y) 误差 < 0.5m

---

## 10. 故障排查

| 现象 | 排查 |
|---|---|
| ODIN driver 启动后立即退出 | USB 没挂进去, 回 步骤 3.1 |
| `/odin1/odometry` 频率 < 5Hz | SDK 初始化未完成, 再等 10s |
| ODIN 静止时漂移 > 0.5m | 没建图, 跑 步骤 5 |
| `/mavros/vision_pose/pose` 无数据 | slam_to_mavros 没起来或 `odom_topic` 没设对 (回 步骤 6) |
| **`/mavros/vision_pose/pose.header.stamp.sec` 几百秒** ⭐ | **ODIN 设备时间未对齐**, 检查 `force_ros_stamp:=true` 是否生效 (步骤 6.2) |
| **`/mavros/local_position/pose` 不动, ODIN 在动** ⭐ | **必查时间戳! PX4 EKF2 拒收 vision pose**. 回顶部必读章节 |
| `/mavros/local_position/pose` 不动 (其他原因) | 看 EKF2 status: `pos_h_rel` 是否=1; 看 `EKF2_EV_CTRL=11` 是否仍生效 |
| mavros 反复重启 | 检查 PX4 USB 还在; `docker logs rm-uavsim` 看错误 |
| PX4 输出跳变 (1m+ 阶跃) | 正常, `EKF2_EVP_GATE=3.0` 拒了. 但若连续运动也跳, 检查 ODIN 是否在漂移 |
| slam_to_mavros 启动后立即退出 | 看 `/tmp/sm.log`, 常见是 TF 异常 |

---

## 11. 停止

```bash
docker exec rm-uavsim pkill -f slam_to_mavros_node
docker exec rm-uavsim pkill -f host_sdk_sample
# mavros 别杀, 留着. 下次 ODIN 再起 driver 即可.
```

---

## 12. 验证清单 (完成后勾一遍)

- [ ] ODIN USB 在主机 lsusb 看到 2207:0019
- [ ] 容器以 `--lidar odin` 重启, 容器内 lsusb 也能看到
- [ ] `/odin1/odometry` 频率 ≥10Hz
- [ ] (可选) 已建图, .bin 文件保存
- [ ] **slam_to_mavros 启动时带 `-p force_ros_stamp:=true`** ⭐
- [ ] slam_to_mavros 启动时带 `-p odom_topic:=/odin1/odometry`
- [ ] **`/mavros/vision_pose/pose.header.stamp.sec` ≈ Unix 时间** ⭐
- [ ] `/mavros/vision_pose/pose` 频率跟 ODIN 一致
- [ ] (可选) `/mavros/estimator/status` 的 `pos_h_rel=1`
- [ ] **PX4 LOCAL_POSITION 跟 ODIN 数值一致 (误差 < 5cm)** ⭐
- [ ] 静态 5s, PX4 漂移 < 0.2m
- [ ] 动态 stop-and-go, 每段误差 < 0.5m
- [ ] PX4 → QGC 看 MAVLink Inspector, LOCAL_POSITION_NED 跟手运动

---

## 13. 长期: 永久修复 ODIN 时间戳

如果不想每次启动都加 `-p force_ros_stamp:=true`, 可以改 ODIN config (方案 A):

1. 编辑 `src/odin_ros_driver/config/control_command.yaml`:
   ```yaml
   use_host_ros_time: 2
   ```
2. 重启 ODIN driver
3. SDK 会做 4 次 NTP-like 握手同步, 30 帧滑动窗口
4. 之后 `/odin1/odometry.header.stamp.sec` 直接就是 Unix 时间

启动 slam_to_mavros 时就不需要 `-p force_ros_stamp:=true` 了 (加了也无害, 会覆盖一次).

---

## 相关 memory

- `~/.claude/projects/-home-robotega-rm-ws/memory/odin-timestamp-px4-fusion.md` — ODIN 时间戳问题的完整分析
- `~/.claude/projects/-home-robotega-rm-ws/memory/imu-vision-fusion-insight.md` — 为什么必须 vision fusion