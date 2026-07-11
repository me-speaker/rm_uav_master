#!/usr/bin/env bash
# =============================================================================
# set_px4_mavlink.sh — 不用 QGC 不用 mavros service, 直接走 MAVLink 设 PX4 参数
# =============================================================================
# 用途:
#   mavros 的 PX4 param service 在 humble 版本 broken, 我们直接走原始 MAVLink
#   串口设参, 绕过 mavros.
#
# 用法:
#   bash scripts/set_px4_mavlink.sh                  # 设 vision-only 参数 + reboot
#   bash scripts/set_px4_mavlink.sh --show           # 只看当前参数
#   bash scripts/set_px4_mavlink.sh --verify         # 验证 PX4 是否在融合 vision
#   bash scripts/set_px4_mavlink.sh --reset          # 还原成 GPS 模式
#   bash scripts/set_px4_mavlink.sh --device /dev/ttyUSB0   # 用别的串口
#
# 首次使用:
#   bash scripts/ensure_pymavlink.sh   # 装 pymavlink (一次性)
# =============================================================================
set -e

# 把参数透传给 python script (--show / --reset / --device / ...)
exec docker exec rm-uavsim python3 /opt/uav_ws/scripts/set_px4_mavlink.py "$@"