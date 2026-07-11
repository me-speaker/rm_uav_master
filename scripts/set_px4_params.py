#!/usr/bin/env python3
"""Set PX4 flight params via mavros service.

Runs INSIDE the container as: python3 set_px4_params.py
Doesn't suffer from the rcl 'context invalid' bug that bash+ros2 service call has.

Usage:
    python3 set_px4_params.py                    # set vision-only params
    python3 set_px4_params.py --show             # show current params
    python3 set_px4_params.py --reset            # reset to GPS mode
    python3 set_px4_params.py SYS_HAS_GPS 0 ...  # custom params
"""
import sys
import time

import rclpy
from rclpy.node import Node
from mavros_msgs.srv import ParamGet, ParamSet, CommandLong


class ParamTool(Node):
    def __init__(self):
        super().__init__('px4_param_tool')

        self.get_cli = self.create_client(ParamGet, '/mavros/cmd/param/get')
        self.set_cli = self.create_client(ParamSet, '/mavros/cmd/param/set')
        self.cmd_cli = self.create_client(CommandLong, '/mavros/cmd/command')

        for name, cli in [('param/get', self.get_cli),
                          ('param/set', self.set_cli),
                          ('cmd/command', self.cmd_cli)]:
            while not cli.wait_for_service(timeout_sec=2.0):
                self.get_logger().warn(f'waiting for {name}...')

    def get(self, name):
        req = ParamGet.Request()
        req.param_id = name
        fut = self.get_cli.call_async(req)
        rclpy.spin_until_future_complete(self, fut, timeout_sec=5.0)
        if not fut.done() or fut.result() is None:
            return None
        resp = fut.result()
        if not resp.success:
            return None
        # mavros 简化: 整数 FLOAT 全在 integer 字段
        return resp.value.integer if resp.value.integer != 0 else int(resp.value.real)

    def set(self, name, value):
        req = ParamSet.Request()
        req.param_id = name
        req.value.integer = int(value)
        req.value.real = float(value)
        req.value.type = 6  # UINT32 (mavros ignores type anyway for INT)
        fut = self.set_cli.call_async(req)
        rclpy.spin_until_future_complete(self, fut, timeout_sec=5.0)
        if not fut.done() or fut.result() is None:
            return False, 'timeout'
        return fut.result().success, ''

    def reboot_px4(self):
        req = CommandLong.Request()
        req.command = 246  # MAV_CMD_PREFLIGHT_REBOOT_SHUTDOWN
        req.param1 = 1.0   # reboot autopilot
        fut = self.cmd_cli.call_async(req)
        rclpy.spin_until_future_complete(self, fut, timeout_sec=5.0)
        return fut.result().success if fut.done() and fut.result() else False


PARAMS_VISION = [
    ('SYS_HAS_GPS', 0),
    ('EKF2_AID_MASK', 24),  # bit3 vision_pos + bit4 vision_yaw
    ('EKF2_EV_CTRL', 15),   # vision_pose + vision_yaw
    ('EKF2_HGT_REF', 3),    # Vision
    ('MAV_USEHILGPS', 0),
]
PARAMS_GPS = [
    ('SYS_HAS_GPS', 1),
    ('EKF2_AID_MASK', 1),
    ('EKF2_HGT_REF', 1),
]


def main():
    rclpy.init()
    node = ParamTool()

    args = sys.argv[1:]
    if '--show' in args or '-s' in args:
        print('=' * 60)
        print('  当前 PX4 关键参数')
        print('=' * 60)
        for n, _ in PARAMS_VISION:
            v = node.get(n)
            print(f'  {n:<20} = {v}')
        node.destroy_node()
        rclpy.shutdown()
        return

    if '--reset' in args or '-r' in args:
        params = PARAMS_GPS
        title = '还原 GPS 模式'
    elif not args:
        params = PARAMS_VISION
        title = '设 vision-only 模式'
    else:
        # custom: name1 value1 name2 value2 ...
        params = list(zip(args[::2], [int(v) for v in args[1::2]]))
        title = '自定义参数'

    print('=' * 60)
    print(f'  {title}')
    print('=' * 60)
    for name, val in params:
        ok, err = node.set(name, val)
        sym = '✅' if ok else '❌'
        print(f'  {sym} {name} = {val}' + (f'   ({err})' if not ok else ''))

    print()
    print('=' * 60)
    print('  Reboot PX4 让参数生效')
    print('=' * 60)
    if node.reboot_px4():
        print('  ✅ reboot 命令已发')
        print('  等 6s PX4 重启...')
        time.sleep(6)
    else:
        print('  ❌ reboot 失败, 手动 reboot PX4')

    print()
    print('=' * 60)
    print('  验证 (再调一次 --show)')
    print('=' * 60)
    for n, expected in params:
        v = node.get(n)
        sym = '✅' if v == expected else '⚠️ '
        print(f'  {sym} {n:<20} = {v} (期望 {expected})')

    node.destroy_node()
    rclpy.shutdown()


if __name__ == '__main__':
    main()