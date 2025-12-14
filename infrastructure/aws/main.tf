data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "tls_private_key" "lab_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "generated_key" {
  key_name   = "${var.project_name}-key"
  public_key = tls_private_key.lab_key.public_key_openssh
}

resource "local_file" "private_key" {
  content         = tls_private_key.lab_key.private_key_pem
  filename        = "${path.module}/lab_key.pem"
  file_permission = "0400"
}

resource "aws_security_group" "lab_sg" {
  name        = "${var.project_name}-sg"
  description = "Salida permitida, Entrada bloqueada (VPN Only)"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "sql_server" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.medium"
  key_name      = aws_key_pair.generated_key.key_name
  
  security_groups = [aws_security_group.lab_sg.name]

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = {
    Name = "SQL-Server-Target"
  }

  # --- AQUI ESTA EL CAMBIO ---
  # Pasamos la nueva variable DB_PASSWORD al script
  user_data = templatefile("user_data.sh", {
    TAILSCALE_KEY = var.tailscale_auth_key
    VPS_IP        = var.vps_monitoring_ip
    DB_PASSWORD   = var.db_password
    ZABBIX_USER   = var.zabbix_user
    ZABBIX_PASS   = var.zabbix_pass
  })
}

output "instance_ip" {
  value = aws_instance.sql_server.public_ip
}
