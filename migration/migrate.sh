#!/usr/bin/env bash
set -euo pipefail

# Production storage migration script.
# Migrates data from nfs-subdir volumes to truenas-iscsi and truenas-nfs PVCs.
#
# Prerequisites:
#   - Branch merged and Flux has reconciled (truenas-csi driver + storage classes exist)
#   - KUBECONFIG set to production cluster
#   - Static NFS media already rsynced on TrueNAS (audible, audiobooks, ebooks)
#   - PVCs already created by Flux reconciliation
#
# Usage:
#   export KUBECONFIG=~/homelab-deployments/production/kubeconfig
#   ./migration/migrate.sh <step> <cluster-name>
#
# Steps (run in order):
#   0  - Suspend Flux
#   1  - Scale down all deployments and CNPG clusters
#   2  - Run rsync jobs
#   3  - Scale everything back up
#   4  - Resume Flux
#
# To find your cluster name: ls /mnt/main/kubernetes-old/ on TrueNAS

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <step> <cluster-name>"
  echo ""
  echo "Steps:"
  echo "  0  Suspend Flux"
  echo "  1  Scale down all deployments"
  echo "  2  Run rsync jobs"
  echo "  3  Scale everything back up"
  echo "  4  Resume Flux"
  exit 1
fi

STEP="$1"
CLUSTER_NAME="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISCSI_JOBS="${SCRIPT_DIR}/rsync-to-iscsi.yaml"
NFS_JOBS="${SCRIPT_DIR}/rsync-to-nfs.yaml"

if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "ERROR: KUBECONFIG not set"
  exit 1
fi

echo "=== Step $STEP | cluster=$CLUSTER_NAME | context=$(kubectl config current-context) ==="

# ============================================================
# Helpers
# ============================================================

wait_for_no_pods() {
  local ns=$1
  local label=$2
  echo "  Waiting for pods with $label in $ns to terminate..."
  kubectl wait --for=delete pod -l "$label" -n "$ns" --timeout=120s 2>/dev/null || true
}

wait_for_job() {
  local ns=$1
  local job=$2
  local timeout=${3:-600}
  echo "  Waiting for job $job in $ns (timeout ${timeout}s)..."
  if ! kubectl wait --for=condition=complete job/"$job" -n "$ns" --timeout="${timeout}s"; then
    echo "  ERROR: Job $job failed or timed out. Logs:"
    kubectl logs job/"$job" -n "$ns" --tail=20
    return 1
  fi
  echo "  Job $job completed"
}

# ============================================================
# Step dispatch
# ============================================================

case "$STEP" in

0)
  echo "=== Step 0: Suspending Flux ==="
  flux suspend kustomization --all
  echo "All Flux kustomizations suspended."
  echo "Done. Next: $0 1 $CLUSTER_NAME"
  ;;

1)
  echo "=== Step 1: Scaling down deployments ==="

  # mail
  echo "Scaling down mail..."
  kubectl scale deployment dovecot-server postfix-server clamav-server rspamd-server roundcube-server -n mail --replicas=0

  # mapper
  echo "Scaling down mapper..."
  kubectl scale deployment mapper-server mapper-client -n mapper --replicas=0

  # games
  echo "Scaling down games..."
  kubectl scale deployment mud-server -n games --replicas=0

  # paperless
  echo "Scaling down paperless..."
  kubectl scale deployment paperless-server paperless-gotenberg paperless-tika -n paperless --replicas=0

  # media
  echo "Scaling down media..."
  kubectl scale deployment audiobookshelf-server -n media --replicas=0

  # photos
  echo "Scaling down photos..."
  kubectl scale deployment immich-server immich-machine-learning -n photos --replicas=0

  # auth
  echo "Scaling down authentik..."
  kubectl scale deployment authentik-server authentik-worker authentik-outpost-ldap -n auth --replicas=0

  # CNPG clusters (hibernate to stop pods while keeping PVCs)
  echo "Hibernating CNPG clusters..."
  kubectl annotate cluster roundcube-postgresql -n mail cnpg.io/hibernation=on --overwrite
  kubectl annotate cluster paperless-postgresql -n paperless cnpg.io/hibernation=on --overwrite
  kubectl annotate cluster immich-postgresql -n photos cnpg.io/hibernation=on --overwrite
  kubectl annotate cluster authentik-postgresql -n auth cnpg.io/hibernation=on --overwrite

  echo "Waiting for all pods to stop..."
  wait_for_no_pods mail "app.kubernetes.io/name=dovecot"
  wait_for_no_pods mail "app.kubernetes.io/name=postfix"
  wait_for_no_pods mail "app.kubernetes.io/name=clamav"
  wait_for_no_pods mail "app.kubernetes.io/name=rspamd"
  wait_for_no_pods mail "app.kubernetes.io/name=roundcube"
  wait_for_no_pods mapper "app.kubernetes.io/instance=mapper"
  wait_for_no_pods games "app.kubernetes.io/instance=mud"
  wait_for_no_pods paperless "app.kubernetes.io/name=paperless"
  wait_for_no_pods media "app.kubernetes.io/name=audiobookshelf-server"
  wait_for_no_pods photos "app.kubernetes.io/instance=immich"
  wait_for_no_pods auth "app.kubernetes.io/instance=authentik"
  wait_for_no_pods mail "cnpg.io/cluster=roundcube-postgresql"
  wait_for_no_pods paperless "cnpg.io/cluster=paperless-postgresql"
  wait_for_no_pods photos "cnpg.io/cluster=immich-postgresql"
  wait_for_no_pods auth "cnpg.io/cluster=authentik-postgresql"

  echo "All deployments scaled to 0."
  echo "Done. Next: $0 2 $CLUSTER_NAME"
  ;;

2)
  echo "=== Step 2: Running rsync jobs ==="
  sed "s/CLUSTER_NAME/${CLUSTER_NAME}/g" "$ISCSI_JOBS" | kubectl apply -f -
  sed "s/CLUSTER_NAME/${CLUSTER_NAME}/g" "$NFS_JOBS" | kubectl apply -f -

  echo "Waiting for rsync jobs to complete..."
  # iSCSI jobs (small, 600s timeout)
  wait_for_job mail migrate-dovecot-mailboxes
  wait_for_job mail migrate-postfix-spool
  wait_for_job mail migrate-clamav-db
  wait_for_job mail migrate-rspamd-var
  wait_for_job mail migrate-roundcube-postgresql
  wait_for_job mapper migrate-mapper-server-db
  wait_for_job games migrate-mud-server-characters
  wait_for_job paperless migrate-paperless-server-data
  wait_for_job paperless migrate-paperless-postgresql
  wait_for_job media migrate-audiobookshelf-config
  wait_for_job media migrate-audiobookshelf-metadata
  wait_for_job photos migrate-immich-postgresql
  wait_for_job auth migrate-authentik-postgresql

  # NFS jobs (large volumes, longer timeout)
  wait_for_job photos migrate-immich-library 3600
  wait_for_job photos migrate-immich-upload
  wait_for_job photos migrate-immich-encoded-video 3600
  wait_for_job photos migrate-immich-profile 3600
  wait_for_job photos migrate-immich-thumbs 3600
  wait_for_job paperless migrate-paperless-server-media 3600

  echo "All rsync jobs completed."
  echo "Done. Next: $0 3 $CLUSTER_NAME"
  ;;

3)
  echo "=== Step 3: Scaling back up ==="

  # CNPG clusters first (apps depend on them).
  # Remove hibernation annotation to wake them up.
  # initdb policy detects existing PGDATA and skips initialization.
  kubectl annotate cluster roundcube-postgresql -n mail cnpg.io/hibernation- --overwrite
  kubectl annotate cluster paperless-postgresql -n paperless cnpg.io/hibernation- --overwrite
  kubectl annotate cluster immich-postgresql -n photos cnpg.io/hibernation- --overwrite
  kubectl annotate cluster authentik-postgresql -n auth cnpg.io/hibernation- --overwrite

  echo "Waiting for CNPG clusters to be ready..."
  kubectl wait --for=condition=Ready cluster/roundcube-postgresql -n mail --timeout=120s
  kubectl wait --for=condition=Ready cluster/paperless-postgresql -n paperless --timeout=120s
  kubectl wait --for=condition=Ready cluster/immich-postgresql -n photos --timeout=120s
  kubectl wait --for=condition=Ready cluster/authentik-postgresql -n auth --timeout=120s

  # Deployments
  kubectl scale deployment dovecot-server postfix-server clamav-server rspamd-server roundcube-server -n mail --replicas=1
  kubectl scale deployment mapper-server mapper-client -n mapper --replicas=1
  kubectl scale deployment mud-server -n games --replicas=1
  kubectl scale deployment paperless-server paperless-gotenberg paperless-tika -n paperless --replicas=1
  kubectl scale deployment audiobookshelf-server -n media --replicas=1
  kubectl scale deployment immich-server immich-machine-learning -n photos --replicas=1
  kubectl scale deployment authentik-server authentik-worker authentik-outpost-ldap -n auth --replicas=1

  echo "All deployments scaled back up."
  echo "Done. Next: $0 4 $CLUSTER_NAME"
  ;;

4)
  echo "=== Step 4: Resuming Flux ==="
  flux resume kustomization --all
  echo "Flux resumed."

  echo ""
  echo "=== Migration complete ==="
  echo "Monitor with: kubectl get pods -A | grep -v Running"
  echo ""
  echo "Next steps:"
  echo "  1. Verify all pods are running"
  echo "  2. Export PV manifests for disaster recovery:"
  echo "       ./migration/export-pvs.sh > ~/homelab-deployments/production/pvs.yaml"
  echo "  3. Commit pvs.yaml to homelab-deployments"
  echo "  4. Cleanup migration jobs:"
  echo "       sed \"s/CLUSTER_NAME/${CLUSTER_NAME}/g\" $ISCSI_JOBS | kubectl delete -f -"
  echo "       sed \"s/CLUSTER_NAME/${CLUSTER_NAME}/g\" $NFS_JOBS | kubectl delete -f -"
  ;;

*)
  echo "ERROR: Unknown step '$STEP'. Valid steps: 0, 1, 2, 3, 4"
  exit 1
  ;;

esac
