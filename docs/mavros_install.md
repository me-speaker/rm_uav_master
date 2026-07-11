 # 如需：安装mavros
  apt-get update && apt-get install -y ros-humble-mavros ros-humble-mavros-extras
  . install_geographiclib_dataset.sh #这个文件说是在mavros安装目录下，但有时并不存在，需要去mavros源码里复制
  cd  /usr/share/GeographicLib
  geographiclib-get-gravity egm96
  geographiclib-get-geoids egm96-5
  geographiclib-get-magnetic emm2015
