# Infrastructure cluster deployments

This branch bootstraps the infrastructure Kubernetes cluster with Flux. It
selects the focused `./profiles/routing` profile from the shared
`homelab-flux-core` repository rather than maintaining another copy of shared
cluster infrastructure.

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
reconciles only the shared routing prerequisites. A routing proxy is
intentionally not installed by this change.

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
`homelab-flux-core`. This repository owns only the cluster's selection of the
routing profile and its Flux inputs.
