#!/usr/bin/env python3
"""stop_and_go_fake_odom.py — 严格的 stop-and-go 测试用 fake_odom.

每 5 秒移动到一个新位置:
    t=[0, 5)  : (0, 0)        # 静止起始
    t=[5, 10) : (5, 0)        # 突跳 5m 东
    t=[10, 15): (5, 5)        # 突跳 5m 北
    t=[15, 20): (0, 5)        # 突跳 5m 西
    t=[20, 25): (0, 0)        # 回原点
    t=[25, 30): (3, 3)        # 最后再来一个
"""
from __future__ import annotations
import time
import random

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
from nav_msgs.msg import Odometry


COVARIANCE_36 = [
    0.01, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.0, 0.01, 0.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.01, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 0.01, 0.0, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.01, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0, 0.01,
]


class StopAndGoFakeOdom(Node):
    def __init__(self):
        super().__init__('stop_and_go_fake_odom')
        self.declare_parameter('publish_rate_hz', 50.0)
        self.declare_parameter('noise_pos_std_m', 0.005)
        self.declare_parameter('odom_topic', '/Odometry')

        rate_hz = float(self.get_parameter('publish_rate_hz').value)
        self.noise_std = float(self.get_parameter('noise_pos_std_m').value)
        odom_topic = self.get_parameter('odom_topic').value

        self.schedule = [
            (0, 5, 0.0, 0.0),
            (5, 10, 5.0, 0.0),
            (10, 15, 5.0, 5.0),
            (15, 20, 0.0, 5.0),
            (20, 25, 0.0, 0.0),
            (25, 30, 3.0, 3.0),
        ]

        self.start_t = time.monotonic()
        self.last_pos = (0.0, 0.0)
        self._msg_count = 0
        self._seg_count = 0

        qos = QoSProfile(reliability=ReliabilityPolicy.RELIABLE, depth=10)
        self.pub = self.create_publisher(Odometry, odom_topic, qos)
        self.timer = self.create_timer(1.0 / rate_hz, self._tick)
        self.get_logger().info(
            f'stop_and_go_fake_odom: {len(self.schedule)} segments, '
            f'{1/rate_hz*1000:.0f}ms rate'
        )

    def _tick(self):
        t = time.monotonic() - self.start_t
        seg_x, seg_y = 0.0, 0.0
        for (ts, te, tx, ty) in self.schedule:
            if ts <= t < te:
                seg_x, seg_y = tx, ty
                break

        x = seg_x + random.gauss(0, self.noise_std)
        y = seg_y + random.gauss(0, self.noise_std)

        new_pos = (round(seg_x, 2), round(seg_y, 2))
        if new_pos != self.last_pos:
            self._seg_count += 1
            self.get_logger().info(
                f'>>> SEG {self._seg_count}: t={t:.1f}s target=({seg_x}, {seg_y})'
            )
            self.last_pos = new_pos

        msg = Odometry()
        msg.header.stamp = self.get_clock().now().to_msg()
        msg.header.frame_id = 'odom'
        msg.child_frame_id = 'base_link'
        msg.pose.pose.position.x = x
        msg.pose.pose.position.y = y
        msg.pose.pose.position.z = 0.0
        msg.pose.pose.orientation.w = 1.0
        msg.pose.covariance = COVARIANCE_36[:]  # COPY so ROS2 doesn't share buffer

        self.pub.publish(msg)
        self._msg_count += 1
        if self._msg_count % 100 == 0:
            self.get_logger().info(
                f't={t:.1f}s msg={self._msg_count} pos=({x:.3f},{y:.3f})'
            )

        if t > 30:
            self.get_logger().info(f'DONE t={t:.1f}s')
            self.timer.cancel()
            raise SystemExit(0)


def main(args=None):
    rclpy.init(args=args)
    node = StopAndGoFakeOdom()
    try:
        rclpy.spin(node)
    except (KeyboardInterrupt, SystemExit):
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