  场景 1: 没接硬件，纯调试节点逻辑

  # 启容器（当前已起 rm-uavsim）
  bash scripts/start_uav_container.sh status
                                                                                                     # 进容器手动跑单个节点（不依赖硬件）                                                               bash scripts/start_uav_container.sh exec bash
  # 在容器内：
  source /opt/uav_ws/install/setup.bash
  ros2 run slam_to_mavros slam_to_mavros_node
  # Ctrl+C 退出节点; exit 退容器

  # 或一次性命令（不进交互）
  bash scripts/start_uav_container.sh exec bash -c \
      'source /opt/uav_ws/install/setup.bash && ros2 run slam_to_mavros slam_to_mavros_node'

  场景 2: 接了 Mid360 但没 PX4（测 SLAM 链路）                                                     
  bash scripts/start_uav_container.sh stop
  bash scripts/start_uav_container.sh --bringup --lidar-ip 192.168.1.150
  # 不传 --fcu-url, mavros 会起但连不上 PX4 (不影响 SLAM)                                                                                                                                               场景 3: 接了 Mid360 + PX4（全链路）                                                              
  bash scripts/start_uav_container.sh stop
  bash scripts/start_uav_container.sh --bringup \
      --lidar-ip 192.168.1.150 \
      --fcu-url /dev/ttyUSB0:921600                                                                                                                                                                     场景 4: 想用浏览器看 rviz                                                                        
  bash scripts/start_uav_container.sh --bringup-gui \
      --lidar-ip 192.168.1.150

  # 然后浏览器开: http://<host-ip>:6080/vnc.html                                                     # 想看 rviz 再开一个终端:
  bash scripts/start_uav_container.sh exec bash -c \
      'source /opt/uav_ws/install/setup.bash && DISPLAY=:99 ros2 launch
  /opt/uav_ws/uav_bringup.launch.py with_rviz:=true'                                               
  场景 5: 改代码看效果

  # 1. 主机改代码
  vim ~/rm_ws/src/slam_to_mavros/slam_to_mavros/slam_to_mavros_node.py

  # 2. .py 改动 → symlink 直接生效, 只需重启节点                                                     bash scripts/start_uav_container.sh exec bash -c \
      'pkill -f slam_to_mavros_node; sleep 1; source /opt/uav_ws/install/setup.bash && \
       nohup ros2 run slam_to_mavros slam_to_mavros_node > /tmp/stm.log 2>&1 &'                                                                                                                         # 3. .cpp 改动 → 需要 rebuild
  bash scripts/start_uav_container.sh exec bash -c \
      'cd /opt/uav_ws && colcon build --packages-select fast_lio'
                                                                                                     容器管理

  bash scripts/start_uav_container.sh status   # 状态 + topic 列表 + mount 检查
  bash scripts/start_uav_container.sh logs -f  # tail 容器日志
  bash scripts/start_uav_container.sh stop     # 停容器
  bash scripts/start_uav_container.sh exec bash # 进容器交互
