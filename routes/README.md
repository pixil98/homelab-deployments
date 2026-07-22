# Cluster routes

Each destination cluster owns a self-contained subdirectory here. The matching
Flux `Kustomization` under `flux/registrations/` reconciles that directory.
All generated resources are placed in the shared `routing`
namespace owned by `infrastructure-envoy-config`.

Do not put active Kubernetes manifests directly in this directory. See
`docs/cluster-registration.md` for the directory contract and example.
