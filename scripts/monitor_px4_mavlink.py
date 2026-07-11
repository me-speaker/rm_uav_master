#!/usr/bin/env python3
"""PX4 端直接监控 — 通过 MAVLink 读 PX4 EKF2 内部状态, 不经过 mavros

对比 /odin1/odometry (ODIN SLAM, ROS 话题) 和 PX4 LOCAL_POSITION_NED (PX4 EKF2, MAVLink)
+ ESTIMATOR_STATUS 解析 control_mode_flags 告诉你 EKF2 真用了 vision 没
"""
import sys
import time
import threading

import rclpy
from rclpy.node import Node
from nav_msgs.msg import Odometry

from pymavlink import mavutil


# ESTIMATOR_STATUS 控制位 (PX4 estimator_status.msg)
CS_BITS = {
    1<<0:  'attitude',
    1<<1:  'velocity_horiz',
    1<<2:  'velocity_vert',
    1<<3:  'pos_horiz_rel',
    1<<4:  'pos_horiz_abs',
    1<<5:  'pos_vert_abs',
    1<<6:  'pos_vert_agl',
    1<<7:  'pred_pos_horiz_rel',
    1<<8:  'pred_pos_horiz_abs',
    1<<9:  'pred_pos_vert_abs',
    1<<10: 'pred_pos_vert_agl',
}
# ESTIMATOR_STATUS sensor flags (PX4 estimator_status.msg, 字段名 sensor_bitfield)
SENSOR_BITS = {
    1<<0:  'GPS',
    1<<1:  'optical_flow',
    1<<2:  'VISION',         # ← 关键: vision 是否被用
    1<<3:  'laser',
    1<<4:  'magnetometer',
    1<<5:  'barometer',
    1<<6:  'differential_pressure',
    1<<7:  'GPS2',
    1<<8:  'external_vision',  # ← 另一个 vision 位
}


class PX4Monitor:
    def __init__(self, device='/dev/ttyACM0', baud=921600):
        print(f'connecting to {device} @ {baud}...')
        self.mav = mavutil.mavlink_connection(device, baud=baud)
        print('waiting for PX4 heartbeat...')
        hb = self.mav.wait_heartbeat(timeout=10)
        if not hb:
            print('NO HEARTBEAT')
            sys.exit(1)
        print(f'PX4 OK: sysid={hb.get_srcSystem()}, compid={hb.get_srcComponent()}')

        # 订阅 LOCAL_POSITION_NED, ATTITUDE, ESTIMATOR_STATUS
        self.last_local_pos = None
        self.last_attitude = None
        self.last_est_status = None
        self.last_odometry = None  # MAVLink ODOMETRY (如果有)

    def request_streams(self):
        """PX4 默认就发所有消息 (LOCAL_POSITION_NED, ESTIMATOR_STATUS, ATTITUDE...),
        不需要订阅. 留着空函数向后兼容.
        """
        pass

    def recv_messages(self):
        """读 MAVLink 队列,更新 latest. 用阻塞 + timeout 让数据有机会累积."""
        # 关键: 非阻塞 timeout=0 在低数据率消息 (ESTIMATOR_STATUS 1Hz) 下可能错过
        # 改用 timeout=0.05, 单次 recv, 主循环每次调用一次
        msg = self.mav.recv_match(blocking=True, timeout=0.05)
        if msg is not None:
            self._dispatch(msg)
        # 也 drain 一下 buffer 里其他消息 (避免堆积)
        while True:
            extra = self.mav.recv_match(blocking=False, timeout=0)
            if extra is None:
                break
            self._dispatch(extra)

    def _dispatch(self, msg):
        t = msg.get_type()
        if t == 'LOCAL_POSITION_NED':
            self.last_local_pos = msg
        elif t == 'ATTITUDE_QUATERNION':
            self.last_attitude = msg
        elif t == 'ESTIMATOR_STATUS':
            self.last_est_status = msg
        elif t == 'ODOMETRY':
            self.last_odometry = msg


def decode_bits(value, bit_map):
    """把 int 解码成 'bit1 (name) | bit2 (name)' 字符串."""
    return ' | '.join(name for bit, name in bit_map.items() if value & bit) or '(none)'


def fmt_local_ned(msg):
    return f'x={msg.x:8.3f}  y={msg.y:8.3f}  z={msg.z:8.3f}'


def fmt_attitude(msg):
    """roll/pitch/yaw 从四元数转欧拉角."""
    import math
    q = [msg.q1, msg.q2, msg.q3, msg.q4]
    # roll (x-axis rotation)
    sinr_cosp = 2 * (q[3]*q[0] + q[1]*q[2])
    cosr_cosp = 1 - 2 * (q[0]*q[0] + q[1]*q[1])
    roll = math.atan2(sinr_cosp, cosr_cosp)
    # pitch (y-axis rotation)
    sinp = 2 * (q[3]*q[1] - q[2]*q[0])
    pitch = math.asin(max(-1, min(1, sinp)))
    # yaw (z-axis rotation)
    siny_cosp = 2 * (q[3]*q[2] + q[0]*q[1])
    cosy_cosp = 1 - 2 * (q[1]*q[1] + q[2]*q[2])
    yaw = math.atan2(siny_cosp, cosy_cosp)
    return f'roll={math.degrees(roll):6.1f}°  pitch={math.degrees(pitch):6.1f}°  yaw={math.degrees(yaw):6.1f}°'


def fmt_odometry(msg):
    """PX4 回传的 ODOMETRY (如果 MAV_ODOM_LP=1)."""
    return f'x={msg.x:8.3f}  y={msg.y:8.3f}  z={msg.z:8.3f}'


class RosOdinListener(Node):
    """订阅 /odin1/odometry 跟 PX4 端对比."""
    def __init__(self):
        super().__init__('odin_listener')
        self.last_odin = None
        self.create_subscription(Odometry, '/odin1/odometry', self.cb, 10)

    def cb(self, msg):
        self.last_odin = msg


def main():
    # ⚠️ 调用前确保 mavros + slam_to_mavros 已停 (host wrapper 脚本负责)
    # 这个脚本只做 MAVLink 直读 + ROS 订阅, 不自己 stop/start 进程
    px4 = PX4Monitor()
    px4.request_streams()

    # ROS side
    rclpy.init()
    ros_node = RosOdinListener()

    print()
    print('=' * 70)
    print('  PX4 MAVLink 直读 + ODIN ROS 监控 (按 Ctrl+C 退出)')
    print('  注意: mavros 暂时停了 (wrapper 脚本会重启)')
    print('=' * 70)
    print('  /odin1/odometry           → ODIN SLAM (ROS)')
    print('  LOCAL_POSITION_NED        → PX4 EKF2 (MAVLink 直读, ROS 没碰)')
    print('  ESTIMATOR_STATUS          → PX4 EKF2 flags (关键!)')
    print('  ATTITUDE_QUATERNION       → PX4 EKF2 姿态')
    print('=' * 70)
    print()

    prev_odin_x = prev_odin_y = prev_px4_x = prev_px4_y = None

    try:
        for i in range(120):
            px4.recv_messages()
            rclpy.spin_once(ros_node, timeout_sec=0)

            print(f'--- T+{i}s ---')

            if px4.last_local_pos:
                lp = px4.last_local_pos
                print(f'  [PX4 LOCAL_POSITION_NED]  {fmt_local_ned(lp)}')
                cur_x, cur_y = lp.x, lp.y
                if prev_px4_x is not None:
                    dx = cur_x - prev_px4_x
                    dy = cur_y - prev_px4_y
                    print(f'    Δx={dx:+7.3f}  Δy={dy:+7.3f}')
                    prev_px4_x, prev_px4_y = cur_x, cur_y
                else:
                    prev_px4_x, prev_px4_y = cur_x, cur_y
            else:
                print(f'  [PX4 LOCAL_POSITION_NED]  (waiting...)')

            # ⭐ ESTIMATOR_STATUS
            if px4.last_est_status:
                es = px4.last_est_status
                # MAVLink ESTIMATOR_STATUS 的字段叫 `flags` (uint32), 不是 control_mode_flags
                flags = getattr(es, 'flags', getattr(es, 'control_mode_flags', 0))
                print(f'  [PX4 ESTIMATOR_STATUS]    flags: 0x{flags:04x}  ({flags})')
                cs_decoded = decode_bits(flags, CS_BITS)
                print(f'                              → {cs_decoded}')

                # MAVLink 标志位定义 (跟 PX4 uORB 不同, 这是 MAVLink 标准定义):
                # bit 0  ATTITUDE              = 1
                # bit 1  VELOCITY_HORIZ        = 2
                # bit 2  VELOCITY_VERT         = 4
                # bit 3  POS_HORIZ_REL         = 8
                # bit 4  POS_HORIZ_ABS         = 16
                # bit 5  POS_VERT_ABS          = 32
                # bit 6  POS_VERT_AGL          = 64
                # bit 7  CONST_POS_MODE        = 128
                horiz_pos = bool(flags & (1<<3)) or bool(flags & (1<<4))  # rel or abs horiz pos
                horiz_vel = bool(flags & (1<<1))
                vert_pos  = bool(flags & (1<<5))
                if horiz_pos:
                    print(f'                              ✅ EKF2 在用 horizontal vision position')
                elif horiz_vel:
                    print(f'                              ⚠️  EKF2 只用 horiz velocity, 没 horizontal position')
                else:
                    print(f'                              ❌ EKF2 没在用 horizontal vision (只 attitude + vertical)')

            if px4.last_attitude:
                print(f'  [PX4 ATTITUDE]            {fmt_attitude(px4.last_attitude)}')

            if ros_node.last_odin:
                o = ros_node.last_odin.pose.pose.position
                print(f'  [ODIN /odin1/odometry]    x={o.x:8.3f}  y={o.y:8.3f}  z={o.z:8.3f}')
                cur_x, cur_y = o.x, o.y
                if prev_odin_x is not None:
                    dx = cur_x - prev_odin_x
                    dy = cur_y - prev_odin_y
                    print(f'    Δx={dx:+7.3f}  Δy={dy:+7.3f}')
                prev_odin_x, prev_odin_y = cur_x, cur_y
            else:
                print(f'  [ODIN /odin1/odometry]    (waiting...)')

            if px4.last_odometry:
                print(f'  [PX4 ODOMETRY 回传]       {fmt_odometry(px4.last_odometry)}')

            print()
            time.sleep(0.5)

    except KeyboardInterrupt:
        print('\nstopped.')
    finally:
        try:
            ros_node.destroy_node()
            rclpy.shutdown()
        except Exception:
            pass


if __name__ == '__main__':
    main()