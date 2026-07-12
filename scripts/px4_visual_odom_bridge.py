#!/usr/bin/env python3
"""px4_visual_odom_bridge.py — /Odometry (REP-103 ENU/FLU) → PX4 VehicleOdometry (NED/FRD).

PX4 v1.17 micro-xrce-dds 链路:
  /Odometry (nav_msgs/Odometry)
        ↓
  px4_visual_odom_bridge (this)
        ↓
  /fmu/in/vehicle_visual_odometry (px4_msgs/VehicleOdometry)
        ↓ (micro-xrce-dds-agent)
  PX4 uXRCE-DDS-Client
        ↓ (uORB)
  PX4 EKF2 → VehicleOdometry fused pose

坐标系转换 (用 scipy.spatial.transform.Rotation 严格推导):
    ROS REP-103:
        World: ENU = (East, North, Up)
        Body : FLU = (Forward, Left, Up)
    PX4:
        World: NED = (North, East, Down)
        Body : FRD = (Forward, Right, Down)

    转换矩阵:
        World ENU→NED:
            [[0, 1, 0],
             [1, 0, 0],
             [0, 0, -1]]
            (相当于 180° rotation about axis (1,1,0)/√2)
        Body FLU→FRD:
            [[1, 0, 0],
             [0,-1, 0],
             [0, 0,-1]]
            (180° rotation about X)

    Quaternion 转换 (frame change composition):
        q_ned_frd = R_world · q_enu_flu · R_body^(-1)
        其中 R_world, R_body 是 frame change rotations

    Velocity (linear): 同样按 R_world 应用到 ENU linear velocity
    Angular velocity (body): 按 R_body 应用到 FLU angular velocity (注意 angular
        velocity 在 body frame 下 frame change 是 R_body, 不是 R_body^(-1))
"""
from __future__ import annotations

import math
import time

import numpy as np
from scipy.spatial.transform import Rotation as R

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy

from nav_msgs.msg import Odometry
from px4_msgs.msg import VehicleOdometry


# Pre-compute frame-change rotations as scipy Rotation objects
# (computed once at module load for efficiency)
_R_WORLD = R.from_matrix(np.array([
    [0, 1, 0],
    [1, 0, 0],
    [0, 0, -1],
]))  # ENU → NED world frame change
_R_BODY = R.from_matrix(np.array([
    [1,  0, 0],
    [0, -1, 0],
    [0,  0, -1],
]))  # FLU → FRD body frame change


class Px4VisualOdomBridge(Node):
    def __init__(self) -> None:
        super().__init__('px4_visual_odom_bridge')

        # ---- parameters ---------------------------------------------------
        self.declare_parameter('odom_topic', '/Odometry')
        self.declare_parameter('px4_topic', '/fmu/in/vehicle_visual_odometry')
        # EKF2 noise params (px4 expects variances = std²)
        self.declare_parameter('position_variance', 0.01)    # 10cm std → 0.01 var
        self.declare_parameter('orientation_variance', 0.05)  # ~13° std
        self.declare_parameter('velocity_variance', 0.05)
        # Quality: -1 = don't check (推荐用 -1 让 EKF2_EV_QMIN=0 不卡 quality)
        self.declare_parameter('quality', -1)

        odom_topic = self.get_parameter('odom_topic').value
        px4_topic = self.get_parameter('px4_topic').value
        self.pos_var = float(self.get_parameter('position_variance').value)
        self.rot_var = float(self.get_parameter('orientation_variance').value)
        self.vel_var = float(self.get_parameter('velocity_variance').value)
        self.quality = int(self.get_parameter('quality').value)

        # ---- QoS ----------------------------------------------------------
        # PX4 sensor best practice: BEST_EFFORT + VOLATILE for high-rate sensor data.
        # PX4 ignores TRANSIENT_LOCAL on /fmu/in/* since it expects fresh data.
        qos = QoSProfile(
            reliability=ReliabilityPolicy.BEST_EFFORT,
            history=HistoryPolicy.KEEP_LAST,
            depth=10,
        )

        # ---- subscriber / publisher ---------------------------------------
        self.sub = self.create_subscription(Odometry, odom_topic, self._on_odom, qos)
        self.pub = self.create_publisher(VehicleOdometry, px4_topic, qos)

        # Track reset_counter for SLAM jumps (e.g., relocalization)
        self._last_position = None
        self._reset_counter = 0

        self._msg_count = 0
        self.get_logger().info(
            f'px4_visual_odom_bridge up: {odom_topic} -> {px4_topic} '
            f'(pos_var={self.pos_var}, rot_var={self.rot_var}, quality={self.quality})'
        )

    def _on_odom(self, msg: Odometry) -> None:
        # ---- 1) Position ENU → NED -----------------------------------------
        # ENU position: x=East, y=North, z=Up
        # NED position: x=North, y=East, z=Down
        enu_pos = np.array([
            msg.pose.pose.position.x,
            msg.pose.pose.position.y,
            msg.pose.pose.position.z,
        ])
        ned_pos = _R_WORLD.apply(enu_pos)

        # ---- 2) Orientation FLU/ENU → FRD/NED -----------------------------
        # Use scipy for clean composition:
        #   q_ned = R_world · q_enu · R_body^(-1)
        # ROS quaternion is (x, y, z, w); scipy expects same order.
        q_enu = R.from_quat([
            msg.pose.pose.orientation.x,
            msg.pose.pose.orientation.y,
            msg.pose.pose.orientation.z,
            msg.pose.pose.orientation.w,
        ])
        q_ned = _R_WORLD * q_enu * _R_BODY.inv()
        # Convert back to (x, y, z, w)
        qx, qy, qz, qw = q_ned.as_quat()

        # ---- 3) Velocity ENU → NED -----------------------------------------
        enu_vel = np.array([
            msg.twist.twist.linear.x,
            msg.twist.twist.linear.y,
            msg.twist.twist.linear.z,
        ])
        ned_vel = _R_WORLD.apply(enu_vel)

        # ---- 4) Angular velocity FLU body → FRD body -----------------------
        # Angular velocity is in body-fixed frame.
        # For body frame change: apply R_body directly (not R_body^(-1))
        flu_angvel = np.array([
            msg.twist.twist.angular.x,
            msg.twist.twist.angular.y,
            msg.twist.twist.angular.z,
        ])
        frd_angvel = _R_BODY.apply(flu_angvel)

        # ---- 5) Detect SLAM position jump (reset_counter logic) ------------
        if self._last_position is not None:
            pos_delta = np.linalg.norm(ned_pos - self._last_position)
            # 0.5m threshold for "jump" detection
            if pos_delta > 0.5:
                self._reset_counter += 1
                self.get_logger().warn(
                    f'position jump detected ({pos_delta:.2f}m), '
                    f'reset_counter -> {self._reset_counter}'
                )
        self._last_position = ned_pos.copy()

        # ---- 6) Build VehicleOdometry message -------------------------------
        out = VehicleOdometry()
        # PX4 uXRCE-DDS 时间戳: 微秒, 系统启动起算. 用 0 让 PX4 用自身时间.
        out.timestamp = 0
        out.timestamp_sample = 0

        # pose_frame = NED (1)
        out.pose_frame = VehicleOdometry.POSE_FRAME_NED
        out.position = [float(ned_pos[0]), float(ned_pos[1]), float(ned_pos[2])]
        # VehicleOdometry quaternion is [w, x, y, z] order
        out.q = [float(qw), float(qx), float(qy), float(qz)]

        # velocity_frame = NED (1)
        out.velocity_frame = VehicleOdometry.VELOCITY_FRAME_NED
        out.velocity = [float(ned_vel[0]), float(ned_vel[1]), float(ned_vel[2])]
        # angular_velocity is in body-fixed FRD
        out.angular_velocity = [float(frd_angvel[0]), float(frd_angvel[1]), float(frd_angvel[2])]

        # variances (var = std²); EKF2_EV_NOISE_MD=0 means use these values
        out.position_variance = [self.pos_var, self.pos_var, self.pos_var]
        out.orientation_variance = [self.rot_var, self.rot_var, self.rot_var]
        out.velocity_variance = [self.vel_var, self.vel_var, self.vel_var]

        out.reset_counter = self._reset_counter
        out.quality = self.quality

        self.pub.publish(out)
        self._msg_count += 1
        if self._msg_count % 50 == 0:
            self.get_logger().info(
                f'sent {self._msg_count} vehicle_visual_odometry msgs, '
                f'last pos NED=({ned_pos[0]:+.3f}, {ned_pos[1]:+.3f}, {ned_pos[2]:+.3f}), '
                f'quat=({qx:+.3f},{qy:+.3f},{qz:+.3f},{qw:+.3f})'
            )


def main(args=None):
    rclpy.init(args=args)
    node = Px4VisualOdomBridge()
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