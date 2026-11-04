# OpenTelemetry Operator: instala os CRDs (OpenTelemetryCollector,
# Instrumentation) e o admission webhook que injeta o agente Java nos pods
# anotados. O Collector, a Instrumentation e o secret do Datadog ficam em k8s/ e
# sao aplicados pelo workflow cluster.yml depois deste apply.
resource "helm_release" "opentelemetry_operator" {
  name             = "opentelemetry-operator"
  namespace        = "opentelemetry-system"
  create_namespace = true

  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-operator"
  version    = "0.114.0"

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  wait_for_jobs   = true
  timeout         = 300

  values = [
    yamlencode({
      crds = {
        create = true
      }

      manager = {
        collectorImage = {
          repository = "otel/opentelemetry-collector-contrib"
        }
      }

      admissionWebhooks = {
        certManager = {
          enabled = false
        }

        autoGenerateCert = {
          enabled = true
        }
      }
    })
  ]

  depends_on = [aws_eks_node_group.this]
}
