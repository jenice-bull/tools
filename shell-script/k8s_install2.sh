#!/bin/bash
#安装k8s
yum install kubeadm-1.28* kubelet-1.28* kubectl-1.28* -y

#统一kubelet与容器运行时的cgroup 驱动为systemd，确保Kubernetes组件之间的资源管理机制兼容
cat <<EOF>>/etc/sysconfig/kubelet
KUBELET_EXTRA_ARGS="--cgroup-driver=systemd"
EOF

#从新加载，设置开机自启
systemctl daemon-reload && systemctl enable --now kubelet
#创建yaml文件
touch /root/kubeadm-config.yaml
cat <<EOF>> /root/kubeadm-config.yaml
---
apiVersion: kubeadm.k8s.io/v1beta3
bootstrapTokens:
- groups:
  - system:bootstrappers:kubeadm:default-node-token
  token: 7t2weq.bjbawausm0jaxury
  ttl: 24h0m0s
  usages:
  - signing
  - authentication
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 192.168.44.140
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/cri-dockerd.sock
  name: k8s-master01
  #taints:
  #- effect: NoSchedule
  #  key: node-role.kubernetes.io/control-plane
---
apiServer:
  certSANs:
  - 192.168.44.140
  timeoutForControlPlane: 4m0s
apiVersion: kubeadm.k8s.io/v1beta3
certificatesDir: /etc/kubernetes/pki
clusterName: kubernetes
controlPlaneEndpoint: 192.168.44.140:6443
controllerManager: {}
etcd:
  local:
    dataDir: /var/lib/etcd
imageRepository: registry.cn-hangzhou.aliyuncs.com/google_containers
kind: ClusterConfiguration
kubernetesVersion: v1.28.15 # 更改此处的版本号和kubeadm version一致
networking:
  dnsDomain: cluster.local
  podSubnet: 172.16.0.0/16
  serviceSubnet: 10.96.0.0/16
scheduler: {}
EOF

#配置文件迁移
kubeadm config migrate --old-config kubeadm-config.yaml --new-config new.yaml
kubeadm config images pull --config new.yaml
kubeadm init --config new.yaml --upload-certs
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
kubectl get nodes
cd /root/ && git clone  https://gitee.com/BRWYZ/kubernetes_install.git
cd /root/kubernetes_install && git checkout v1.28+  && cd calico/

#>>> 修改calico配置文件中Pod的网段
POD_SUBNET=`cat /etc/kubernetes/manifests/kube-controller-manager.yaml | grep cluster-cidr= | awk -F= '{print $NF}'`
sed -i "s#POD_CIDR#${POD_SUBNET}#g" calico.yaml

#>>> 创建calico容器
kubectl apply -f calico.yaml

#>>> 查看Pod的信息
kubectl get po -n kube-system
kubectl taint node k8s-master01 node-role.kubernetes.io/control-plane-


#>>> 安装Metrics server（master01）
cd ~/kubernetes_install/kubeadm-metrics-server/  && kubectl  create -f comp.yaml

#>>> 查看Metrics server状态（master01）
kubectl get po -n kube-system -l k8s-app=metrics-server

#>>> 查看节点状态（master01）
kubectl top node  

#>>> 查看pod的状态（master01）
kubectl top po -A
kubectl edit cm kube-proxy -n kube-system
      # 找到mode字段添加ipvs

#>>> 更新Kube-Proxy的Pod
kubectl patch daemonset kube-proxy -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"date\":\"`date +'%s'`\"}}}}}" -n kube-system

#>>> 验证Kube-Proxy模式
curl 127.0.0.1:10249/proxyMode

yum install -y bash-completion
source /usr/share/bash-completion/bash_completion
source <(kubectl completion bash) 
echo "source <(kubectl completion bash)" >> ~/.bashrc
source ~/.bashrc
