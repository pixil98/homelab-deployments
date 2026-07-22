# Flux route registrations

The cluster Terraform module writes one Flux `Kustomization` manifest here per
destination cluster. Each manifest points at that cluster's directory under
`routes/` and depends on both `infrastructure-envoy-config` and
`flux-core-routing-cert-manager-config`. It substitutes values from the shared
`flux-values` ConfigMap and `flux-secrets` Secret before applying the route.

There is deliberately no shared Kustomize resource index in this directory.
The root Flux reconciliation discovers the registration manifests recursively,
so independent cluster deployments only modify files that they own.
