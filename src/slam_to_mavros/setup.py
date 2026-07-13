from setuptools import find_packages, setup

package_name = 'slam_to_mavros'

setup(
    name=package_name,
    version='0.1.0',
    packages=find_packages(exclude=['test']),
    data_files=[
        ('share/ament_index/resource_index/packages',
            ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
        ('share/' + package_name + '/launch',
            ['launch/slam_to_mavros.launch.py',
             'launch/odin_px4_full.launch.py']),
        ('share/' + package_name + '/config',
            ['config/slam_to_mavros.yaml']),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='speaker',
    maintainer_email='525705262@qq.com',
    description='Bridges FAST-LIO /Odometry -> MAVROS /mavros/vision_pose/* for PX4 EKF2 fusion (indoor SLAM flight).',
    license='TODO: License declaration',
    extras_require={
        'test': ['pytest'],
    },
    entry_points={
        'console_scripts': [
            'slam_to_mavros_node = slam_to_mavros.slam_to_mavros_node:main',
            'fake_odom_publisher = slam_to_mavros.fake_odom_publisher:main',
        ],
    },
)