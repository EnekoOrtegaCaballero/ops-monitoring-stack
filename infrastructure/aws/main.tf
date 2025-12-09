cat << 'EOF' > infrastructure/aws/main.tf
# 1. Obtener la última imagen de Ubuntu 22.04 automáticamente
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical (Dueños de Ubuntu)

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# 2. Crear una llave SSH temporal (por si necesitamos entrar a debuggear)
resource "tls_private_key" "lab_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "generated_key" {
  key_name   = "${var.project_name}-key"
  public_key = tls_private_key.lab_key.public_key_openssh
}

# Guardar la llave privada en tu PC por si acaso
resource "local_file" "private_key" {
  content  = tls_private_key.lab_key.private_key_pem
  filename = "${path.module}/lab_key.pem"
  file_permission = "0400"
}

# 3. Security Group (Firewall)
resource "aws_security_group" "lab_sg" {
  name        = "${var.project_name}-sg"
  description = "Permitir salida total, bloquear entrada (Tailscale rules)"

  # Salida: Permitir TODO (necesario para descargar Docker, conectar a Tailscale, etc)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Entrada: CERRADO TOTALMENTE.
  # Demostramos que la monitorización funciona por VPN sin abrir puertos.
}

# 4. La Instancia EC2 (El servidor SQL)
resource "aws_instance" "sql_server" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.medium" # 2 vCPU, 4GB RAM (Suficiente para SQL + Caos)
  key_name      = aws_key_pair.generated_key.key_name
  
  security_groups = [aws_security_group.lab_sg.name]

  root_block_device {
    volume_size = 20 # 20GB de disco
    volume_type = "gp3"
  }

  tags = {
    Name = "SQL-Server-Target"
  }

  # AQUÍ OCURRE LA MAGIA: El script de inicio
  user_data = templatefile("user_data.sh", {
    TAILSCALE_KEY = var.tailscale_auth_key
    VPS_IP        = var.vps_monitoring_ip
  })
}

output "instance_ip" {
  value = aws_instance.sql_server.public_ip
}
EOF
