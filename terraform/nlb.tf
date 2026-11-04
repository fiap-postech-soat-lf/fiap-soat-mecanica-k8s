# NLB publico (HTTP) -> Traefik NodePort em todos os nodes. O API Gateway do -auth
# integra com ele por HTTP_PROXY (ADR-F4-06).
# Rede (F2-i): o NLB tem SG proprio, e o SG do cluster so aceita o NodePort a partir dele.

resource "aws_security_group" "nlb" {
  name        = "${var.project}-nlb"
  description = "NLB publico do Traefik"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name = "${var.project}-nlb"
  }
}

resource "aws_vpc_security_group_ingress_rule" "nlb_http" {
  security_group_id = aws_security_group.nlb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  description       = "Internet -> NLB:80"
}

resource "aws_vpc_security_group_egress_rule" "nlb_para_traefik" {
  security_group_id            = aws_security_group.nlb.id
  referenced_security_group_id = local.cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = var.traefik_node_port
  to_port                      = var.traefik_node_port
  description                  = "NLB -> nodes no NodePort do Traefik"
}

resource "aws_vpc_security_group_ingress_rule" "traefik_do_nlb" {
  security_group_id            = local.cluster_security_group_id
  referenced_security_group_id = aws_security_group.nlb.id
  ip_protocol                  = "tcp"
  from_port                    = var.traefik_node_port
  to_port                      = var.traefik_node_port
  description                  = "NodePort do Traefik so a partir do NLB (trafego e health check)"
}

resource "aws_lb" "this" {
  name                             = "${var.project}-nlb"
  load_balancer_type               = "network"
  internal                         = false
  subnets                          = local.subnet_ids
  security_groups                  = [aws_security_group.nlb.id] # so pode ser definido na criacao
  enable_cross_zone_load_balancing = true
}

resource "aws_lb_target_group" "traefik" {
  name        = "${var.project}-traefik"
  port        = var.traefik_node_port
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = data.aws_vpc.default.id

  health_check {
    protocol = "TCP"
    port     = "traffic-port"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.traefik.arn
  }
}

# Registra as instancias do ASG do node group no target group (inclusive as recriadas).
resource "aws_autoscaling_attachment" "traefik" {
  autoscaling_group_name = aws_eks_node_group.this.resources[0].autoscaling_groups[0].name
  lb_target_group_arn    = aws_lb_target_group.traefik.arn
}
