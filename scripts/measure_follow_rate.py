#!/usr/bin/env python3
"""measure_follow_rate.py — 对比 fake_odom 与 PX4 EKF2 的跟随率.

输入:
    /Odometry                        (fake_odom, odom frame → base_link)
    /mavros/local_position/pose      (PX4 EKF2 输出, map frame → base_link, NED)

输出:
    CSV 文件 (时间戳, fake_x, fake_y, fake_z, px4_x, px4_y, px4_z)
    终端打印: 相关系数 / 振幅比 / 相位滞后

坐标系转换:
    PX4 local_position 是 NED (x=North, y=East, z=Down).
    fake_odom 是 ENU (x=East, y=North, z=Up).
    对比时: fake_x → px4_y, fake_y → px4_x, fake_z → -px4_z
"""
from __future__ import annotations

import argparse
import math
import sys
import time
from collections import deque

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy

from nav_msgs.msg import Odometry
from geometry_msgs.msg import PoseStamped


class FollowRateMeter(Node):
    def __init__(self, duration_sec: float = 30.0, output_csv: str = ''):
        super().__init__('follow_rate_meter')
        self.duration = duration_sec
        self.output_csv = output_csv

        qos = QoSProfile(reliability=ReliabilityPolicy.BEST_EFFORT,
                         history=HistoryPolicy.KEEP_LAST, depth=10)

        self.create_subscription(Odometry, '/Odometry', self._on_odom, qos)
        self.create_subscription(PoseStamped, '/mavros/local_position/pose',
                                  self._on_px4, qos)

        # 时间对齐 buffer (0.05s 容差)
        self.fake_buf: deque = deque(maxlen=2000)
        self.px4_buf: deque = deque(maxlen=2000)
        self.start_t = None

    def _on_odom(self, msg):
        t = self._stamp(msg.header.stamp)
        if self.start_t is None:
            self.start_t = t
        self.fake_buf.append((
            t - self.start_t,
            msg.pose.pose.position.x,
            msg.pose.pose.position.y,
            msg.pose.pose.position.z,
        ))

    def _on_px4(self, msg):
        t = self._stamp(msg.header.stamp)
        if self.start_t is None:
            self.start_t = t
        # PX4 local_position 是 NED; 转 ENU 对齐 fake_odom
        # px4 pose: NED → x_px4=North, y_px4=East, z_px4=Down
        # 对应 fake (ENU): x_fake=East=px4_y, y_fake=North=px4_x, z_fake=Up=-px4_z
        self.px4_buf.append((
            t - self.start_t,
            msg.pose.position.y,   # East
            msg.pose.position.x,   # North
            -msg.pose.position.z,  # Up
        ))

    @staticmethod
    def _stamp(stamp):
        return stamp.sec + stamp.nanosec * 1e-9

    def spin_and_analyze(self):
        rate = self.create_rate(50)
        deadline = time.monotonic() + self.duration
        while time.monotonic() < deadline and rclpy.ok():
            rclpy.spin_once(self, timeout_sec=0.05)
        rclpy.shutdown()

        if not self.fake_buf or not self.px4_buf:
            print('ERROR: 没有数据', file=sys.stderr)
            return 1

        # 时间对齐: 对每个 fake timestamp 找最近的 px4 sample (max 50ms 差)
        ALIGN = 0.05
        paired = []
        px4_list = list(self.px4_buf)
        j = 0
        for t, fx, fy, fz in self.fake_buf:
            best = None
            best_dt = ALIGN + 1
            while j < len(px4_list):
                pt, px, py, pz = px4_list[j]
                dt = abs(pt - t)
                if dt < best_dt:
                    best_dt = dt
                    best = (px, py, pz)
                if pt > t + ALIGN:
                    break
                j += 1
            if best is not None and best_dt <= ALIGN:
                paired.append((t, fx, fy, fz, *best))

        n = len(paired)
        if n < 10:
            print(f'ERROR: 只对齐了 {n} 个样本,太少', file=sys.stderr)
            return 1

        # 计算统计
        # 1. 去中心化 (减均值)
        def stats(vals):
            mean = sum(vals) / len(vals)
            std = math.sqrt(sum((v - mean) ** 2 for v in vals) / len(vals))
            return mean, std

        fxs = [p[1] for p in paired]
        fys = [p[2] for p in paired]
        fzs = [p[3] for p in paired]
        pxs = [p[4] for p in paired]
        pys = [p[5] for p in paired]
        pzs = [p[6] for p in paired]

        results = {}
        for axis, (fake_v, px4_v) in [
            ('x_East', (fxs, pxs)),
            ('y_North', (fys, pys)),
            ('z_Up', (fzs, pzs)),
        ]:
            fmean, fstd = stats(fake_v)
            pmean, pstd = stats(px4_v)
            # 相关系数
            cov = sum((f - fmean) * (p - pmean)
                       for f, p in zip(fake_v, px4_v)) / n
            corr = cov / (fstd * pstd) if (fstd > 1e-9 and pstd > 1e-9) else 0.0
            # 振幅比 (PX4 / fake)
            amp_ratio = pstd / fstd if fstd > 1e-9 else 0.0
            # 相位滞后 (max cross-correlation)
            lag_samples = self._cross_corr_lag(fake_v, px4_v, max_lag=n // 4)
            lag_sec = lag_samples * 0.02  # 假设 50Hz
            results[axis] = (fmean, fstd, pmean, pstd, corr, amp_ratio, lag_sec)

        # 输出
        print()
        print('═' * 80)
        print(f'  跟随率测量结果 (样本数: {n}, 时长: {paired[-1][0] - paired[0][0]:.1f}s)')
        print('═' * 80)
        print(f'  {"轴":<8} {"fake 均值":>10} {"fake std":>9} {"PX4 均值":>10} '
              f'{"PX4 std":>9} {"相关系数":>10} {"振幅比":>9} {"滞后(s)":>10}')
        print('  ' + '─' * 78)
        for axis, (fm, fs, pm, ps, corr, amp, lag) in results.items():
            c_sym = '✓' if corr > 0.8 else ('△' if corr > 0.5 else '✗')
            a_sym = '✓' if amp > 0.7 else ('△' if amp > 0.4 else '✗')
            l_sym = '✓' if abs(lag) < 0.5 else ('△' if abs(lag) < 1.0 else '✗')
            print(f'  {axis:<8} {fm:>10.4f} {fs:>9.4f} {pm:>10.4f} {ps:>9.4f} '
                  f'{corr:>9.3f} {c_sym} {amp:>8.3f} {a_sym} {lag:>9.3f} {l_sym}')
        print()
        print('  判定: ✓ = 好 (>0.8 系数, >0.7 振幅, <0.5s 滞后)')
        print('        △ = 一般 (0.5-0.8 / 0.4-0.7 / 0.5-1.0)')
        print('        ✗ = 差 (<0.5 / <0.4 / >1.0)')
        print('═' * 80)

        # CSV 输出
        if self.output_csv:
            with open(self.output_csv, 'w') as f:
                f.write('t,fake_x,fake_y,fake_z,px4_x,px4_y,px4_z\n')
                for p in paired:
                    f.write(','.join(f'{x:.6f}' for x in p) + '\n')
            print(f'\nCSV 写入 {self.output_csv} ({n} 行)')

        return 0

    @staticmethod
    def _cross_corr_lag(a, b, max_lag):
        """求 b 相对 a 的滞后 (sample 数, 正数=b 落后 a)"""
        n = len(a)
        a_mean = sum(a) / n
        b_mean = sum(b) / n
        a0 = [x - a_mean for x in a]
        b0 = [x - b_mean for x in b]

        def corr_at(lag):
            s = 0.0
            cnt = 0
            for i in range(n):
                j = i + lag
                if 0 <= j < n:
                    s += a0[i] * b0[j]
                    cnt += 1
            return s / cnt if cnt else 0.0

        best_lag = 0
        best_val = -1e18
        for lag in range(-max_lag, max_lag + 1):
            v = corr_at(lag)
            if v > best_val:
                best_val = v
                best_lag = lag
        return best_lag


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--duration', type=float, default=30.0)
    p.add_argument('--csv', type=str, default='')
    args = p.parse_args()

    rclpy.init()
    meter = FollowRateMeter(duration_sec=args.duration, output_csv=args.csv)
    sys.exit(meter.spin_and_analyze())


if __name__ == '__main__':
    main()