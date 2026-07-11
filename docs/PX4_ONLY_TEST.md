# PX4-only 全链路测试 (无 LiDAR 硬件)

> 适用: 有真 PX4 飞控, 但暂时没有 Mid-360 / ODIN 雷达的场景.
> 用 `fake_odom_publisher` 节点替代真实 SLAM, 验证整条链路.
>
> 数据流:
> ```
> fake_odom_publisher  --/Odometry-->  slam_to_mavros  --/mavros/vision_pose/pose-->  mavros  --MAVLink-->  PX4 EKF2
> ```

## 1. 硬件接线

| 设备 | 接什么 | 备注 |
|------|--------|------|
| PX4 FMU | USB → 小电脑 | `/dev/ttyUSB0` 或 `/dev/ttyACM0` |
| (无 LiDAR) | — | — |

不需要 LiDAR, 不需要网络。

## 2. PX4 端参数 (跟真 LiDAR 一致)

QGC → Vehicle Setup → Parameters:

```
SYS_HAS_GPS          0
EKF2_AID_MASK        24
EKF2_EV_CTRL         15
EKF2_HGT_REF         3
MAV_USEHILGPS        0
```

> **重要**: `SYS_HAS_GPS 0` + `EKF2_AID_MASK 24` = 完全依赖视觉融合, 室内无 GPS 时必设.

## 3. 启动

### 3.1 启容器 (idle 模式, 不要 --bringup)

```bash
cd ~/rm_ws
bash scripts/start_uav_container.sh
```

(确认 PX4 USB 接好, 容器启动时已加 `--device=/dev/ttyUSB0`)

### 3.2 一键启动 fake LiDAR + PX4 链路

```bash
bash scripts/launch_test_with_px4.sh \
    --fcu-url /dev/ttyUSB0:921600 \
    --motion-mode circle
```

内部相当于: `ros2 launch uav_bringup.launch.py lidar:=fake fake_motion_mode:=circle fcu_url:=/dev/ttyUSB0:921600`

启动顺序:
```
T+0s : fake_odom_publisher     (产 /Odometry @ 50Hz, mode=circle 走 1m 半径圆)
T+0s : slam_to_mavros_node     (桥 -> /mavros/vision_pose/pose)
T+3s : mavros (px4.launch)     (跟 PX4 MAVLink 握手)
```

### 3.3 运动模式选项

```bash
# 原点悬浮 (最稳, 默认)
bash scripts/launch_test_with_px4.sh --motion-mode hover

# 水平圆周 (1m 半径, 20s/圈)  ← 验 PX4 是否跟随
bash scripts/launch_test_with_px4.sh --motion-mode circle

# 直线飞 (+X 方向, 1m/s)
bash scripts/launch_test_with_px4.sh --motion-mode linear

# 随机游走 (±0.3m) — 压力测试
bash scripts/launch_test_with_px4.sh --motion-mode random
```

## 4. 验证 PX4 真的收到 vision pose

### 4.1 mavros 连接成功

```bash
bash scripts/start_uav_container.sh exec bash -c \
    'source /opt/uav_ws/install/setup.bash && \
     ros2 topic echo /mavros/state --once'
```

期望:
```
header:
  stamp: ...
connected: True
mode: ...
armed: False
guided: True
```

### 4.2 vision pose 在发布

```bash
bash scripts/start_uav_container.sh exec bash -c \
    'source /opt/uav_ws/install/setup.bash && \
     timeout 3 ros2 topic hz /mavros/vision_pose/pose'
```

期望: `rate: 50.000` 附近

### 4.3 PX4 端融合状态 (QGC)

QGC 主界面 → drone 在地图上应该显示一个小圆点/小幅度晃动 (跟着 circle 模式转):
- 工具栏: **SYS_STATUS** 正常
- **ESTIMATOR STATUS**:
  - `preflt_check: OK`
  - `attitude: fused`
  - `velocity: fused`
  - `position: fused` ← 关键!
  - `height: fused`

### 4.4 PX4 端 vision delay log

```bash
# 进 MAVLink console (QGC → Analyze Tools → MAVLink Console)
listener vision_pose
```

期望: 高频 (50Hz) 收到的 vision pose, covariance 正常.

## 5. 进阶测试

### 5.1 验证 PX4 EKF2 切换到 vision-only

```bash
# PX4 参数
param show EKF2_AID_MASK    # 应该 24
param show EKF2_HGT_REF     # 应该 3 (Vision)
param show EKF2_EV_CTRL     # 应该 15
```

### 5.2 模拟传感器失效 (断开 mavros 看看 PX4 怎么办)

```bash
bash scripts/stop_launch.sh px4-test  # 停 mavros
```

PX4 失去 vision pose 后应该:
- 切到 failsafe (因为 SYS_HAS_GPS=0)
- 如果遥控器在, 切 manual 模式还能飞

### 5.3 切换运动模式 (热切换)

```bash
bash scripts/start_uav_container.sh exec bash -c \
    'pkill -f fake_odom_publisher; sleep 1; \
     source /opt/uav_ws/install/setup.bash && \
     nohup ros2 run slam_to_mavros fake_odom_publisher --ros-args -p motion_mode:=hover > /tmp/fake.log 2>&1 &'
```

QGC 上 drone 应该立刻停在小幅晃动.

## 6. 跟真 LiDAR 模式的对比

| | PX4-only (fake) | 真 LiDAR (mid360/odin) |
|---|---|---|
| /Odometry 来源 | fake_odom_publisher (50Hz) | fast_lio 或 odin_ros_driver |
| /mavros/vision_pose/pose | ✅ 真实进入 PX4 | ✅ 真实进入 PX4 |
| PX4 EKF2 融合 | ✅ 完全一样 | ✅ 完全一样 |
| 验证什么 | mavros + slam_to_mavros + PX4 链路 | 整体定位 + 控制链路 |
| 适用 | 实验室无 LiDAR 时开发调试 | 真实飞行 |

**建议工作流**:
1. 第一步: PX4-only 模式验证链路通 (本节)
2. 第二步: 装 LiDAR 后换 mid360/odin 模式
3. 第三步: 实飞前静态测试 (手持晃动机体看 rviz 地图成形)

## 7. 故障排查

| 现象 | 排查 |
|------|------|
| mavros `connected: false` | 检查 `ls /dev/ttyUSB*`, container 启动加了 `--device=$PX4_DEV` |
| /mavros/vision_pose/pose 没数据 | `slam_to_mavros_node` 进程在不在? `fake_odom_publisher` 是不是起? `/Odometry` 频率多少? |
| PX4 connected 但 position 不 fused | `EKF2_AID_MASK` 不是 24; `EKF2_HGT_REF` 不是 3; 重启 PX4 让参数生效 |
| PX4 不停重启 / drone 抖 | covariance 太大或太小; 检查 fake_odom_publisher.yaml 的 `noise_pos_std_m` (默认 0.005 应该够) |
| /mavros/vision_speed/speed_twist 没数据 | fake_odom_publisher 默认不发 (因为速度算不精确), 改代码或调参数 |
| 想关掉 fake 看真实 EKF2 警告 | 停 fake_odom_publisher, PX4 会因 vision pose 缺失报警 (符合预期) |

## 8. 与 sim_ws 模式的关系

| | sim_ws/egg_ws (SITL) | rm_ws (实机) |
|---|---|---|
| 仿真方式 | Gazebo Harmonic | 直接真 PX4 |
| 雷达 | GZ plugin 模拟 | 真 LiDAR 或 fake |
| PX4 | PX4 SITL in container | 真 PX4 硬件 |
| 优势 | 不用硬件, 全栈可仿真 | 真实 EKF2 行为 |
| 适用 | 算法验证 | 集成 / 飞行前验证 |

**推荐双轨**:
- sim_ws 跑 SITL: 算法修改后先在仿真里试
- rm_ws 跑实机: SITL 通了再上真机, PX4-only 测试先验链路, 再加 LiDAR