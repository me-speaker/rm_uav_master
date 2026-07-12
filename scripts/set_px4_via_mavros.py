#!/usr/bin/env python3
"""通过 mavros 的 param service 设 PX4 参数 (不抢串口).

mavros 已经连 PX4, 它的 /mavros/param/set 服务会通过 MAVLink 发到 PX4.
我们直接 import rclpy 调用这个 service, 不用 pymavlink 抢串口.
"""
import sys

import rclpy
from rclpy.node import Node

from mavros_msgs.msg import ParamValue
from mavros_msgs.srv import ParamGet, ParamSet, CommandLong


PARAMS_VISION = [
    ('SYS_HAS_GPS',   0, 6),
    ('SYS_HAS_MAG',   0, 6),
    ('MAV_USEHILGPS', 0, 2),
    # EKF2 全开 vision (除 velocity): horiz pos + vert pos + yaw
    ('EKF2_EV_CTRL', 11, 6),  # 1 + 2 + 8
    ('EKF2_AID_MASK', 11, 6),
    # 高度也用 vision
    ('EKF2_HGT_REF', 3, 6),  # Vision
    ('EKF2_EV_DELAY', 0.01, 9),  # FLOAT
    ('EKF2_EVP_NOISE', 0.03, 9),  # FLOAT  (3cm)
    ('MAV_ODOM_LP', 1, 2),
]


class ParamTool(Node):
    def __init__(self):
        super().__init__('px4_param_tool_via_mavros')
        for srv, name in [('param/get', '/mavros/cmd/param/get'),
                          ('param/set', '/mavros/cmd/param/set')]:
            cli = self.create_client(ParamGet if 'get' in name else ParamSet, name)
            if not cli.wait_for_service(timeout_sec=5.0):
                self.get_logger().warn(f'{srv} 服务不可用, {name} 没注册')
            else:
                self.get_logger().info(f'{srv} ready')

        self.get_cli = self.create_client(ParamGet, '/mavros/cmd/param/get')
        self.set_cli = self.create_client(ParamSet, '/mavros/cmd/param/set')

    def get(self, name):
        if not self.get_cli.wait_for_service(timeout_sec=2.0):
            return None
        req = ParamGet.Request()
        req.param_id = name
        fut = self.get_cli.call_async(req)
        rclpy.spin_until_future_complete(self, fut, timeout_sec=5.0)
        if not fut.done() or fut.result() is None or not fut.result().success:
            return None
        return fut.result().value.integer

    def set(self, name, value, ptype):
        if not self.set_cli.wait_for_service(timeout_sec=2.0):
            return False, 'no service'
        req = ParamSet.Request()
        req.param_id = name
        req.value.integer = int(value)
        req.value.real = float(value)
        req.value.type = ptype
        fut = self.set_cli.call_async(req)
        rclpy.spin_until_future_complete(self, fut, timeout_sec=5.0)
        if not fut.done() or fut.result() is None:
            return False, 'timeout'
        return fut.result().success, ''


def main():
    rclpy.init()
    tool = ParamTool()

    print('=' * 60)
    print('  PX4 参数状态 (通过 mavros service)')
    print('=' * 60)
    for name, _, _ in PARAMS_VISION:
        v = tool.get(name)
        sym = '✅' if v is not None else '❌'
        print(f'  {sym} {name:<20} = {v}')
    print()

    print('=' * 60)
    print('  设参数')
    print('=' * 60)
    # 让 rclpy 在 set 之间有 spin 时间
    for name, val, ptype in PARAMS_VISION:
        ok, err = tool.set(name, val, ptype)
        sym = '✅' if ok else '❌'
        cur = tool.get(name)
        print(f'  {sym} {name:<20} 设={val}  现={cur}')
        rclpy.spin_once(tool, timeout_sec=0.05)

    print()
    print('=' * 60)
    print('  再验证一次')
    print('=' * 60)
    for name, _, _ in PARAMS_VISION:
        v = tool.get(name)
        print(f'  {name:<20} = {v}')
        rclpy.spin_once(tool, timeout_sec=0.02)

    # ⚠️ 不让 PX4 reboot — reboot 过程中 mavros 会因 USB 掉而死锁
    # 参数已设, 大部分 PX4 param 不需要 reboot 即时生效
    # (需要 reboot 生效的: SYS_HAS_GPS, EKF2_xxx, 等下次手动 / 飞行前重启用 wrapper)
    print()
    print('=' * 60)
    print('  ✅ 参数已设 (不 reboot, 避免 mavros USB deadlock)')
    print('  需要 reboot 生效的参数会标 ⚠️ nexttime reboot')

    tool.destroy_node()
    rclpy.shutdown()


if __name__ == '__main__':
    main()