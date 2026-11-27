variable "region" {
  description = "阿里云地域"
  type        = string
  default     = "cn-hangzhou"
}

variable "availability_zone" {
  description = "可用区 ID；留空则自动挑选支持 worker 规格与 ESSD 的第一个可用区"
  type        = string
  default     = ""
}

variable "vpc_cidr" {
  description = "VPC 网段"
  type        = string
  default     = "10.0.0.0/16"
}

variable "vswitch_cidr" {
  description = "交换机网段（节点与 CLB 都在此网段内）"
  type        = string
  default     = "10.0.1.0/24"
}

variable "master_count" {
  description = "控制节点数量（etcd 要求奇数，3 为最小高可用）"
  type        = number
  default     = 3

  validation {
    condition     = var.master_count % 2 == 1 && var.master_count >= 3
    error_message = "master_count 必须是 >= 3 的奇数。"
  }
}

variable "master_instance_type" {
  description = "控制节点规格（2C4G；预算允许可升 ecs.c7.xlarge/4C8G）"
  type        = string
  default     = "ecs.c7.large"
}

variable "master_system_disk_size" {
  description = "控制节点系统盘大小（GiB，etcd + 系统）"
  type        = number
  default     = 40
}

variable "worker_count" {
  description = "工作节点数量"
  type        = number
  default     = 3
}

variable "worker_instance_type" {
  description = "工作节点规格（8C16G）"
  type        = string
  default     = "ecs.c7.2xlarge"
}

variable "worker_system_disk_size" {
  description = "工作节点系统盘大小（GiB，容器镜像 + 系统）"
  type        = number
  default     = 40
}

variable "worker_data_disk_size" {
  description = "工作节点数据盘大小（GiB，承载全部 prod PVC：合计约 70G）"
  type        = number
  default     = 80
}

variable "image_name_regex" {
  description = "系统镜像名称正则（默认 Ubuntu 22.04）"
  type        = string
  default     = "^ubuntu_22"
}

variable "key_pair_name" {
  description = "阿里云密钥对名称"
  type        = string
  default     = "micro-bl"
}

variable "ssh_public_key" {
  description = "SSH 公钥内容（必填，写入 alicloud_key_pair）"
  type        = string
  default     = ""

  validation {
    condition     = length(trimspace(var.ssh_public_key)) > 0
    error_message = "必须提供 ssh_public_key（在 terraform.tfvars 中填写）。"
  }
}

variable "ssh_cidr" {
  description = "允许 SSH 与 6443（kubectl 直连 master）的来源 CIDR，强烈建议只填自己的公网 IP/32"
  type        = string
  default     = ""

  validation {
    condition     = length(trimspace(var.ssh_cidr)) > 0 && var.ssh_cidr != "0.0.0.0/0" && can(cidrhost(var.ssh_cidr, 0))
    error_message = "必须提供 ssh_cidr（例如 1.2.3.4/32），禁止留空，也禁止 0.0.0.0/0（SSH 与 6443 只应对自己的公网 IP 开放）。"
  }
}

variable "node_port_cidr" {
  description = "允许访问 NodePort 入口的来源 CIDR；必须收敛为自己的公网 IP/32（与 ssh_cidr 同值即可）"
  type        = string
  default     = ""

  validation {
    condition     = length(trimspace(var.node_port_cidr)) > 0 && var.node_port_cidr != "0.0.0.0/0" && can(cidrhost(var.node_port_cidr, 0))
    error_message = "必须提供 node_port_cidr（例如 1.2.3.4/32）：禁止留空，也禁止 0.0.0.0/0（Harbor/ArgoCD/Grafana 密码较弱，入口必须只对自己的 IP 开放）。"
  }
}

variable "internet_max_bandwidth_out" {
  description = "每台节点公网出带宽上限（Mbps），按流量计费"
  type        = number
  default     = 10
}

variable "tags" {
  description = "通用标签"
  type        = map(string)
  default = {
    project = "micro-bl"
    env     = "prod"
  }
}
