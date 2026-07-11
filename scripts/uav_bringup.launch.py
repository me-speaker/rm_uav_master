"""uav_bringup.launch.py — 一键拉起整套机载链路 (支持 Mid-360 / ODIN).

启动顺序 (ros2 launch 会按声明顺序拉):
    1. lidar_source == "mid360":
         livox_ros_driver2 (MID360)  -> /livox/lidar, /livox/imu
         fast_lio mapping           -> /Odometry
       lidar_source == "odin":
         odin_ros_driver host_sdk_sample  -> /odin1/cloud_raw, /odin1/imu,
                                              /odin1/odometry  (ODIN 自带 SLAM)
    2. slam_to_mavros bridge  (订阅 /Odometry 或 /odin1/odometry -> /mavros/vision_pose/pose)
    3. mavros px4.launch       (MAVLink <-> FCU)
    4. (可选) rviz2

使用:
    # Mid-360 全链路 (默认)
    ros2 launch /opt/uav_ws/scripts/uav_bringup.launch.py \\
        lidar:=mid360 lidar_ip:=192.168.1.150 fcu_url:=/dev/ttyUSB0:921600

    # ODIN1 全链路 (用 ODIN 自带 SLAM)
    ros2 launch /opt/uav_ws/scripts/uav_bringup.launch.py \\
        lidar:=odin fcu_url:=/dev/ttyUSB0:921600

    # 带 rviz (需 WITH_GUI=yes 镜像)
    ros2 launch /opt/uav_ws/scripts/uav_bringup.launch.py lidar:=odin with_rviz:=true
"""
import os
from launch import LaunchDescription
from launch.actions import (
    DeclareLaunchArgument,
    GroupAction,
    IncludeLaunchDescription,
    OpaqueFunction,
    TimerAction,
)
from launch.conditions import IfCondition
from launch.substitutions import (
    LaunchConfiguration,
    EnvironmentVariable,
    PythonExpression,
)
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch_ros.actions import Node
from ament_index_python.packages import get_package_share_directory


def _launch_livox(context, *args, **kwargs):
    """Launch livox_ros_driver2 + fast_lio for Mid-360."""
    livox_launch_file = os.path.join(
        get_package_share_directory('livox_ros_driver2'),
        'launch_ROS2', 'msg_MID360_launch.py')
    livox = IncludeLaunchDescription(
        PythonLaunchDescriptionSource(livox_launch_file),
        launch_arguments={
            'xfer_format': '0',
            'multi_topic': '0',
            'data_src': '0',
            'publish_freq': '10.0',
            'output_data_type': '0',
            'frame_id': 'livox_frame',
        }.items(),
    )
    fast_lio_launch_file = os.path.join(
        get_package_share_directory('fast_lio'),
        'launch', 'mapping.launch.py')
    fast_lio = IncludeLaunchDescription(
        PythonLaunchDescriptionSource(fast_lio_launch_file),
        launch_arguments={
            'config_file': 'mid360.yaml',
            'rviz': 'false',
            'use_sim_time': 'false',
        }.items(),
    )
    return [livox, fast_lio]


def _launch_odin(context, *args, **kwargs):
    """Launch only host_sdk_sample (the main ODIN driver).

    The full odin1_ros2.launch.py also pulls pcd2depth / reprojection / overlay
    nodes that need extra config + high CPU. For SLAM-only use we just want
    the main driver (produces /odin1/cloud_raw /imu/odometry/cloud_slam).

    ⚠️ 不传 `config_file` ROS2 param: host_sdk_sample.cpp 不用它 (从 COLCON_PREFIX_PATH
    环境变量找路径), 而且如果传了, launch 会用 --params-file 把同一个 yaml 再
    load 一次, 文件句柄冲突 → "读取YAML文件失败: bad conversion" → SIGSEGV (实测).
    """
    host_sdk = Node(
        package='odin_ros_driver',
        executable='host_sdk_sample',
        # 不设 name=, 否则 launch 加 -r __node:=host_sdk_sample 触发 SIGSEGV
        output='screen',
    )
    return [host_sdk]


def _launch_fake_odom(context, *args, **kwargs):
    """Launch fake_odom_publisher — for PX4-only test without real LiDAR.

    Generates synthetic /Odometry so slam_to_mavros + mavros + PX4 chain
    can be verified end-to-end without a real SLAM source. Motion mode
    is configured via the motion_mode launch arg.
    """
    fake = Node(
        package='slam_to_mavros',
        executable='fake_odom_publisher',
        name='fake_odom_publisher',
        output='screen',
        parameters=[{
            'publish_rate_hz': LaunchConfiguration('fake_rate_hz'),
            'motion_mode': LaunchConfiguration('fake_motion_mode'),
            'noise_pos_std_m': LaunchConfiguration('fake_noise_pos_m'),
        }],
    )
    return [fake]


def generate_launch_description():
    # ---- launch args -------------------------------------------------------
    lidar_arg = DeclareLaunchArgument(
        'lidar', default_value='mid360',
        description='LiDAR source: "mid360" | "odin" | "fake" (PX4-only test, no hardware)')
    fcu_url_arg = DeclareLaunchArgument(
        'fcu_url',
        default_value=EnvironmentVariable('FCU_URL', default_value='/dev/ttyUSB0:921600'),
        description='PX4 FCU MAVLink URL')
    tgt_system_arg = DeclareLaunchArgument('tgt_system', default_value='1')
    tgt_component_arg = DeclareLaunchArgument('tgt_component', default_value='1')
    with_rviz_arg = DeclareLaunchArgument(
        'with_rviz', default_value='false',
        description='Launch rviz2 (requires WITH_GUI=yes image)')
    fake_rate_arg = DeclareLaunchArgument(
        'fake_rate_hz', default_value='50.0',
        description='(lidar:=fake) fake /Odometry publish rate')
    fake_motion_arg = DeclareLaunchArgument(
        'fake_motion_mode', default_value='hover',
        description='(lidar:=fake) motion: hover | circle | linear | random')
    fake_noise_arg = DeclareLaunchArgument(
        'fake_noise_pos_m', default_value='0.005',
        description='(lidar:=fake) position noise std (m)')

    slam_to_mavros_launch = os.path.join(
        get_package_share_directory('slam_to_mavros'),
        'launch', 'slam_to_mavros.launch.py')

    # ---- mavros (px4.launch) — always, 3s delay ---------------------------
    # apt 的 ros-humble-mavros 只给了 ROS1 的 px4.launch (XML), ROS2 加载会
    # "invalid syntax". 用我们自己的 px4.launch.py (在 scripts/ 目录).
    mavros_launch_file = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        'px4.launch.py')
    mavros = TimerAction(
        period=3.0,
        actions=[IncludeLaunchDescription(
            PythonLaunchDescriptionSource(mavros_launch_file),
            launch_arguments={
                'fcu_url': LaunchConfiguration('fcu_url'),
                'gcs_url': '',
                'tgt_system': LaunchConfiguration('tgt_system'),
                'tgt_component': LaunchConfiguration('tgt_component'),
                'fcu_protocol': 'v2.0',
                'respawn_mavros': 'false',
            }.items(),
        )],
    )

    # ---- (optional) rviz2 -------------------------------------------------
    rviz = Node(
        package='rviz2',
        executable='rviz2',
        name='rviz2',
        arguments=['-d', os.path.join(
            get_package_share_directory('fast_lio'), 'rviz', 'fastlio.rviz')],
        condition=IfCondition(LaunchConfiguration('with_rviz')),
    )

    return LaunchDescription([
        lidar_arg,
        fcu_url_arg,
        tgt_system_arg,
        tgt_component_arg,
        with_rviz_arg,
        fake_rate_arg,
        fake_motion_arg,
        fake_noise_arg,
        # ---- Mid-360 group ----
        GroupAction(
            condition=IfCondition(
                PythonExpression(["'", LaunchConfiguration('lidar'), "' == 'mid360'"])),
            actions=[
                OpaqueFunction(function=_launch_livox),
                IncludeLaunchDescription(
                    PythonLaunchDescriptionSource(slam_to_mavros_launch),
                    launch_arguments={'odom_topic': '/Odometry'}.items(),
                ),
            ],
        ),
        # ---- ODIN group ----
        GroupAction(
            condition=IfCondition(
                PythonExpression(["'", LaunchConfiguration('lidar'), "' == 'odin'"])),
            actions=[
                OpaqueFunction(function=_launch_odin),
                IncludeLaunchDescription(
                    PythonLaunchDescriptionSource(slam_to_mavros_launch),
                    launch_arguments={'odom_topic': '/odin1/odometry'}.items(),
                ),
            ],
        ),
        # ---- Fake odom group (PX4-only test) ----
        GroupAction(
            condition=IfCondition(
                PythonExpression(["'", LaunchConfiguration('lidar'), "' == 'fake'"])),
            actions=[
                OpaqueFunction(function=_launch_fake_odom),
                IncludeLaunchDescription(
                    PythonLaunchDescriptionSource(slam_to_mavros_launch),
                    launch_arguments={'odom_topic': '/Odometry'}.items(),
                ),
            ],
        ),
        # ---- MAVROS always (3s delay) ----
        mavros,
        # ---- Optional rviz ----
        rviz,
    ])