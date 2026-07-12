#!/usr/bin/env python3
"""px4_vision_injector.py — 直接用 pymavlink 注入 VISION_POSITION_ESTIMATE 给 PX4.

绕过 mavros vision_pose plugin 的 bug (callback 不 fire, 即使订阅创建成功也不转发)。

用法:
  1. 停 mavros (独占 /dev/ttyACM0):
     docker exec rm-uavsim bash -c 'pkill -9 -f mavros_node'
  2. 跑这个 injector (它会自己开 pymavlink 连 PX4):
     python3 /opt/uav_ws/scripts/px4_vision_injector.py
  3. 同时跑 fake_odom (产 /Odometry):
     ros2 run slam_to_mavros fake_odom_publisher --ros-args -p motion_mode:=circle

输入:
  /Odometry (nav_msgs/Odometry, REP-103 ENU/FLU)

输出:
  MAVLink VISION_POSITION_ESTIMATE (msg 102) 直接发到 PX4 over USB-C

坐标系转换 (跟 px4_visual_odom_bridge.py 一样):
  Position ENU→NED:  (x_ned, y_ned, z_ned) = (y_enu, x_enu, -z_enu)
  Quaternion: FLU→FRD body + ENU→NED world, 用 scipy Rotation 严格转换
"""
from __future__ import annotations

import math
import sys
import time

import numpy as np
from scipy.spatial.transform import Rotation as R

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy

from nav_msgs.msg import Odometry
from pymavlink import mavutil

# Pre-compute frame-change rotations
_R_WORLD = R.from_matrix(np.array([
    [0, 1, 0],
    [1, 0, 0],
    [0, 0, -1],
]))
_R_BODY = R.from_matrix(np.array([
    [1,  0, 0],
    [0, -1, 0],
    [0,  0, -1],
]))


class Px4VisionInjector(Node):
    def __init__(self) -> None:
        super().__init__('px4_vision_injector')

        # ---- parameters ---------------------------------------------------
        self.declare_parameter('odom_topic', '/Odometry')
        self.declare_parameter('px4_device', '/dev/ttyACM0')
        self.declare_parameter('px4_baud', 921600)
        self.declare_parameter('inject_rate_hz', 30.0)
        # covariances (std², 单位跟 VISION_POSITION_ESTIMATE 一致)
        self.declare_parameter('position_noise', 0.1)    # 0.1 m std = 10cm
        self.declare_parameter('angle_noise', 0.1)       # ~18° std
        self.declare_parameter('quality', 100)
        self.declare_parameter('reset_counter', 0)

        odom_topic = self.get_parameter('odom_topic').value
        device = self.get_parameter('px4_device').value
        baud = int(self.get_parameter('px4_baud').value)
        rate_hz = float(self.get_parameter('inject_rate_hz').value)
        self.pos_noise = float(self.get_parameter('position_noise').value)
        self.angle_noise = float(self.get_parameter('angle_noise').value)
        self.quality = int(self.get_parameter('quality').value)
        self.reset_counter = int(self.get_parameter('reset_counter').value)

        # ---- MAVLink connection -------------------------------------------
        self.get_logger().info(f'connecting to PX4 at {device} @ {baud}...')
        self.mav = mavutil.mavlink_connection(device, baud=baud, autoreconnect=True)
        hb = self.mav.wait_heartbeat(timeout=10)
        if not hb:
            self.get_logger().error('no heartbeat from PX4')
            sys.exit(1)
        self.get_logger().info(
            f'PX4 connected sysid={hb.get_srcSystem()} compid={hb.get_srcComponent()}'
        )

        # Request PX4 to stream ESTIMATOR_STATUS + ODOMETRY at 10Hz for monitoring
        self.mav.mav.command_long_send(
            self.mav.target_system, self.mav.target_component,
            mavutil.mavlink.MAV_CMD_SET_MESSAGE_INTERVAL, 0,
            mavutil.mavlink.MAV_MSG_ESTIMATOR_STATUS, 100000,
            0, 0, 0, 0, 0,
        )
        self.mav.mav.command_long_send(
            self.mav.target_system, self.mav.target_component,
            mavutil.mavlink.MAV_CMD_SET_MESSAGE_INTERVAL, 0,
            mavutil.mavlink.MAV_MSG_ODOMETRY, 100000,
            0, 0, 0, 0, 0,
        )

        # ---- ROS2 subscriber ----------------------------------------------
        qos = QoSProfile(reliability=ReliabilityPolicy.BEST_EFFORT,
                         history=HistoryPolicy.KEEP_LAST, depth=10)
        self.sub = self.create_subscription(Odometry, odom_topic, self._on_odom, qos)

        # ---- rate limiter -------------------------------------------------
        self._last_inject_time = 0.0
        self._min_dt = 1.0 / rate_hz if rate_hz > 0 else 0.0

        # bookkeeping
        self._last_position = None
        self._msg_count = 0
        self._injected = 0

        self.get_logger().info(
            f'px4_vision_injector up: {odom_topic} -> VISION_POSITION_ESTIMATE @ {rate_hz}Hz'
        )

    def _on_odom(self, msg: Odometry) -> None:
        now = time.monotonic()
        if self._min_dt > 0 and (now - self._last_inject_time) < self._min_dt:
            return
        self._last_inject_time = now
        self._msg_count += 1

        # ---- convert ENU/FLU → NED/FRD ------------------------------------
        enu_pos = np.array([
            msg.pose.pose.position.x,
            msg.pose.pose.position.y,
            msg.pose.pose.position.z,
        ])
        ned_pos = _R_WORLD.apply(enu_pos)

        q_enu = R.from_quat([
            msg.pose.pose.orientation.x,
            msg.pose.pose.orientation.y,
            msg.pose.pose.orientation.z,
            msg.pose.pose.orientation.w,
        ])
        q_ned = _R_WORLD * q_enu * _R_BODY.inv()
        qx, qy, qz, qw = q_ned.as_quat()

        # ---- SLAM position jump detection (SLAM mode reset_counter) -------
        if self._last_position is not None:
            pos_delta = np.linalg.norm(ned_pos - self._last_position)
            if pos_delta > 0.5:
                self.reset_counter += 1
                self.get_logger().warn(
                    f'position jump {pos_delta:.2f}m, reset_counter -> {self.reset_counter}'
                )
        self._last_position = ned_pos.copy()

        # ---- build covariance for VISION_POSITION_ESTIMATE ---------------
        # MAVLink VISION_POSITION_ESTIMATE.covariance is upper triangle of 6x6
        # Order: x y z roll pitch yaw, 21 elements (variances + correlations)
        # Use diagonal-only (no cross-correlations)
        var_xyz = [self.pos_noise**2] * 3
        var_rpy = [self.angle_noise**2] * 3
        # 21-element upper triangle: [c00, c01, c02, c03, c04, c05,
        #                            c11, c12, c13, c14, c15,
        #                            c22, c23, c24, c25,
        #                            c33, c34, c35,
        #                            c44, c45,
        #                            c55]
        covariance = [
            var_xyz[0], 0, 0, 0, 0, 0,
            0, var_xyz[1], 0, 0, 0,
            0, 0, var_xyz[2], 0, 0,
            0, 0, 0, var_rpy[0], 0,
            0, 0, 0, 0, var_rpy[1],
            0, 0, 0, 0, 0, var_rpy[2],
        ]
        # Pad to 21 elements (some pymavlink versions need exactly 21)
        if len(covariance) > 21:
            covariance = covariance[:21]

        # ---- inject MAVLink VISION_POSITION_ESTIMATE ---------------------
        # msg id 102, fields: usec, x, y, z, roll, pitch, yaw, covariance[21], reset_counter
        # Note: we send rpy separately (NOT quaternion) since VISION_POSITION_ESTIMATE
        # uses RPY convention. Convert q_ned to RPY.
        from scipy.spatial.transform import Rotation as R2
        rpy = R2.from_quat([qx, qy, qz, qw]).as_euler('xyz', degrees=False)

        self.mav.mav.vision_position_estimate_send(
            int(time.time() * 1_000_000),
            float(ned_pos[0]), float(ned_pos[1]), float(ned_pos[2]),
            float(rpy[0]), float(rpy[1]), float(rpy[2]),
            covariance,
            self.reset_counter,
        )
        self._injected += 1
        if self._injected % 30 == 0:
            self.get_logger().info(
                f'injected {self._injected} VISION_POSITION_ESTIMATE msgs, '
                f'last pos NED=({ned_pos[0]:+.3f}, {ned_pos[1]:+.3f}, {ned_pos[2]:+.3f}), '
                f'last rpy=({math.degrees(rpy[0]):+.1f}°, {math.degrees(rpy[1]):+.1f}°, {math.degrees(rpy[2]):+.1f}°)'
            )


def main(args=None):
    rclpy.init(args=args)
    node = Px4VisionInjector()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        try:
            node.destroy_node()
        except Exception:
            pass
        try:
            if rclpy.ok():
                rclpy.shutdown()
        except Exception:
            pass


if __name__ == '__main__':
    main()