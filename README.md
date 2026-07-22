# Infrastructure cluster deployments

This branch bootstraps the infrastructure Kubernetes cluster with Flux. It
selects the focused `./profiles/routing` profile from the shared
`homelab-flux-core` repository and adds the Envoy Gateway resources that are
specific to this cluster.

## Shared infrastructure profile

The shared routing profile installs:

- MetalLB and the shared L2 address-pool configuration.
- cert-manager for ACME certificate issuance.
- Staging and production `ClusterIssuer` resources that complete Let's Encrypt
  DNS-01 challenges through Cloudflare.
- The shared self-signed CA issuer.

The profile points to the same manifests used by the standard core stack. The
standard profile lives at `./profiles/standard`; the compatibility
`./bootstrap` path continues to select it for existing clusters. This cluster
reconciles only the shared routing prerequisites.

## Envoy Gateway

This repository installs Envoy Gateway and owns the
`infrastructure-routing` `GatewayClass`. Gateways using that class are merged
onto one Envoy data-plane deployment and one MetalLB `LoadBalancer` service.
The service uses `192.168.2.10`; the infrastructure MetalLB pool is
`192.168.2.2-192.168.2.10`.

Envoy terminates client TLS and can establish a separately validated TLS
connection to a destination cluster. The external `Backend` API is enabled so
routes can target an IP address or FQDN outside this Kubernetes cluster.

## Cluster registrations

Registrations are checked into this repository rather than applied directly to
the infrastructure cluster. Each destination cluster owns:

- `routes/<cluster>/`, containing its namespace, certificate, Gateway,
  Backend, routes, and backend TLS policy.
- `flux/registrations/<cluster>.yaml`, containing the Flux `Kustomization`
  that reconciles that route directory after Envoy Gateway and the shared
  certificate issuers are ready.

This avoids a shared registration index, so independently deployed clusters do
not need to edit the same file. See
[the cluster registration contract](docs/cluster-registration.md) for the
required resources and an artificial example.

## Flux inputs

Copy `secrets.example.json` to the ignored `secrets.json` file and replace the
placeholder with a Cloudflare API token. The token should be restricted to the
zones whose certificates will be managed by this cluster and have these
permissions:

- `Zone:DNS:Edit`
- `Zone:Zone:Read`

The cluster Terraform module flattens that value into the `flux-secrets` Secret
as `secrets_infra_cloudflare_apiToken`. The shared routing profile substitutes it
into the cert-manager credential Secret at apply time. The token is not stored in
this repository.

Replace the contact-address placeholder in `values.json` as well. The module
publishes it as `vals_info_cluster_email` for the shared Let's Encrypt issuers.
Set the MetalLB address pool in the same file; it is published as
`vals_infra_metallb_ipAddressPool`.

Controller versions and shared infrastructure resources are maintained in
`homelab-flux-core`. Envoy Gateway and cluster registration resources are
maintained here so they can evolve independently and can be migrated to another
Gateway API implementation later.
