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

variable "master_spot_strategy" {
  description = "控制节点计费策略：NoSpot（按量，推荐）| SpotAsPriceGo（抢占，跟随市价）| SpotWithPriceLimit"
  type        = string
  default     = "NoSpot"

  validation {
    condition     = contains(["NoSpot", "SpotAsPriceGo", "SpotWithPriceLimit"], var.master_spot_strategy)
    error_message = "master_spot_strategy 只能是 NoSpot / SpotAsPriceGo / SpotWithPriceLimit。"
  }
}

variable "worker_spot_strategy" {
  description = "工作节点计费策略：默认 SpotAsPriceGo（抢占式，最高可省约 90%，但可能被回收）"
  type        = string
  default     = "SpotAsPriceGo"

  validation {
    condition     = contains(["NoSpot", "SpotAsPriceGo", "SpotWithPriceLimit"], var.worker_spot_strategy)
    error_message = "worker_spot_strategy 只能是 NoSpot / SpotAsPriceGo / SpotWithPriceLimit。"
  }
}

variable "spot_price_limit" {
  description = "抢占式实例出价上限（元/小时），仅 SpotWithPriceLimit 生效；0 表示不设置"
  type        = number
  default     = 0
}

variable "image_name_regex" {
  description = "系统镜像名称正则（Ubuntu 22.04 标准 20G 镜像）"
  type        = string
  # 必须钉住 20G 系列：^ubuntu_22 太宽，most_recent 会挑到最新的
  # 100G GPU+CUDA 镜像（ubuntu_22_04_x64_100G_with_gpu_driver_and_cuda_alibase_*），
  # 导致 system_disk_size=40 报 InvalidSystemDiskSize.LessThanImageSize。
  # \d+G_alibase 要求容量后紧跟 _alibase，GPU 镜像中间插了 with_gpu_driver，
  # 匹配不上；镜像恒为 20G，40GiB 系统盘永远满足 >= 镜像容量。
  default = "^ubuntu_22_04_x64_20G_alibase"
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
  description = "允许 SSH 与 6443（kubectl 直连 master）的来源 CIDR；本机 IP 会变/开代理时用 0.0.0.0/0"
  type        = string
  default     = ""

  validation {
    condition     = length(trimspace(var.ssh_cidr)) > 0 && can(cidrhost(var.ssh_cidr, 0))
    error_message = "必须提供 ssh_cidr（合法 CIDR，例如 0.0.0.0/0 或 1.2.3.4/32），禁止留空。"
  }
}

variable "node_port_cidr" {
  description = "允许访问 NodePort 入口的来源 CIDR；本机 IP 会变/开代理时用 0.0.0.0/0（GitHub Webhook 30081 也需要它放行）"
  type        = string
  default     = ""

  validation {
    condition     = length(trimspace(var.node_port_cidr)) > 0 && can(cidrhost(var.node_port_cidr, 0))
    error_message = "必须提供 node_port_cidr（合法 CIDR，例如 0.0.0.0/0 或 1.2.3.4/32），禁止留空。"
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
