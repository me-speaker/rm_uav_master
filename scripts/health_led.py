#!/usr/bin/env python3
# =============================================================================
# health_led.py — Drone 启动信号灯 (默认 UART driver, 可扩展)
# =============================================================================
# 功能: 在 launch 3 节点 ready 后, 通过硬件信号通知 GCS 操作员/飞手
#       "drone 自启链路通, 可以起飞". 避免静默失败导致飞行事故.
#
# 默认 driver: UART /dev/ttyTHS2 (Jetson Orin Nano UART2, JST-GH 1.25 4-pin connector)
#   写 ASCII "READY\n" 给外部 UART-LED 桥接器 (ESP8266/Arduino + LED 模块).
#   外部 MCU 收到 "READY" 亮 LED, 收到 "FAIL" 闪红, 收到 "ALIVE" 心跳闪.
#
# 可扩展: 改 LED_DRIVER + 加分支 → libgpiod (GPIO LED) / WS2812B (PiPixel) /
#        USB LED (blink(1)) 都只改这一个文件
#
# 用法:
#   python3 health_led.py ready      # 3 次短闪
#   python3 health_led.py fail       # 长闪 (1.5s)
#   python3 health_led.py heartbeat   # 单次短闪
#
# Fallback: UART device not exist → log warning 不 raise (不阻塞 launch)
#
# 安装 (drone 端): sudo cp health_led.py /usr/local/bin/
# =============================================================================

import os
import sys
import time

LED_DRIVER = "uart_tths2"   # 占位 driver, 实际 driver 实现见下分支
UART_DEV = os.environ.get("HEALTH_LED_UART", "/dev/ttyTHS2")
UART_BAUD = int(os.environ.get("HEALTH_LED_BAUD", "115200"))


def _uart_write(payload: bytes):
    """写固定字节到 UART — 外部 LED 桥接器根据 payload 决策亮/灭/闪."""
    try:
        import serial  # pyserial (runtime image 已经装)
    except ImportError:
        print(f"[health_led] WARN pyserial missing, skip UART write", file=sys.stderr)
        return

    try:
        with serial.Serial(UART_DEV, UART_BAUD, timeout=0.1) as s:
            s.write(payload)
    except (FileNotFoundError, OSError) as e:
        # 设备不存在 / 无权限 — 静默失败 (e.g. dev 端无 UART, 不阻塞)
        print(f"[health_led] WARN uart unavailable {UART_DEV}: {e}", file=sys.stderr)
    except Exception as e:
        print(f"[health_led] WARN uart write fail: {e}", file=sys.stderr)


def signal_ready():
    """3 次短闪 (200ms on / 200ms off) — drone 链路 ready, 可以起飞."""
    for _ in range(3):
        _uart_write(b"READY\n")  # external LED: ON
        time.sleep(0.2)
        _uart_write(b"\n")        # external LED: OFF
        time.sleep(0.2)


def signal_fail():
    """长闪 (1.5s on) — drone 链路 fail, 不要起飞."""
    _uart_write(b"FAIL\n")
    time.sleep(1.5)
    _uart_write(b"\n")


def signal_heartbeat():
    """单次短闪 (启动中)."""
    _uart_write(b"ALIVE\n")
    time.sleep(0.1)
    _uart_write(b"\n")


def main():
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} <ready|fail|heartbeat>", file=sys.stderr)
        sys.exit(1)
    action = sys.argv[1]
    if action == "ready":
        signal_ready()
    elif action == "fail":
        signal_fail()
    elif action == "heartbeat":
        signal_heartbeat()
    else:
        print(f"unknown action: {action}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
