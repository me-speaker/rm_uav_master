"""全链路 launch file: ODIN + PX4 mavros + slam_to_mavros.

一句话启完整个外部定位链路 (替代 launch_odin_px4.sh 的 shell 拼接).

用法 (容器内):
    source /opt/uav_ws/install/setup.bash
    ros2 launch slam_to_mavros odin_px4_full.launch.py

参数:
    odom_topic          (str)  default /odin1/odometry
    force_ros_stamp     (bool) default True  (ODIN 时间戳修复)
    fcu_url             (str)  default /dev/ttyACM0:921600
    gcs_url             (str)  default ''     (不监听 GCS)
"""
import os

from ament_index_python.packages import get_package_share_directory

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, TimerAction
from launch.substitutions import LaunchConfiguration, Command
from launch_ros.actions import Node


def generate_launch_description():
    pkg_share = get_package_share_directory('slam_to_mavros')
    default_params = os.path.join(pkg_share, 'config', 'slam_to_mavros.yaml')

    # ---- args ---------------------------------------------------------
    odom_topic_arg = DeclareLaunchArgument(
        'odom_topic', default_value='/odin1/odometry',
        description='SLAM odometry input topic')
    force_stamp_arg = DeclareLaunchArgument(
        'force_ros_stamp', default_value='True',
        description='Force ROS now() stamp (ODIN time bug workaround)')
    fcu_url_arg = DeclareLaunchArgument(
        'fcu_url', default_value='/dev/ttyACM0:921600',
        description='PX4 MAVLink URL')
    gcs_url_arg = DeclareLaunchArgument(
        'gcs_url', default_value='',
        description='MAVLink GCS URL (empty = no listener)')
    tgt_system_arg = DeclareLaunchArgument(
        'tgt_system', default_value='1')
    tgt_component_arg = DeclareLaunchArgument(
        'tgt_component', default_value='1')
    fcu_protocol_arg = DeclareLaunchArgument(
        'fcu_protocol', default_value='v2.0')

    # ---- 1. ODIN driver (host_sdk_sample) ---------------------------------
    # 让 mavros 和 slam_to_mavros 延迟启动, 给 ODIN SDK init 时间
    # ODIN 正常运行不会自己 fail, respawn=True 处理 PX4 reboot / USB reconnect 等场景
    odin_node = Node(
        package='odin_ros_driver',
        executable='host_sdk_sample',
        # 不设 name=, launch 会自动 -r __node:=host_sdk_sample, 否则 SIGSEGV (已知 bug)
        output='screen',
        respawn=True,                    # PX4 reboot / USB 重连时自动拉起
        respawn_delay=5.0,
    )

    # ---- 2. mavros (15s 后启, 等 ODIN SDK init 完) -----------------------
    mavros_node = Node(
        package='mavros',
        executable='mavros_node',
        namespace='/mavros',
        output='screen',
        respawn=True,                    # PX4 reboot → mavros 自动拉起
        respawn_delay=5.0,
        parameters=[{
            'fcu_url': LaunchConfiguration('fcu_url'),
            'gcs_url': LaunchConfiguration('gcs_url'),
            'tgt_system': LaunchConfiguration('tgt_system'),
            'tgt_component': LaunchConfiguration('tgt_component'),
            'pluginlists_yaml': '/opt/ros/humble/share/mavros/launch/px4_pluginlists.yaml',
            'config_yaml':      '/opt/ros/humble/share/mavros/launch/px4_config.yaml',
            'plugin_denylist': [
                'image_pub', 'vibration', 'distance_sensor',
                'rangefinder', 'wheel_odometry',
                'companion_process_status',  # mavros humble type conflict
                'adsb', 'cellular_status', 'trajectory',
            ],
        }],
    )

    # ---- 3. slam_to_mavros (15s 后启, 等 ODIN 有数据) --------------------
    slam_node = Node(
        package='slam_to_mavros',
        executable='slam_to_mavros_node',
        name='slam_to_mavros',
        output='screen',
        respawn=True,                    # PX4 fusion 链路关键, 必须一直活着
        respawn_delay=2.0,
        parameters=[default_params, {
            'odom_topic': LaunchConfiguration('odom_topic'),
            'force_ros_stamp': LaunchConfiguration('force_ros_stamp'),
        }],
    )

    return LaunchDescription([
        # args
        odom_topic_arg, force_stamp_arg, fcu_url_arg, gcs_url_arg,
        tgt_system_arg, tgt_component_arg, fcu_protocol_arg,

        # ODIN 先起 (不 respawn, SDK bug 留 watchdog)
        odin_node,

        # 15s 后启 mavros 和 slam (等 ODIN SDK init + USB settle)
        TimerAction(period=2.0, actions=[mavros_node, slam_node]),
    ])