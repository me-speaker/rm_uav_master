# =============================================================================
# px4.launch.py — ROS2 wrapper for mavros (apt 包只给了 ROS1 的 px4.launch)
# =============================================================================
# 替代 /opt/ros/humble/share/mavros/launch/px4.launch (那个是 ROS1 XML 格式,
# 在 ROS2 里加载就 "invalid syntax (px4.launch, line 1)")
#
# 用法 (跟 ROS1 px4.launch 一模一样):
#   ros2 launch px4.launch.py fcu_url:=/dev/ttyACM0:921600
#
# 等价于 ROS1 的:
#   roslaunch mavros px4.launch fcu_url:=...
# =============================================================================

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def generate_launch_description():
    return LaunchDescription([
        DeclareLaunchArgument(
            'fcu_url', default_value='/dev/ttyACM0:57600',
            description='MAVLink FCU URL (e.g. /dev/ttyACM0:921600, udpin://...)'),
        DeclareLaunchArgument('gcs_url', default_value='',
            description='MAVLink GCS URL (空 = 不监听)'),
        DeclareLaunchArgument('tgt_system', default_value='1',
            description='Target system ID'),
        DeclareLaunchArgument('tgt_component', default_value='1',
            description='Target component ID'),
        DeclareLaunchArgument('fcu_protocol', default_value='v2.0',
            description='MAVLink protocol version'),
        DeclareLaunchArgument('respawn_mavros', default_value='false',
            description='Auto-respawn mavros on crash'),

        Node(
            package='mavros',
            executable='mavros_node',
            # 用 namespace='/mavros' 让 topic 是 /mavros/*, 但**不**设 name=
            # 否则 ROS2 自动加 -r __node:=<name>, mavros_node 内部又把 'mavros'
            # 当默认 namespace → 'mavros/mavros/*' 双前缀, 触发 service/publisher
            # type conflict 崩溃. mavros humble 已知 bug, workaround 就是裸起.
            namespace='/mavros',
            output='screen',
            respawn=True,                    # PX4 reboot → mavros crash → 自动拉起
            respawn_delay=5.0,                # 给 PX4 5 秒重启时间再连
            parameters=[{
                'fcu_url': LaunchConfiguration('fcu_url'),
                'gcs_url': LaunchConfiguration('gcs_url'),
                'tgt_system': LaunchConfiguration('tgt_system'),
                'tgt_component': LaunchConfiguration('tgt_component'),
                # 用 apt 装的 PX4 配置 + 插件列表 (ROS1 px4.launch 就是这么搞)
                'pluginlists_yaml': '/opt/ros/humble/share/mavros/launch/px4_pluginlists.yaml',
                'config_yaml':      '/opt/ros/humble/share/mavros/launch/px4_config.yaml',
                # CompanionProcessStatus 跟 mavros 自带 status pub 有 type 冲突
                # (known mavros humble bug), 加黑名单. 其他用不到的也禁.
                'plugin_denylist': [
                    'image_pub', 'vibration', 'distance_sensor',
                    'rangefinder', 'wheel_odometry',
                    'companion_process_status',
                    'adsb', 'cellular_status', 'trajectory',
                ],
            }],
        ),
    ])