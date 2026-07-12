#!/usr/bin/env python3
"""假 ODIN odometry, 模拟运动, 看 PX4 EKF2 是否真的在用 vision.

替代物理晃 ODIN. 直接发 /odin1/odometry 消息 (Odometry type) 模拟 ODIN 在动.

跑法 (在容器里):
    python3 /opt/uav_ws/scripts/fake_odin_motion.py

它会发 30 秒, 走 1m 半径圆 (clockwise), 然后退出.
同时 mavros/launch_uav 必须跑着.
"""
import sys
import time
import math

import rclpy
from rclpy.node import Node
from nav_msgs.msg import Odometry


class FakeODIN(Node):
    def __init__(self):
        super().__init__('fake_odin')
        self.pub = self.create_publisher(Odometry, '/odin1/odometry', 10)
        # IMPORTANT: QoS RELIABLE 才能跟 host_sdk QoS 兼容
        self.timer = self.create_timer(0.1, self.publish)  # 10Hz
        self.t0 = time.time()
        self.radius = 1.0  # 1m circle
        self.omega = 0.5   # rad/s, 周期 ~12.6s
        self.get_logger().info('fake_odin started, will publish 1m circle for 30s')

    def publish(self):
        elapsed = time.time() - self.t0
        if elapsed > 30:
            self.get_logger().info(f'30s done. final position: x={self.radius*math.cos(self.omega*elapsed):.3f} y={self.radius*math.sin(self.omega*elapsed):.3f}')
            rclpy.shutdown()
            return
        # 走圆, x = R cos(ωt), y = R sin(ωt)
        x = self.radius * math.cos(self.omega * elapsed)
        y = self.radius * math.sin(self.omega * elapsed)
        z = 0.0
        # 朝向也跟圆切线对齐 (简化: 固定为 0)
        qx, qy, qz, qw = 0.0, 0.0, 0.0, 1.0
        # covariance: 跟 slam_to_mavros 默认给的一致 (5cm pos, 30° rot)
        cov = [0.0025] + [0.0]*5 + [0.0, 0.0025] + [0.0]*4 + \
              [0.0, 0.0, 0.0025] + [0.0]*3 + \
              [0.0]*3 + [0.25] + [0.0]*2 + \
              [0.0]*4 + [0.25] + [0.0] + \
              [0.0]*5 + [0.25]

        msg = Odometry()
        msg.header.stamp = self.get_clock().now().to_msg()
        msg.header.frame_id = 'odom'
        msg.child_frame_id = 'odin1_base_link'
        msg.pose.pose.position.x = x
        msg.pose.pose.position.y = y
        msg.pose.pose.position.z = z
        msg.pose.pose.orientation.x = qx
        msg.pose.pose.orientation.y = qy
        msg.pose.pose.orientation.z = qz
        msg.pose.pose.orientation.w = qw
        msg.pose.covariance = cov
        msg.twist.twist.linear.x = -self.radius * self.omega * math.sin(self.omega * elapsed)
        msg.twist.twist.linear.y =  self.radius * self.omega * math.cos(self.omega * elapsed)
        msg.twist.twist.linear.z = 0.0
        msg.twist.covariance = [0.01]*36
        self.pub.publish(msg)
        if int(elapsed) % 5 == 0:
            self.get_logger().info(f't={elapsed:.1f}s x={x:.3f} y={y:.3f}')


def main():
    rclpy.init()
    node = FakeODIN()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    node.destroy_node()
    rclpy.shutdown()


if __name__ == '__main__':
    main()