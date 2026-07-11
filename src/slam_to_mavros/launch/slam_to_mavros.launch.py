"""slam_to_mavros launch — start the FAST-LIO -> MAVROS vision-pose bridge.

Usage:
    ros2 launch slam_to_mavros slam_to_mavros.launch.py
    ros2 launch slam_to_mavros slam_to_mavros.launch.py \
        lidar_to_base_xyz:='[0.0, 0.0, -0.05]' \
        lidar_to_base_rpy:='[0.0, 0.0, 0.0]'
"""
import os

from ament_index_python.packages import get_package_share_directory

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def generate_launch_description():
    pkg_share = get_package_share_directory('slam_to_mavros')
    default_params = os.path.join(pkg_share, 'config', 'slam_to_mavros.yaml')

    # CLI args (override yaml)
    odom_topic_arg = DeclareLaunchArgument(
        'odom_topic', default_value='/Odometry',
        description='FAST-LIO odometry topic (nav_msgs/Odometry)')
    world_frame_arg = DeclareLaunchArgument(
        'world_frame_id', default_value='map',
        description='frame_id for published vision pose (PX4 expects "map")')
    base_frame_arg = DeclareLaunchArgument(
        'base_frame_id', default_value='base_link',
        description='child frame_id in TF')
    lidar_frame_arg = DeclareLaunchArgument(
        'lidar_frame_id', default_value='livox_frame',
        description='frame_id of the LiDAR mount as known by FAST-LIO')

    node = Node(
        package='slam_to_mavros',
        executable='slam_to_mavros_node',
        name='slam_to_mavros',
        output='screen',
        parameters=[
            default_params,
            {
                'odom_topic': LaunchConfiguration('odom_topic'),
                'world_frame_id': LaunchConfiguration('world_frame_id'),
                'base_frame_id': LaunchConfiguration('base_frame_id'),
                'lidar_frame_id': LaunchConfiguration('lidar_frame_id'),
            },
        ],
    )

    return LaunchDescription([
        odom_topic_arg,
        world_frame_arg,
        base_frame_arg,
        lidar_frame_arg,
        node,
    ])