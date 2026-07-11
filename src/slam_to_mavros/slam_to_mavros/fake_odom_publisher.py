"""fake_odom_publisher — 不接真实 LiDAR 时, 用这个节点产生假 /Odometry.

用途: 纯 PX4 飞控端到端测试. 把 fake_odom_publisher 的输出当 SLAM 的
      Odometry, 走完整链路:
        /Odometry (fake) -> slam_to_mavros -> /mavros/vision_pose/pose
                                                  -> mavros -> PX4 EKF2

运动模式 (param motion_mode):
    hover    原点悬浮 (带微小噪声), 默认模式. 适合验 PX4 EKF2 是否能 fuse vision pose
    circle   1m 半径水平圆周运动, yaw 持续旋转. 适合验 PX4 跟随能力
    linear   从原点匀速向 +X 方向飞 (1m/s), 适合验单轴跟踪
    random   随机游走 ±0.3m 范围内, 适合压力测试

参数 (declare at launch):
    publish_rate_hz   (float) default 50.0
    motion_mode       (str)   default "hover"
    start_x/y/z       (float) default 0.0
    circle_radius_m   (float) default 1.0
    circle_period_sec (float) default 20.0
    linear_speed_mps  (float) default 1.0
    noise_pos_std_m   (float) default 0.005  (5mm 噪声, 模拟 SLAM 真实输出)
    noise_yaw_std_rad (float) default 0.005
    odom_topic        (str)   default "/Odometry" (slam_to_mavros 订阅的)
    base_frame_id     (str)   default "base_link"
    world_frame_id    (str)   default "odom"
"""
from __future__ import annotations

import math

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy

from geometry_msgs.msg import Quaternion, TransformStamped, TwistStamped
from nav_msgs.msg import Odometry
from tf2_ros import TransformBroadcaster

import math
import random


# --------------------------------------------------------------------------
# Minimal quaternion helper — avoid tf_transformations (not in apt for jammy).
# --------------------------------------------------------------------------
def quaternion_from_euler(roll: float, pitch: float, yaw: float):
    cr = math.cos(roll * 0.5); sr = math.sin(roll * 0.5)
    cp = math.cos(pitch * 0.5); sp = math.sin(pitch * 0.5)
    cy = math.cos(yaw * 0.5); sy = math.sin(yaw * 0.5)
    return (
        sr * cp * cy - cr * sp * sy,
        cr * sp * cy + sr * cp * sy,
        cr * cp * sy - sr * sp * cy,
        cr * cp * cy + sr * sp * sy,
    )


class FakeOdomPublisher(Node):
    """Publishes a synthetic Odometry stream at a fixed rate."""

    def __init__(self) -> None:
        super().__init__('fake_odom_publisher')

        # ---- params --------------------------------------------------------
        self.declare_parameter('publish_rate_hz', 50.0)
        self.declare_parameter('motion_mode', 'hover')
        self.declare_parameter('start_x', 0.0)
        self.declare_parameter('start_y', 0.0)
        self.declare_parameter('start_z', 0.0)
        self.declare_parameter('circle_radius_m', 1.0)
        self.declare_parameter('circle_period_sec', 20.0)
        self.declare_parameter('linear_speed_mps', 1.0)
        self.declare_parameter('noise_pos_std_m', 0.005)
        self.declare_parameter('noise_yaw_std_rad', 0.005)
        self.declare_parameter('odom_topic', '/Odometry')
        self.declare_parameter('base_frame_id', 'base_link')
        self.declare_parameter('world_frame_id', 'odom')

        self.rate_hz = float(self.get_parameter('publish_rate_hz').value)
        self.mode = self.get_parameter('motion_mode').value
        self.start = (
            float(self.get_parameter('start_x').value),
            float(self.get_parameter('start_y').value),
            float(self.get_parameter('start_z').value),
        )
        self.circle_r = float(self.get_parameter('circle_radius_m').value)
        self.circle_T = float(self.get_parameter('circle_period_sec').value)
        self.lin_speed = float(self.get_parameter('linear_speed_mps').value)
        self.noise_pos = float(self.get_parameter('noise_pos_std_m').value)
        self.noise_yaw = float(self.get_parameter('noise_yaw_std_rad').value)
        self.odom_topic = self.get_parameter('odom_topic').value
        self.base_frame_id = self.get_parameter('base_frame_id').value
        self.world_frame_id = self.get_parameter('world_frame_id').value

        # ---- publisher -----------------------------------------------------
        # SLAM-to-mavros subscribes RELIABLE, depth=10 → match here
        qos = QoSProfile(
            reliability=ReliabilityPolicy.RELIABLE,
            history=HistoryPolicy.KEEP_LAST,
            depth=10,
        )
        self.pub_odom = self.create_publisher(
            Odometry, self.odom_topic, qos)

        # Optional: publish /mavros/vision_speed/speed_twist so PX4 EKF2
        # gets velocity from the same source (more stable than pose-only)
        self.declare_parameter('publish_speed', True)
        self.declare_parameter('speed_topic', '/mavros/vision_speed/speed_twist')
        self.pub_speed = self.create_publisher(
            TwistStamped, self.get_parameter('speed_topic').value,
            QoSProfile(reliability=ReliabilityPolicy.BEST_EFFORT,
                       history=HistoryPolicy.KEEP_LAST, depth=10))

        # TF odom -> base_link so rviz shows the fake trajectory
        self.tf_br = TransformBroadcaster(self)

        # ---- timer ---------------------------------------------------------
        period = 1.0 / max(self.rate_hz, 1.0)
        self._t0 = self.get_clock().now().nanoseconds / 1e9
        self._last_t = 0.0
        self._timer = self.create_timer(period, self._tick)
        self._msg_count = 0

        self.get_logger().info(
            f'fake_odom_publisher up: mode={self.mode} rate={self.rate_hz}Hz '
            f'topic={self.odom_topic} start={self.start}')

    # -----------------------------------------------------------------
    def _compute_pose(self, t: float):
        """Returns (x, y, z, roll, pitch, yaw) given elapsed seconds."""
        if self.mode == 'hover':
            x = self.start[0] + random.gauss(0, self.noise_pos)
            y = self.start[1] + random.gauss(0, self.noise_pos)
            z = self.start[2] + random.gauss(0, self.noise_pos)
            roll = random.gauss(0, self.noise_yaw)
            pitch = random.gauss(0, self.noise_yaw)
            yaw = random.gauss(0, self.noise_yaw)

        elif self.mode == 'circle':
            omega = 2.0 * math.pi / self.circle_T
            x = self.start[0] + self.circle_r * math.cos(omega * t)
            y = self.start[1] + self.circle_r * math.sin(omega * t)
            z = self.start[2]
            roll = 0.0
            pitch = 0.0
            yaw = (omega * t + math.pi / 2) % (2 * math.pi)  # tangent to circle
            # add small noise
            x += random.gauss(0, self.noise_pos)
            y += random.gauss(0, self.noise_pos)
            yaw += random.gauss(0, self.noise_yaw)

        elif self.mode == 'linear':
            x = self.start[0] + self.lin_speed * t
            y = self.start[1]
            z = self.start[2]
            roll = 0.0
            pitch = 0.0
            yaw = 0.0

        elif self.mode == 'random':
            # bounded random walk ~ uniform in [-0.3, 0.3]
            x = self.start[0] + (random.random() - 0.5) * 0.6
            y = self.start[1] + (random.random() - 0.5) * 0.6
            z = self.start[2] + (random.random() - 0.5) * 0.2
            roll = 0.0
            pitch = 0.0
            yaw = (random.random() - 0.5) * 0.4

        else:
            self.get_logger().warn(f'unknown mode "{self.mode}", falling back to hover')
            x, y, z, roll, pitch, yaw = (*self.start, 0.0, 0.0, 0.0)

        return x, y, z, roll, pitch, yaw

    # -----------------------------------------------------------------
    def _compute_velocity(self, x, y, z, t):
        """Naive numerical velocity (m/s) by finite difference."""
        dt = t - self._last_t
        if dt <= 0 or self._last_t == 0.0:
            return 0.0, 0.0, 0.0
        # we need last pose for accurate vel — approximate by recomputing at t-dt
        lx, ly, lz, _, _, _ = self._compute_pose(t - dt)
        vx = (x - lx) / dt
        vy = (y - ly) / dt
        vz = (z - lz) / dt
        return vx, vy, vz

    # -----------------------------------------------------------------
    def _tick(self) -> None:
        now = self.get_clock().now()
        t = now.nanoseconds / 1e9 - self._t0

        x, y, z, roll, pitch, yaw = self._compute_pose(t)
        vx, vy, vz = self._compute_velocity(x, y, z, t)

        qx, qy, qz, qw = quaternion_from_euler(roll, pitch, yaw)

        # ---- publish /Odometry -----------------------------------------
        msg = Odometry()
        msg.header.stamp = now.to_msg()
        msg.header.frame_id = self.world_frame_id
        msg.child_frame_id = self.base_frame_id
        msg.pose.pose.position.x = x
        msg.pose.pose.position.y = y
        msg.pose.pose.position.z = z
        msg.pose.pose.orientation.x = qx
        msg.pose.pose.orientation.y = qy
        msg.pose.pose.orientation.z = qz
        msg.pose.pose.orientation.w = qw
        # Covariance (a small one to make EKF2 trust vision more)
        for i in (0, 7, 14):
            msg.pose.covariance[i] = 0.01  # 0.01 m^2
        msg.twist.twist.linear.x = vx
        msg.twist.twist.linear.y = vy
        msg.twist.twist.linear.z = vz
        self.pub_odom.publish(msg)

        # ---- publish /mavros/vision_speed/speed_twist ------------------
        if self.pub_speed.get_subscription_count() > 0:
            ts = TwistStamped()
            ts.header = msg.header
            ts.twist.linear.x = vx
            ts.twist.linear.y = vy
            ts.twist.linear.z = vz
            self.pub_speed.publish(ts)

        # ---- publish TF odom -> base_link -------------------------------
        tf = TransformStamped()
        tf.header = msg.header
        tf.header.frame_id = self.world_frame_id
        tf.child_frame_id = self.base_frame_id
        tf.transform.translation.x = x
        tf.transform.translation.y = y
        tf.transform.translation.z = z
        tf.transform.rotation.x = qx
        tf.transform.rotation.y = qy
        tf.transform.rotation.z = qz
        tf.transform.rotation.w = qw
        self.tf_br.sendTransform(tf)

        self._msg_count += 1
        self._last_t = t


def main(args=None) -> None:
    rclpy.init(args=args)
    node = FakeOdomPublisher()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    except Exception as e:                       # noqa: BLE001
        node.get_logger().error(f'unhandled: {e}', throttle_duration_sec=5.0)
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