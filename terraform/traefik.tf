# Gateway do cluster: recebe o trafego do NLB no NodePort e roteia pelas IngressRoutes
# de cada servico. Chart fixado na versao estavel mais recente em 2026-11-03
# (42.3.0, Traefik v3.7.17).
resource "helm_release" "traefik" {
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = "42.3.0"
  namespace        = "traefik"
  create_namespace = true

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 300

  values = [
    yamlencode({
      # No chart 42 o tipo fica em service.spec; "service.type" e ignorado em silencio
      # e o Service sairia LoadBalancer (um ELB fora do Terraform).
      service = {
        spec = {
          type = "NodePort"
        }
      }

      ports = {
        web = {
          nodePort = var.traefik_node_port
        }
        # TLS termina no API Gateway; o NLB so encaminha HTTP.
        websecure = {
          expose = {
            default = false
          }
        }
      }

      api = {
        dashboard = false
      }

      ingressRoute = {
        dashboard = {
          enabled = false
        }
      }

      log = {
        format = "json"
      }

      accessLog = {
        enabled = true
        format  = "json"
      }
    })
  ]

  depends_on = [aws_eks_node_group.this, aws_eks_addon.metrics_server]
}
