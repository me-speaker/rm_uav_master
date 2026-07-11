#!/usr/bin/env python3
"""简化的 PX4 MAVLink 监控: 打印所有收到的 MAVLink 消息."""
import time
from pymavlink import mavutil


def main():
    print('connecting to /dev/ttyACM0 @ 921600...')
    mav = mavutil.mavlink_connection('/dev/ttyACM0', baud=921600)
    print('waiting heartbeat...')
    hb = mav.wait_heartbeat(timeout=10)
    if not hb:
        print('NO HEARTBEAT')
        return
    print(f'PX4 OK sysid={hb.get_srcSystem()}, compid={hb.get_srcComponent()}')
    print()

    # 不订阅任何东西, 看 PX4 默认发什么
    print('不订阅任何东西, 看 PX4 默认 5s 内发啥:')
    start = time.time()
    msg_counts = {}
    while time.time() - start < 5:
        msg = mav.recv_match(blocking=True, timeout=1)
        if msg:
            t = msg.get_type()
            msg_counts[t] = msg_counts.get(t, 0) + 1
            print(f'  [{t}] {msg}')

    print()
    print('=== 收到的消息统计 (5s) ===')
    for t, c in sorted(msg_counts.items(), key=lambda x: -x[1]):
        print(f'  {t}: {c}')

    print()
    print('现在用 SET_MESSAGE_INTERVAL 订阅 LOCAL_POSITION_NED (50ms = 20Hz):')
    mav.mav.command_long_send(
        mav.target_system, mav.target_component,
        511,  # MAV_CMD_SET_MESSAGE_INTERVAL
        0,    # confirmation
        33,   # LOCAL_POSITION_NED
        50000,  # 50ms in μs
        0, 0, 0, 0, 0
    )

    print('等 5s 看 LOCAL_POSITION_NED:')
    start = time.time()
    count = 0
    while time.time() - start < 5:
        msg = mav.recv_match(type='LOCAL_POSITION_NED', blocking=True, timeout=1)
        if msg:
            count += 1
            print(f'  [{count}] x={msg.x:.3f} y={msg.y:.3f} z={msg.z:.3f}')

    print(f'\n收到 {count} 条 LOCAL_POSITION_NED')


if __name__ == '__main__':
    main()