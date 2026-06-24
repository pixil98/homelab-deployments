#!/usr/bin/env python3
"""Regenerate pvs.yaml from the live cluster.

Dumps every democratic-csi (TrueNAS) PersistentVolume, strips the runtime and
binding-specific fields, forces the reclaim policy to Retain, and reduces each
claimRef to name/namespace so the PV can rebind to a freshly-created PVC after a
cluster rebuild. Output is sorted by PV name for a stable diff.

Usage:
    ./regenerate-pvs.py           # write ./pvs.yaml (next to this script)
    ./regenerate-pvs.py -         # write to stdout
"""
import json
import subprocess
import sys
from pathlib import Path

import yaml

# Keep only democratic-csi (TrueNAS) volumes; node-local provisioners do not
# survive a rebuild and must not be pinned here.
DRIVER_PREFIX = "org.democratic-csi"

# Annotations that are binding/apply artifacts rather than reattach data.
DROP_ANNOTATIONS = {
    "kubectl.kubernetes.io/last-applied-configuration",
    "pv.kubernetes.io/bound-by-controller",
}

# csi.volumeAttributes keys tied to a specific provisioner instance; stale and
# meaningless after a rebuild.
DROP_VOLUME_ATTRIBUTES = {
    "storage.kubernetes.io/csiProvisionerIdentity",
}


def clean(pv):
    spec = pv["spec"]
    md = pv["metadata"]

    annotations = {
        k: v for k, v in (md.get("annotations") or {}).items()
        if k not in DROP_ANNOTATIONS
    }
    # Ensure Flux applies without clobbering an existing live PV.
    annotations["kustomize.toolkit.fluxcd.io/ssa"] = "IfNotPresent"

    metadata = {"name": md["name"], "annotations": annotations}
    if md.get("labels"):
        metadata["labels"] = md["labels"]

    spec["persistentVolumeReclaimPolicy"] = "Retain"

    attrs = (spec.get("csi") or {}).get("volumeAttributes")
    if attrs:
        for key in DROP_VOLUME_ATTRIBUTES:
            attrs.pop(key, None)

    claim = spec.get("claimRef")
    if claim:
        spec["claimRef"] = {
            "apiVersion": claim.get("apiVersion", "v1"),
            "kind": claim.get("kind", "PersistentVolumeClaim"),
            "name": claim["name"],
            "namespace": claim["namespace"],
        }

    return {
        "apiVersion": "v1",
        "kind": "PersistentVolume",
        "metadata": metadata,
        "spec": spec,
    }


def main():
    out = subprocess.run(
        ["kubectl", "get", "pv", "-o", "json"],
        check=True, capture_output=True, text=True,
    ).stdout
    items = json.loads(out)["items"]

    # Retain excludes the ephemeral volsync cache volumes (truenas-*-ephemeral,
    # Delete policy), which are recreated dynamically and must not be pinned.
    pvs = [
        clean(pv) for pv in items
        if (pv["spec"].get("csi") or {}).get("driver", "").startswith(DRIVER_PREFIX)
        and pv["spec"].get("persistentVolumeReclaimPolicy") == "Retain"
    ]
    pvs.sort(key=lambda p: p["metadata"]["name"])

    text = "---\n".join(
        yaml.safe_dump(p, default_flow_style=False, sort_keys=True) for p in pvs
    )

    dest = sys.argv[1] if len(sys.argv) > 1 else "pvs.yaml"
    if dest == "-":
        sys.stdout.write(text)
    else:
        path = Path(__file__).resolve().parent / dest
        path.write_text(text)
        print(f"Wrote {len(pvs)} PVs to {path}", file=sys.stderr)


if __name__ == "__main__":
    main()
