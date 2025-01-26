provider "kubernetes" {
  config_path = "~/.kube/config" # Path to kubeconfig
}

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}

# Load applications dynamically from JSON
locals {
  applications_file = "${path.module}/applications.json" # Define the path to the applications file here
  applications      = jsondecode(file(local.applications_file))["applications"]
}

# Deploy applications
resource "kubernetes_deployment" "apps" {
  for_each = { for app in local.applications : app.name => app }

  metadata {
    name = each.key
    labels = {
      app = each.key
    }
  }

  spec {
    replicas = each.value.replicas

    selector {
      match_labels = {
        app = each.key
      }
    }

    template {
      metadata {
        labels = {
          app = each.key
        }
      }

      spec {
        container {
          image = each.value.image
          name  = each.key

          args = [each.value.args]

          port {
            container_port = each.value.port
          }
        }
      }
    }
  }
}

# Expose services
resource "kubernetes_service" "apps" {
  for_each = { for app in local.applications : app.name => app }

  metadata {
    name = each.key
  }

  spec {
    selector = {
      app = each.key
    }

    port {
      port        = each.value.port
      target_port = each.value.port
    }
  }
}

# Install NGINX Ingress Controller
resource "helm_release" "nginx_ingress" {
  name       = "nginx-ingress"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = "4.0.6"

  values = [
    <<EOF
controller:
  replicaCount: 1
  service:
    type: NodePort
EOF
  ]
}

# Create Ingress for traffic splitting
resource "kubernetes_ingress_v1" "app_ingress" {
  metadata {
    name      = "app-ingress"
    namespace = "default"
  }

  spec {
    # Default ingress rule for the blue app
    rule {
      host = "example.com"

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = kubernetes_service.apps["blue-app"].metadata[0].name
              port {
                number = kubernetes_service.apps["blue-app"].spec[0].port[0].port
              }
            }
          }
        }
      }
    }

    # Dynamic Ingress for traffic weights (Canary traffic splitting)
    dynamic "rule" {
      for_each = { for app in local.applications : app.name => app if app.traffic_weight != "75" }

      content {
        http {
          path {
            path      = "/"
            path_type = "Prefix"

            backend {
              service {
                name = kubernetes_service.apps[rule.value.name].metadata[0].name
                port {
                  number = rule.value.port
                }
              }
            }
          }
        }

        # annotations = {
        #   "nginx.ingress.kubernetes.io/canary"        = "true"
        #   "nginx.ingress.kubernetes.io/canary-weight" = rule.value.traffic_weight
        # }
      }
    }
  }
}
