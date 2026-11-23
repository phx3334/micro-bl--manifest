# Ansible inventory模板，Terraform templatefile渲染
# ansible_host：公网IP，用于本地SSH登录ECS
# private_ip：自定义变量，固定内网IP，供K3s集群内部通信使用
[masters]
%{ for m in masters ~}
${m.name} ansible_host=${m.public_ip} private_ip=${m.private_ip}
%{ endfor ~}

[workers]
%{ for w in workers ~}
${w.name} ansible_host=${w.public_ip} private_ip=${w.private_ip}
%{ endfor ~}

# 全局变量：所有节点生效
[all:vars]
ansible_user=root
ansible_python_interpreter=/usr/bin/python3
apiserver_endpoint=${apiserver_endpoint} # CLB控制面入口
