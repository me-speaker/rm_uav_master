#!/usr/bin/env python3
"""Quick test: get one PX4 param."""
import sys
import rclpy
from rclpy.node import Node
from mavros_msgs.srv import ParamGet, ParamSet, CommandLong


def main():
    rclpy.init()
    node = rclpy.create_node('param_test')

    cli = node.create_client(ParamGet, '/mavros/cmd/param/get')
    print('waiting for service...', flush=True)
    if not cli.wait_for_service(timeout_sec=10.0):
        print('TIMEOUT - service not found', flush=True)
        return
    print('service ready, calling get SYS_HAS_GPS...', flush=True)

    req = ParamGet.Request()
    req.param_id = 'SYS_HAS_GPS'
    fut = cli.call_async(req)
    rclpy.spin_until_future_complete(node, fut, timeout_sec=10.0)
    if fut.done() and fut.result():
        print(f'success={fut.result().success} value={fut.result().value.integer}', flush=True)
    else:
        print('no response', flush=True)
    node.destroy_node()
    rclpy.shutdown()


if __name__ == '__main__':
    main()