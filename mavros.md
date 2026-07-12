六、安装 MAVROS2
# 创建工作空间
mkdir -p ~/mavros2_ws/src
cd ~/mavros2_ws

# 下载 mavlink 和 mavros 源码
rosinstall_generator --format repos mavlink | tee /tmp/mavlink.repos
rosinstall_generator --format repos --upstream mavros | tee -a /tmp/mavros.repos
vcs import src < /tmp/mavlink.repos
vcs import src < /tmp/mavros.repos

# 安装依赖
sudo rosdep init 2>/dev/null || true
rosdep update
rosdep install --from-paths src --ignore-src -y

# 编译工作空间
colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release

# 安装 GeographicLib 数据
sudo ./src/mavros/mavros/scripts/install_geographiclib_datasets.sh

# 添加环境变量
echo "source ~/mavros2_ws/install/setup.bash" >> ~/.bashrc
source ~/.bashrc
七、测试 MAVROS2 + PX4
ros2 launch mavros px4.launch gcs_url:="udp://:14540@127.0.0.1:14557"
如果终端输出正常，则说明 MAVROS2 与 PX4 配置完成，可以开始无人机仿真和开发，输出结果示意如下图。
