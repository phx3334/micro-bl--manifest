[masters]
%{ for m in masters ~}
${m.name} ansible_host=${m.public_ip} private_ip=${m.private_ip}
%{ endfor ~}

[workers]
%{ for w in workers ~}
${w.name} ansible_host=${w.public_ip} private_ip=${w.private_ip}
%{ endfor ~}

[all:vars]
ansible_user=root
ansible_python_interpreter=/usr/bin/python3
apiserver_endpoint=${apiserver_endpoint}
