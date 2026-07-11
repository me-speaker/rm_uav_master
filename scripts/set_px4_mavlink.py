#!/usr/bin/env python3
"""Set PX4 params via raw MAVLink over serial (bypasses broken mavros param service).

Usage:
    python3 set_px4_mavlink.py                    # set vision-only params + reboot
    python3 set_px4_mavlink.py --show             # show current key params
    python3 set_px4_mavlink.py --verify           # verify PX4 is fusing vision
    python3 set_px4_mavlink.py --reset            # revert to GPS mode
"""
import sys
import time
import argparse

from pymavlink import mavutil


def connect(device='/dev/ttyACM0', baud=921600):
    print(f'connecting to {device} @ {baud}...')
    mav = mavutil.mavlink_connection(device, baud=baud, autoreconnect=False)
    print('waiting for heartbeat...')
    hb = mav.wait_heartbeat(timeout=10)
    if not hb:
        print('NO HEARTBEAT — PX4 not responding')
        sys.exit(1)
    print(f'PX4 sysid={hb.get_srcSystem()}, compid={hb.get_srcComponent()}')
    return mav


def param_get(mav, name, retries=3):
    for _ in range(retries):
        mav.mav.param_request_read_send(
            mav.target_system, mav.target_component, name.encode(), -1)
        msg = mav.recv_match(type='PARAM_VALUE', blocking=True, timeout=2)
        if msg and msg.param_id == name:
            return msg.param_value, msg.param_type
    return None, None


def param_set(mav, name, value, ptype=6):
    """ptype: 1=INT8, 2=UINT8, 3=INT16, 4=UINT16, 5=INT32, 6=UINT32, 9=FLOAT32"""
    mav.mav.param_set_send(
        mav.target_system, mav.target_component,
        name.encode(), float(value), ptype)
    msg = mav.recv_match(type='PARAM_VALUE', blocking=True, timeout=2)
    if msg and msg.param_id == name:
        return msg.param_value
    return None


def reboot(mav):
    """MAV_CMD_PREFLIGHT_REBOOT_SHUTDOWN = 246, param1=1 reboot autopilot."""
    mav.mav.command_long_send(
        mav.target_system, mav.target_component,
        246, 0,  # command, confirmation
        1, 0, 0, 0, 0, 0, 0)  # param1=1 (reboot autopilot)
    print('reboot command sent, waiting 5s for PX4 to come back...')
    time.sleep(5)


PARAMS_VISION = [
    # (name, value, ptype, description)
    # ----- sensor enable / disable -----
    ('SYS_HAS_GPS',   0, 6, 'disable GPS fusion (室内)'),
    ('SYS_HAS_MAG',   0, 6, 'disable magnetometer (室内, 避免金属/电机磁干扰)'),
    ('MAV_USEHILGPS', 0, 2, 'no HIL GPS'),

    # ----- EKF2 vision fusion control -----
    # EKF2_EV_CTRL bit 定义:
    #   bit0 (1) = horizontal position fusion
    #   bit1 (2) = vertical (height) fusion
    #   bit2 (4) = velocity fusion   ← 9 关掉这个, vision 速度噪声大, 让 IMU 算
    #   bit3 (8) = yaw fusion
    # 9 = horiz pos + yaw (推荐: 不太激进, 室内稳)
    ('EKF2_EV_CTRL',  9, 6, 'vision: horiz pos + yaw (NO velocity, NO vert)'),
    ('EKF2_AID_MASK', 9, 6, 'backup: bit0 vision_pos + bit3 vision_yaw'),
    ('EKF2_HGT_REF',  1, 6, 'Barometer (默认 1; vision 高位噪声大, 用 baro 更稳)'),

    # ----- EKF2 vision noise / delay -----
    # EV_DELAY 单位秒, 10ms ≈ 0.01s (docker 容器内多几 ms 延迟, 给点余量)
    ('EKF2_EV_DELAY',  0.01, 9, 'vision 数据相对 IMU 的延迟 (10ms, 含 docker 链路)'),
    # EVP_NOISE 单位米, vision 位置噪声标准差 (ODIN 自带 SLAM ~3cm 量级)
    ('EKF2_EVP_NOISE', 0.03, 9, 'vision position 噪声 std (3cm)'),

    # ----- 验证用 -----
    ('MAV_ODOM_LP',    1, 2, 'PX4 回传 ODOMETRY, --verify 用来验证 fusion 在跑'),
]
PARAMS_GPS = [
    ('SYS_HAS_GPS',   1, 6, 'enable GPS fusion'),
    ('SYS_HAS_MAG',   1, 6, 're-enable magnetometer'),
    ('EKF2_AID_MASK', 1, 6, 'bit0 GPS only'),
    ('EKF2_EV_CTRL',  0, 6, 'disable all vision fusion'),
    ('EKF2_HGT_REF',  1, 6, 'GPS/baro height'),
    ('EKF2_EV_DELAY', 0.0, 9, 'reset'),
    ('EKF2_EVP_NOISE',0.1, 9, 'reset to default-ish'),
    ('MAV_ODOM_LP',   0, 2, 'stop ODOMETRY echo'),
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--show', action='store_true', help='show current params')
    parser.add_argument('--verify', action='store_true', help='verify vision fusion running')
    parser.add_argument('--reset', action='store_true', help='revert to GPS mode')
    parser.add_argument('--device', default='/dev/ttyACM0')
    parser.add_argument('--baud', type=int, default=921600)
    parser.add_argument('--no-reboot', action='store_true', help='set params without reboot')
    args = parser.parse_args()

    mav = connect(args.device, args.baud)

    if args.show:
        print('=' * 60)
        print('  PX4 当前关键参数')
        print('=' * 60)
        for name, _, _, _ in PARAMS_VISION:
            v, t = param_get(mav, name)
            if v is not None:
                print(f'  {name:<20} = {v:>10.4f}')
            else:
                print(f'  {name:<20} = ???')
        return

    if args.verify:
        # check estimator_status flags via mavros / PX4 sys_status
        # easiest: see if MAV_ODOM_LP=1 we get ODOMETRY msg back
        print('=' * 60)
        print('  验证 vision fusion (MAV_ODOM_LP 回传检查)')
        print('=' * 60)
        v, _ = param_get(mav, 'MAV_ODOM_LP')
        print(f'  MAV_ODOM_LP = {v}')
        if v != 1:
            print('  先设 MAV_ODOM_LP=1 重启后再 verify')
            return
        print('  waiting for ODOMETRY echo from PX4 (8s)...')
        # mavproxy style: msg = mav.recv_match(type='ODOMETRY', blocking=True, timeout=8)
        start = time.time()
        odom_msgs = []
        while time.time() - start < 8:
            msg = mav.recv_match(type='ODOMETRY', blocking=False, timeout=0.1)
            if msg:
                odom_msgs.append(msg)
        if odom_msgs:
            print(f'  ✅ 收到 {len(odom_msgs)} 条 ODOMETRY 回传, PX4 EKF2 在跑')
            last = odom_msgs[-1]
            print(f'  最后一条: x={last.x:.3f} y={last.y:.3f} z={last.z:.3f}')
        else:
            print(f'  ❌ 8s 内没收到 ODOMETRY 回传')
            print(f'     可能: EKF2_EV_CTRL=15 没设 / PX4 EKF2 没在融合 vision')
        return

    if args.reset:
        params = PARAMS_GPS
        title = '还原 GPS 模式'
    else:
        params = PARAMS_VISION
        title = '设 vision-only 模式'

    print('=' * 60)
    print(f'  {title}')
    print('=' * 60)
    for name, val, ptype, desc in params:
        # 先读当前值
        cur, _ = param_get(mav, name)
        # 设新值
        new = param_set(mav, name, val, ptype)
        sym = '✅' if new == val else '⚠️ '
        cur_s = f'{cur:.4f}' if cur is not None else '?'
        new_s = f'{new:.4f}' if new is not None else '?'
        print(f'  {sym} {name:<20} {cur_s} → {new_s}  ({desc})')

    if not args.no_reboot:
        print()
        print('=' * 60)
        print('  Reboot PX4')
        print('=' * 60)
        reboot(mav)
        # 重连
        mav.close()
        time.sleep(1)
        mav = connect(args.device, args.baud)
        print()
        print('=' * 60)
        print('  验证生效')
        print('=' * 60)
        for name, val, _, _ in params:
            cur, _ = param_get(mav, name)
            sym = '✅' if cur == val else '⚠️ '
            print(f'  {sym} {name:<20} = {cur}  (期望 {val})')


if __name__ == '__main__':
    main()