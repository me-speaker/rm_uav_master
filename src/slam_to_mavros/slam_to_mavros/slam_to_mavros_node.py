"""slam_to_mavros_node — FAST-LIO Odometry -> MAVROS /vision_pose/* bridge.

v0.1.0 design (direct mode, indoor SLAM flight)
----------------------------------------------
FAST-LIO publishes nav_msgs/Odometry on `/Odometry`:
    header.frame_id        = "camera_init" (first LiDAR frame as world)
    child_frame_id         = "base_link" (or "livox_frame" depending on config)
    pose.pose              = T_world_base   (position+orientation of drone in world)

PX4 EKF2 needs to receive visual odometry as `geometry_msgs/PoseStamped` on
`/mavros/vision_pose/pose`, in the NED frame, with `frame_id = "map"` (the
MAVROS convention used by px4_config.yaml's tf block).

Strategy:
    1. Apply static extrinsic T_lidar->base_link  (lidar mount offset on drone)
    2. Apply static initial-alignment T_world->map   (= identity in direct mode)
    3. Republish to /mavros/vision_pose/pose with frame_id="map"
    4. Broadcast TF map -> odom (static, identity) and odom -> base_link
       (dynamic, taken straight from FAST-LIO pose)

Coordinate conventions:
    - All ROS-side frames follow REP-103 (ENU).
    - PX4 internally converts ROS ENU <-> NED via the MAVROS frame transform.
    - We DO NOT pre-rotate to NED here — that is MAVROS's job. We publish
      in ROS ENU, frame_id="map".

Parameters (declare at launch):
    odom_topic           (str)   default "/Odometry"
    vision_pose_topic    (str)   default "/mavros/vision_pose/pose"
    vision_speed_topic   (str)   default "/mavros/vision_speed/speed_twist"
    world_frame_id       (str)   default "map"          (PX4 expects "map")
    odom_frame_id        (str)   default "odom"         (MAVROS tf child of map)
    base_frame_id        (str)   default "base_link"    (drone body)
    lidar_frame_id       (str)   default "livox_frame"  (FAST-LIO input frame)
    lidar_to_base_xyz    (list)  default [0.0, 0.0, 0.0]   (m)
    lidar_to_base_rpy    (list)  default [0.0, 0.0, 0.0]   (rad, roll/pitch/yaw)
    publish_tf           (bool)  default True
    publish_speed        (bool)  default True
    publish_vision_pose  (bool)  default True
    target_rate_hz       (float) default 50.0  (max republish rate; FAST-LIO
                                                 itself runs at scan rate)
    frame_timeout_sec    (float) default 1.0   (warn if no /Odometry in N s)

This node does NOT do its own time-loop: it republishes synchronously on
incoming /Odometry messages (FAST-LIO drives the rate). target_rate_hz is
only used to enforce a minimum spacing between successive publishes.
"""
from __future__ import annotations

import math
import time

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy

from geometry_msgs.msg import PoseStamped, TransformStamped, TwistStamped
from nav_msgs.msg import Odometry
from tf2_ros import StaticTransformBroadcaster, TransformBroadcaster


# --------------------------------------------------------------------------
# Minimal quaternion helpers (avoid pulling in tf_transformations which is
# not packaged for Ubuntu 22.04 apt). API matches a subset of
# tf_transformations: quaternion_from_euler / quaternion_multiply.
# --------------------------------------------------------------------------
def quaternion_from_euler(roll: float, pitch: float, yaw: float):
    """Return (x, y, z, w) from roll/pitch/yaw (rad)."""
    cr = math.cos(roll * 0.5)
    sr = math.sin(roll * 0.5)
    cp = math.cos(pitch * 0.5)
    sp = math.sin(pitch * 0.5)
    cy = math.cos(yaw * 0.5)
    sy = math.sin(yaw * 0.5)
    return (
        sr * cp * cy - cr * sp * sy,   # x
        cr * sp * cy + sr * cp * sy,   # y
        cr * cp * sy - sr * sp * cy,   # z
        cr * cp * cy + sr * sp * sy,   # w
    )


def quaternion_multiply(a, b):
    """Hamilton product q = a * b. a, b as (x, y, z, w). Returns (x, y, z, w)."""
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz,
    )


class SlamToMavros(Node):
    """Republish FAST-LIO /Odometry as MAVROS vision-pose messages + TF."""

    def __init__(self) -> None:
        super().__init__('slam_to_mavros')

        # ---- parameters -----------------------------------------------------
        self.declare_parameter('odom_topic', '/Odometry')
        self.declare_parameter('vision_pose_topic', '/mavros/vision_pose/pose')
        self.declare_parameter('vision_speed_topic', '/mavros/vision_speed/speed_twist')
        self.declare_parameter('world_frame_id', 'map')
        self.declare_parameter('odom_frame_id', 'odom')
        self.declare_parameter('base_frame_id', 'base_link')
        self.declare_parameter('lidar_frame_id', 'livox_frame')
        self.declare_parameter('lidar_to_base_xyz', [0.0, 0.0, 0.0])
        self.declare_parameter('lidar_to_base_rpy', [0.0, 0.0, 0.0])
        self.declare_parameter('publish_tf', True)
        self.declare_parameter('publish_speed', True)
        self.declare_parameter('publish_vision_pose', True)
        self.declare_parameter('target_rate_hz', 50.0)
        self.declare_parameter('frame_timeout_sec', 1.0)

        self.odom_topic          = self.get_parameter('odom_topic').value
        self.vision_pose_topic   = self.get_parameter('vision_pose_topic').value
        self.vision_speed_topic  = self.get_parameter('vision_speed_topic').value
        self.world_frame_id      = self.get_parameter('world_frame_id').value
        self.odom_frame_id       = self.get_parameter('odom_frame_id').value
        self.base_frame_id       = self.get_parameter('base_frame_id').value
        self.lidar_frame_id      = self.get_parameter('lidar_frame_id').value
        xyz                      = self.get_parameter('lidar_to_base_xyz').value
        rpy                      = self.get_parameter('lidar_to_base_rpy').value
        self.publish_tf          = bool(self.get_parameter('publish_tf').value)
        self.publish_speed       = bool(self.get_parameter('publish_speed').value)
        self.publish_vision_pose = bool(self.get_parameter('publish_vision_pose').value)
        self.target_rate_hz      = float(self.get_parameter('target_rate_hz').value)
        self.frame_timeout_sec   = float(self.get_parameter('frame_timeout_sec').value)

        # ---- extrinsic: lidar_frame -> base_link ---------------------------
        # FAST-LIO outputs pose of the lidar (in its world frame). To convert
        # to pose of the drone body we apply T_lidar->base once. Stored as a
        # quaternion for cheap math.
        self.q_lb = quaternion_from_euler(float(rpy[0]), float(rpy[1]), float(rpy[2]))
        self.t_lb = (float(xyz[0]), float(xyz[1]), float(xyz[2]))

        # ---- publishers -----------------------------------------------------
        qos = QoSProfile(
            reliability=ReliabilityPolicy.RELIABLE,
            history=HistoryPolicy.KEEP_LAST,
            depth=10,
        )
        # MAVROS vision-pose expects BEST_EFFORT in some plugin paths; we use
        # RELIABLE which works with the default px4_config.yaml (MAVROS
        # internally downgrades to BEST_EFFORT for PX4 uXRCE-DDS).
        mavros_qos = QoSProfile(
            reliability=ReliabilityPolicy.BEST_EFFORT,
            history=HistoryPolicy.KEEP_LAST,
            depth=10,
        )
        self.pub_pose = self.create_publisher(
            PoseStamped, self.vision_pose_topic, mavros_qos)
        self.pub_twist = self.create_publisher(
            TwistStamped, self.vision_speed_topic, mavros_qos)
        self.tf_br = TransformBroadcaster(self)
        self.tf_static = StaticTransformBroadcaster(self)

        # ---- subscriber -----------------------------------------------------
        self.sub = self.create_subscription(
            Odometry, self.odom_topic, self._on_odom, qos)

        # ---- bookkeeping ---------------------------------------------------
        self._last_pub_time = 0.0
        self._last_odom_time = 0.0
        self._msg_count = 0

        # ---- static TF: map -> odom (identity in direct mode) --------------
        # PX4's MAVROS vision_pose plugin publishes T_map->base_link = pose.
        # MAVROS also handles `tf` config (in px4_config.yaml). We publish
        # map->odom as identity here so tf_tree stays consistent and rviz
        # shows the SLAM trajectory correctly.
        if self.publish_tf:
            self._broadcast_static_map_to_odom()

        # ---- watchdog timer ------------------------------------------------
        self._wd_timer = self.create_timer(
            max(0.1, self.frame_timeout_sec), self._watchdog)

        self.get_logger().info(
            f'slam_to_mavros up: odom={self.odom_topic} '
            f'-> pose={self.vision_pose_topic} twist={self.vision_speed_topic} '
            f'world={self.world_frame_id} base={self.base_frame_id} '
            f'lidar={self.lidar_frame_id} '
            f'extrinsic xyz={self.t_lb} rpy={rpy} '
            f'target_rate={self.target_rate_hz}Hz')

    # ---------------------------------------------------------------------
    def _broadcast_static_map_to_odom(self) -> None:
        t = TransformStamped()
        t.header.stamp = self.get_clock().now().to_msg()
        t.header.frame_id = self.world_frame_id
        t.child_frame_id = self.odom_frame_id
        t.transform.translation.x = 0.0
        t.transform.translation.y = 0.0
        t.transform.translation.z = 0.0
        t.transform.rotation.x = 0.0
        t.transform.rotation.y = 0.0
        t.transform.rotation.z = 0.0
        t.transform.rotation.w = 1.0
        self.tf_static.sendTransform(t)
        self.get_logger().info(
            f'published static TF {self.world_frame_id} -> {self.odom_frame_id} (identity)')

    # ---------------------------------------------------------------------
    def _on_odom(self, msg: Odometry) -> None:
        self._last_odom_time = time.monotonic()

        # rate limit
        now = time.monotonic()
        if self.target_rate_hz > 0.0:
            min_dt = 1.0 / self.target_rate_hz
            if now - self._last_pub_time < min_dt:
                return
        self._last_pub_time = now
        self._msg_count += 1

        # T_world_lidar = pose from FAST-LIO
        q_wl = (
            msg.pose.pose.orientation.x,
            msg.pose.pose.orientation.y,
            msg.pose.pose.orientation.z,
            msg.pose.pose.orientation.w,
        )
        t_wl = (
            msg.pose.pose.position.x,
            msg.pose.pose.position.y,
            msg.pose.pose.position.z,
        )

        # T_world_base = T_world_lidar * T_lidar_base
        q_wb = quaternion_multiply(q_wl, self.q_lb)
        # rotation-only translation: t_wb = t_wl + R_wl * t_lb
        # We compute R_wl * t_lb by rotating t_lb through q_wl.
        t_rot = self._rotate_vector_by_quaternion(self.t_lb, q_wl)
        t_wb = (
            t_wl[0] + t_rot[0],
            t_wl[1] + t_rot[1],
            t_wl[2] + t_rot[2],
        )

        # Publish vision pose
        if self.publish_vision_pose:
            ps = PoseStamped()
            ps.header = msg.header
            # PX4 expects frame_id to match MAVROS tf config; px4_config.yaml
            # defaults to "map".
            ps.header.frame_id = self.world_frame_id
            ps.pose.position.x = t_wb[0]
            ps.pose.position.y = t_wb[1]
            ps.pose.position.z = t_wb[2]
            ps.pose.orientation.x = q_wb[0]
            ps.pose.orientation.y = q_wb[1]
            ps.pose.orientation.z = q_wb[2]
            ps.pose.orientation.w = q_wb[3]
            self.pub_pose.publish(ps)

        # Publish twist (linear only — FAST-LIO publishes angular velocity
        # from IMU but expressed in odom frame; PX4 doesn't fuse it via
        # vision_speed, so we leave it out to avoid double-counting with
        # PX4's own gyro).
        if self.publish_speed:
            ts = TwistStamped()
            ts.header = msg.header
            ts.header.frame_id = self.world_frame_id
            ts.twist.linear.x = msg.twist.twist.linear.x
            ts.twist.linear.y = msg.twist.twist.linear.y
            ts.twist.linear.z = msg.twist.twist.linear.z
            self.pub_twist.publish(ts)

        # Publish TF odom -> base_link (dynamic, from FAST-LIO pose)
        if self.publish_tf:
            tf = TransformStamped()
            tf.header = msg.header
            tf.header.frame_id = self.odom_frame_id
            tf.child_frame_id = self.base_frame_id
            tf.transform.translation.x = t_wl[0]
            tf.transform.translation.y = t_wl[1]
            tf.transform.translation.z = t_wl[2]
            tf.transform.rotation.x = q_wl[0]
            tf.transform.rotation.y = q_wl[1]
            tf.transform.rotation.z = q_wl[2]
            tf.transform.rotation.w = q_wl[3]
            self.tf_br.sendTransform(tf)

    # ---------------------------------------------------------------------
    def _watchdog(self) -> None:
        if self._last_odom_time == 0.0:
            return  # never received anything yet
        gap = time.monotonic() - self._last_odom_time
        if gap > self.frame_timeout_sec:
            self.get_logger().warn(
                f'no /Odometry for {gap:.2f}s (>{self.frame_timeout_sec}s) — '
                f'check FAST-LIO / livox driver', throttle_duration_sec=5.0)

    # ---------------------------------------------------------------------
    @staticmethod
    def _rotate_vector_by_quaternion(v, q):
        """Rotate vector v by quaternion q. v, q as 3-tuple / 4-tuple."""
        vx, vy, vz = v
        qx, qy, qz, qw = q
        # t = 2 * cross(q.xyz, v)
        tx = 2.0 * (qy * vz - qz * vy)
        ty = 2.0 * (qz * vx - qx * vz)
        tz = 2.0 * (qx * vy - qy * vx)
        # v' = v + qw * t + cross(q.xyz, t)
        rx = vx + qw * tx + (qy * tz - qz * ty)
        ry = vy + qw * ty + (qz * tx - qx * tz)
        rz = vz + qw * tz + (qx * ty - qy * tx)
        return (rx, ry, rz)


def main(args=None) -> None:
    rclpy.init(args=args)
    node = SlamToMavros()
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
