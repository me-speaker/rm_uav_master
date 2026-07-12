#!/usr/bin/env python3
"""listen_estimator_status.py — 监听 PX4 ESTIMATOR_STATUS 验证 EKF2 融合状态.

监听 PX4 的 ESTIMATOR_STATUS 消息, 打印 flags 字段变化 (特别是 vision 融合 bit).
flags bit 定义 (PX4):
  bit 0 = attitude            (1)
  bit 1 = vel_horiz          (2)
  bit 2 = vel_vert           (4)
  bit 3 = pos_horiz_rel      (8)     <-- vision 水平位置融合
  bit 4 = pos_horiz_abs      (16)
  bit 5 = pos_vert_abs       (32)
  bit 6 = pos_vert_agl       (64)
  bit 7 = const_pos_mode     (128)   <-- PX4 没收到 vision 的 fallback

期望结果 (vision 融合成功):
  flags=0x0081 (改之前, 只有 attitude + const_pos)
  flags=0x008B (改之后, att + vel_h + pos_h_rel)  <-- pos_h_rel bit 3 被设上!

用法:
  python3 /opt/uav_ws/scripts/listen_estimator_status.py [--device /dev/ttyACM0] [--baud 921600]
"""
import argparse
import sys
import time

from pymavlink import mavutil


FLAG_NAMES = {
    1: 'attitude',
    2: 'vel_horiz',
    4: 'vel_vert',
    8: 'pos_horiz_rel',     # vision horizontal position
    16: 'pos_horiz_abs',
    32: 'pos_vert_abs',
    64: 'pos_vert_agl',
    128: 'const_pos_mode',   # PX4 fallback (no external pos)
    256: 'pred_horiz_rel',
    512: 'pred_horiz_abs',
}


def flags_to_str(flags):
    bits = []
    for bit, name in FLAG_NAMES.items():
        if flags & bit:
            bits.append(name)
    return ','.join(bits) if bits else '(none)'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--device', default='/dev/ttyACM0')
    parser.add_argument('--baud', type=int, default=921600)
    parser.add_argument('--duration', type=float, default=30.0,
                        help='监听时长 (秒), 0 = 无限')
    args = parser.parse_args()

    print(f'connecting to {args.device} @ {args.baud}...', flush=True)
    mav = mavutil.mavlink_connection(args.device, baud=args.baud, autoreconnect=True)
    hb = mav.wait_heartbeat(timeout=15)
    if not hb:
        print('NO HEARTBEAT - check PX4 USB', flush=True)
        sys.exit(1)
    print(f'PX4 connected sysid={hb.get_srcSystem()} compid={hb.get_srcComponent()}', flush=True)

    # 请求 PX4 每 50ms 发一次 ESTIMATOR_STATUS
    mav.mav.command_long_send(
        mav.target_system, mav.target_component,
        mavutil.mavlink.MAV_CMD_SET_MESSAGE_INTERVAL, 0,
        mavutil.mavlink.MAV_MSG_ESTIMATOR_STATUS, 50000,
        0, 0, 0, 0, 0,
    )

    print(f'\n=== 监听 ESTIMATOR_STATUS ({"无限" if args.duration == 0 else f"{args.duration}s"}) ===', flush=True)
    print('期望: flags 含 "pos_horiz_rel" (bit 3) 表示 EKF2 在融合 vision\n', flush=True)

    start = time.time()
    last_flags = None
    last_print = start

    try:
        while args.duration == 0 or (time.time() - start) < args.duration:
            msg = mav.recv_match(type='ESTIMATOR_STATUS', blocking=True, timeout=0.5)
            if msg is None:
                continue
            if msg.flags != last_flags:
                last_flags = msg.flags
                bits_str = flags_to_str(msg.flags)
                # 给关键 bit 加 emoji
                marker = ''
                if msg.flags & 8:
                    marker = ' ✅ VISION FUSED'
                elif msg.flags & 128:
                    marker = ' ⚠️  PX4 FALLBACK (const_pos)'
                print(f'  [{time.time()-start:6.1f}s] flags=0x{msg.flags:04X} [{bits_str}]{marker}', flush=True)

            # 同时每 1 秒看 ODOMETRY 位置
            now = time.time()
            if now - last_print > 1.0:
                last_print = now
                odo = mav.recv_match(type='ODOMETRY', blocking=False, timeout=0)
                if odo:
                    print(f'  [{time.time()-start:6.1f}s] ODOMETRY x={odo.x:+.3f} y={odo.y:+.3f} z={odo.z:+.3f}  '
                          f'(estimated from EKF2)', flush=True)
    except KeyboardInterrupt:
        pass
    finally:
        mav.close()
        print('\n[done]', flush=True)


if __name__ == '__main__':
    main()