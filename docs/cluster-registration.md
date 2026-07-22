# Cluster routing registration

Each destination cluster checks two self-contained sets of files into this
repository. Its Terraform state owns only those files and does not apply routing
resources directly to the infrastructure Kubernetes API.

## Repository contract

For a cluster named `<cluster>`, create:

- `flux/registrations/<cluster>.yaml`: a Flux `Kustomization` pointing at the
  route directory.
- `routes/<cluster>/kustomization.yaml`: the directory's Kustomize resource
  list.
- `routes/<cluster>/routing.yaml`: the cluster's routing resources.

The Flux object must depend on `infrastructure-envoy-config` and
`flux-core-routing-cert-manager-config`. The former creates the shared
`routing` namespace before any registration is applied. The Flux object must
use the shared `flux-values` ConfigMap and `flux-secrets`
Secret for post-build substitution, matching the rest of the cluster. Every
cluster registration then contributes only its listeners, routes, and backend
configuration. The shared Envoy service requests the stable address with
`${vals_infra_envoyGateway_loadBalancerIP}`.

Deleting a cluster registration must delete both its route directory and Flux
manifest. Flux pruning will then remove the resources previously applied for
that cluster.

## Resource contract

For each base domain, the route directory creates the following resources in
the shared `routing` namespace. Resource names must be unique to the destination
cluster.

1. A cert-manager `Certificate` containing `<domain>` and `*.<domain>`, issued
   by `letsencrypt-production-cloudflare`.
2. A `Gateway` using `routing`, with separate apex and wildcard HTTP and HTTPS
   listeners. The shared Envoy service owns the stable load-balancer address.
3. An Envoy Gateway `Backend` containing an IP or FQDN endpoint reachable from
   the infrastructure cluster. It must not resolve back to this Envoy gateway.
4. An HTTP `HTTPRoute` that redirects both hostnames to HTTPS.
5. An HTTPS `HTTPRoute` that forwards both hostnames to the external Backend.
6. For a TLS backend, a `BackendTLSPolicy` containing the backend SNI and trust
   configuration.

Envoy preserves the incoming `Host` header unless a route explicitly rewrites
it. The backend TLS connection uses the policy hostname for SNI and certificate
validation; this is independent of the edge certificate stored in the
infrastructure cluster.

The MetalLB address is the internal Envoy service address. Cloudflare DNS must
point at the externally reachable address for the environment, which may be a
NAT, proxy, or tunnel address rather than the MetalLB address itself.

## Artificial example

For `cluster-a`, Terraform would create this Flux object at
`flux/registrations/cluster-a.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: route-cluster-a
  namespace: flux-system
spec:
  dependsOn:
    - name: infrastructure-envoy-config
    - name: flux-core-routing-cert-manager-config
  interval: 10m
  path: ./routes/cluster-a
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: flux-values
      - kind: Secret
        name: flux-secrets
  prune: true
  retryInterval: 1m
  sourceRef:
    kind: GitRepository
    name: flux-system
  timeout: 15m
  wait: true
```

Its `routes/cluster-a/kustomization.yaml` is:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - routing.yaml
```

An HTTPS backend registration in `routes/cluster-a/routing.yaml` looks like:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: a
  namespace: routing
spec:
  dnsNames:
    - a.example
    - "*.a.example"
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: letsencrypt-production-cloudflare
  privateKey:
    rotationPolicy: Always
  secretName: a-tls
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: a
  namespace: routing
spec:
  gatewayClassName: routing
  listeners:
    - hostname: a.example
      name: http-apex
      port: 80
      protocol: HTTP
    - hostname: "*.a.example"
      name: http-wildcard
      port: 80
      protocol: HTTP
    - hostname: a.example
      name: https-apex
      port: 443
      protocol: HTTPS
      tls:
        certificateRefs:
          - group: ""
            kind: Secret
            name: a-tls
        mode: Terminate
    - hostname: "*.a.example"
      name: https-wildcard
      port: 443
      protocol: HTTPS
      tls:
        certificateRefs:
          - group: ""
            kind: Secret
            name: a-tls
        mode: Terminate
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: Backend
metadata:
  name: a
  namespace: routing
spec:
  endpoints:
    - fqdn:
        hostname: backend.a.test
        port: 443
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: a-http-redirect
  namespace: routing
spec:
  hostnames:
    - a.example
    - "*.a.example"
  parentRefs:
    - name: a
      sectionName: http-apex
    - name: a
      sectionName: http-wildcard
  rules:
    - filters:
        - requestRedirect:
            scheme: https
            statusCode: 301
          type: RequestRedirect
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: a-https
  namespace: routing
spec:
  hostnames:
    - a.example
    - "*.a.example"
  parentRefs:
    - name: a
      sectionName: https-apex
    - name: a
      sectionName: https-wildcard
  rules:
    - backendRefs:
        - group: gateway.envoyproxy.io
          kind: Backend
          name: a
---
apiVersion: gateway.networking.k8s.io/v1alpha3
kind: BackendTLSPolicy
metadata:
  name: a
  namespace: routing
spec:
  targetRefs:
    - group: gateway.envoyproxy.io
      kind: Backend
      name: a
  validation:
    hostname: a.example
    wellKnownCACertificates: System
```

For a plain HTTP backend, use its HTTP port in the `Backend` and omit the
`BackendTLSPolicy`.
