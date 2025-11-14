#!/bin/bash
#执行脚本前将内核包和cri包放在root目录下（下载地址：http://mirrors.coreix.net/elrepo-archive-archive/kernel/el7/x86_64/RPMS/）(https://github.com/Mirantis/cri-dockerd/releases)
init1(){
# 1. 设置主机名
hostnamectl set-hostname k8s-master01

# 2. 禁用防火墙服务
systemctl disable --now firewalld 

# 3. 禁用 SELinux
sed -ri "s/^SELINUX=enforcing/SELINUX=disabled/" /etc/selinux/config
sed -i 's#SELINUX=enforcing#SELINUX=disabled#g' /etc/sysconfig/selinux
setenforce 0

# 4. 关闭交换分区并设置 vm.swappiness
swapoff -a && sysctl -w vm.swappiness=0 && sed -ri '/^[^#]*swap/s@^@#@' /etc/fstab
}

init2(){
# 5. 配置主机名解析和静态ip

# 输入静态IP（必选，验证格式）
while true; do
    read -p "1. 请输入静态IP地址（例：192.168.44.142）：" STATIC_IP
    if [[ $STATIC_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        break
    else
        echo "⚠️  格式错误！请输入类似 192.168.1.100 的合法IP"
    fi
done

# 输入子网掩码（必选，默认255.255.255.0）
while true; do
    read -p "2. 请输入子网掩码（默认255.255.255.0，直接回车用默认）：" NETMASK
    if [ -z "$NETMASK" ]; then
        NETMASK="255.255.255.0"  # 默认值
        break
    elif [[ $NETMASK =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        break
    else
        echo "⚠️  格式错误！请输入类似 255.255.255.0 的合法掩码"
    fi
done

# 输入网关（可选，验证格式）
while true; do
    read -p "3. 请输入网关地址（例：192.168.44.2，无需则直接回车）：" GATEWAY
    if [ -z "$GATEWAY" ] || [[ $GATEWAY =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        break
    else
        echo "⚠️  格式错误！请输入类似 192.168.1.1 的合法网关"
    fi
done

# 输入首选DNS（必选，验证格式）
while true; do
    read -p "4. 请输入首选DNS服务器（例：8.8.8.8 或 223.5.5.5）：" DNS1
    if [[ $DNS1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        break
    else
        echo "⚠️  格式错误！请输入类似 8.8.8.8 的合法DNS"
    fi
done

# 输入备用DNS（可选，验证格式）
while true; do
    read -p "5. 请输入备用DNS服务器（可选，无需则直接回车）：" DNS2
    if [ -z "$DNS2" ] || [[ $DNS2 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        break
    else
        echo "⚠️  格式错误！请输入类似 8.8.4.4 的合法DNS"
    fi
done
ens=`ip a | grep ens | awk -F':' '{print $2}' | awk 'NR==1{print $1}'`
cat << EOF >> /etc/sysconfig/network-scripts/ifcfg-$ens
TYPE="Ethernet"
BOOTPROTO="static"
DEFROUTE="yes"
NAME="$ens"
DEVICE="$ens"
ONBOOT="yes"
IPADDR=$STATIC_IP  # 静态IP
NETMASK=$NETMASK  # 子网掩码
GATEWAY="$GATEWAY"
DNS1="$DNS1"
DNS2="$DNS2"
EOF

#设置域名解析
cat <<-EOF >>/etc/hosts
192.168.44.139    k8s-master01 
EOF

#重启服务
systemctl restart network
}

init3(){
# 6. 配置阿里云 YUM 源

rm -rf /etc/yum.repos.d/*
curl -o /etc/yum.repos.d/CentOS-Base.repo https://mirrors.aliyun.com/repo/Centos-7.repo
curl -o /etc/yum.repos.d/epel.repo https://mirrors.aliyun.com/repo/epel-7.repo
yum install -y yum-utils
}

init4(){
# 7. 配置 Docker CE YUM 源
yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo

# 8. 配置 Kubernetes YUM 源
cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.28/rpm/
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.28/rpm/repodata/repomd.xml.key
EOF
}

init5(){
# 9. 更新系统（排除内核更新）并安装指定内核
yum -y update --exclude=kernel*
yum -y localinstall kernel-*
grub2-set-default 0 && grub2-mkconfig -o /etc/grub2.cfg

# 10. 配置内核参数以支持 user namespace
grubby --args="user_namespace.enable=1" --update-kernel="$(grubby --default-kernel)"
grubby --default-kernel 

# 11. 安装常用工具和依赖包
yum -y install wget jq psmisc vim net-tools telnet yum-utils \
               device-mapper-persistent-data lvm2 git ntpdate \
               ipvsadm ipset sysstat conntrack libseccomp    

# 12. 配置定时任务进行时间同步
echo "*/5 * * * *        ntpdate -b ntp.aliyun.com" >>/var/spool/cron/root

# 13. 设置时区
ln -sf /usr/share/zoneinfo/Asia/Shanghai  /etc/localtime
echo 'Asia/Shanghai' > /etc/timezone

# 14. 调整系统文件描述符限制
ulimit -SHn 65535
cat <<-EOF >>/etc/security/limits.conf
* soft nofile 655360
* hard nofile 131072
* soft nproc 655350
* hard nproc 655350
* soft memlock unlimited
* hard memlock unlimited
EOF

# 15. 加载 IPVS 和相关内核模块
modprobe -- ip_vs
modprobe -- ip_vs_rr
modprobe -- ip_vs_wrr
modprobe -- ip_vs_sh
modprobe -- nf_conntrack
cat <<-EOF >>/etc/modules-load.d/ipvs.conf
ip_vs
ip_vs_lc
ip_vs_wlc
ip_vs_rr
ip_vs_wrr
ip_vs_lblc
ip_vs_lblcr
ip_vs_dh
ip_vs_sh
ip_vs_fo
ip_vs_nq
ip_vs_sed
ip_vs_ftp
nf_conntrack
ip_tables
ip_set
xt_set
ipt_set
ipt_rpfilter
ipt_REJECT
ipip
EOF

# 16. 配置 Kubernetes 所需的内核参数
cat <<EOF > /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
fs.may_detach_mounts = 1
net.ipv4.conf.all.route_localnet = 1
vm.overcommit_memory=1
vm.panic_on_oom=0
fs.inotify.max_user_watches=89100
fs.file-max=52706963
fs.nr_open=52706963
net.netfilter.nf_conntrack_max=2310720
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_intvl =15
net.ipv4.tcp_max_tw_buckets = 36000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_orphans = 327680
net.ipv4.tcp_orphan_retries = 3
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.ip_conntrack_max = 65536
net.ipv4.tcp_timestamps = 0
net.core.somaxconn = 16384
EOF
sysctl --system
}

init6(){
# 17. 安装 Docker CE 并配置
yum install -y docker-ce-20.10.* docker-ce-cli-20.10.* containerd.io 
systemctl enable --now docker.service
cat <<-EOF >/etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "registry-mirrors": [ "http://hub-mirror.c.163.com", 
   "https://kr1xs9ba.mirror.aliyuncs.com",
   "https://docker.m.daocloud.io", 
   "https://dockerproxy.com", 
   "https://docker.mirrors.ustc.edu.cn", 
   "https://docker.nju.edu.cn", 
   "https://docker.registry.cyou",
   "https://docker-cf.registry.cyou",
   "https://dockercf.jsdelivr.fyi",
   "https://docker.jsdelivr.fyi",
   "https://dockertest.jsdelivr.fyi",
   "https://mirror.aliyuncs.com",
   "https://dockerproxy.com",
   "https://mirror.baidubce.com",
   "https://docker.m.daocloud.io",
   "https://docker.nju.edu.cn",
   "https://docker.mirrors.sjtug.sjtu.edu.cn",
   "https://docker.mirrors.ustc.edu.cn",
   "https://mirror.iscas.ac.cn",
   "https://docker.rainbond.cc",
   "https://noohub.run",
   "https://huecker.io",
   "https://dockerhub.timeweb.cloud", 
   "https://registry.docker-cn.com",
   "https://yfw3r2c6.mirror.aliyuncs.com", 
   "http://hub-mirror.c.163.com", 
   "https://docker.m.daocloud.io",
   "https://dockerproxy.com",
   "https://docker.mirrors.ustc.edu.cn",
   "https://docker.nju.edu.cn"] 
}
EOF
systemctl daemon-reload && systemctl restart docker

# 18. 安装和配置 cri-dockerd
tar -xvf cri-dockerd-0.3.14.amd64.tgz --strip-components=1 -C /usr/local/bin/
touch /etc/systemd/system/cri-docker.service
cat << EOF >> /etc/systemd/system/cri-docker.service
[Unit]
Description=CRI Interface for Docker Application Container Engine
Documentation=https://docs.mirantis.com
After=network-online.target firewalld.service docker.service
Wants=network-online.target
Requires=cri-docker.socket

[Service]
Type=notify
ExecStart=/usr/local/bin/cri-dockerd --pod-infra-container-image=registry.aliyuncs.com/google_containers/pause:3.9 --container-runtime-endpoint=unix:///var/run/cri-dockerd.sock --cri-dockerd-root-directory=/var/lib/dockershim --cri-dockerd-root-directory=/var/lib/docker
ExecReload=/bin/kill -s HUP $MAINPID
TimeoutSec=0
RestartSec=2
Restart=always
StartLimitBurst=3
StartLimitInterval=60s
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
touch /etc/systemd/system/cri-docker.socket
cat <<EOF>> /etc/systemd/system/cri-docker.socket
[Unit]
Description=CRI Docker Socket for the API
PartOf=cri-docker.service

[Socket]
ListenStream=/var/run/cri-dockerd.sock
SocketMode=0660
SocketUser=root
SocketGroup=docker

[Install]
WantedBy=sockets.target
EOF
systemctl daemon-reload 
systemctl enable --now cri-docker.service
  systemctl status cri-docker.service
}

# 主菜单循环
while true; do

    # 显示菜单
    echo "========================"
    echo "      功能菜单示例      "
    echo "========================"
    echo "1. 设置主机名、关闭防火墙"
    echo "2. 静态ip配置"
    echo "3. yum源配置"
    echo "4. docker和k8s源配置"
    echo "5. 内核调优"
    echo "6. 安装docker"
    echo "0. 退出程序"
    echo "========================"
    
    # 读取用户输入
    read -p "请输入选择 (0-6): " choice
    
    # 根据选择执行对应功能
    case $choice in
        1)
            init1
            ;;
        2)
            init2
            ;;
        3)
            init3
            ;;
        4)
            init4
            ;;
        5)
            init5
            ;;
        6)
            init6
            ;;
        0)
            echo "程序退出，再见！"
            exit 0
            ;;
        *)
            echo "无效选择，请输入 0-6 之间的数字"
            ;;
    esac
    
    # 暂停，等待用户按回车继续
    read -p "按回车键返回菜单..." key
done
