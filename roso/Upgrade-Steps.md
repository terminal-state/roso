# RHOSO + OCP Upgrade Runbook
**Cluster:** https://api.ocp-upgrade.cluster.test:6443  
**Logged in as:** kube:admin  
**Date started:** 2026-06-22  
**Author:** scottlryan@gmail.com

---

## Overview

This runbook covers the full upgrade of Red Hat OpenStack Services on OpenShift (RHOSO) and
OpenShift Container Platform (OCP) for a 3-node compact cluster.

| Item | From | To |
|---|---|---|
| RHOSO | 18.0.18 (already satisfies 18.0.6+ requirement) | No change required |
| OCP | 4.16.55 | 4.18.43 (EUS-to-EUS, via 4.16.62 and 4.17.54) |

### Actual Upgrade Path Taken

```
OCP:   4.16.55 → 4.16.62 → 4.17.54 → 4.18.43
RHOSO: 18.0.18 (unchanged throughout — operator survives all hops via OLM)
```

> **EUS-to-EUS clarification:** The CVO (Cluster Version Operator) must traverse 4.17 internally.
> What EUS saves you is worker node reboots for 4.17 machine configs. With MCPs paused, worker
> nodes only reboot once — for 4.18. In a compact cluster (all nodes are masters), master nodes
> reboot for each hop since the master MCP cannot be paused, but the end state is fully 4.18.

---

## Cluster Baseline (Pre-Upgrade State)

| Item | Value |
|---|---|
| OCP Version | 4.16.55 |
| OCP Channel | stable-4.16 |
| Cluster Topology | 3-node compact — master-1, master-2, master-3 (all are control-plane + worker) |
| Worker MCP members | 0 (no separate worker nodes) |
| RHOSO Version | 18.0.18 — `openstack-operator.v1.18.0` |
| RHOSO Namespace | `openstack` (not `openstack-operators` — varies by deployment method) |
| Operator Channel | `stable-v1.0` |
| InstallPlanApproval | Automatic |
| Catalog Source | `registry.redhat.io/redhat/redhat-operator-index:v4.16` |
| Catalog Poll Interval | 10 minutes |
| Cluster Operators | All 33 healthy (Available=True, Progressing=False, Degraded=False) |
| cert-manager | **Not installed** (required by OpenStack init CR — post-upgrade task) |
| StorageClass | **None** (required for OpenStackControlPlane — post-upgrade task) |

### RHOSO Version Reference
Source: https://access.redhat.com/articles/7125383

| RHOSO Version | Operator CSV | OpenStackVersion | Release Type |
|---|---|---|---|
| 18.0.0 | v1.0.0 | 18.0.0-20240715.2 | GA |
| 18.0.1 | v1.0.2 | 18.0.0-20240909.2 | Bug fix |
| 18.0.2 | v1.0.3 | 18.0.2-20240923.2 | Bug fix |
| 18.0.3 | v1.0.4 | 18.0.3-20241025.2 | Feature Release 1 |
| 18.0.4 | v1.0.6 | 18.0.4-20250106.2 | Bug fix |
| 18.0.5 | v1.0.7 | 18.0.6-20250317.1 | |
| 18.0.6 | v1.0.8 | 18.0.6-20250403.1 | Container grade update |
| 18.0.7 | v1.0.9 | 18.0.7-20250408.2 | Bug fix |
| 18.0.8 | v1.0.10 | 18.0.8-20250505.2 | Bug fix |
| 18.0.9 | v1.0.11 | 18.0.9-20250602.2 | Bug fix |
| 18.0.10 | v1.0.12 | 18.0.10-20250701.2 | Feature Release 3 |
| 18.0.11 | v1.0.13 | 18.0.11-20250812.2 | Bug fix |
| 18.0.12 | v1.0.14 | 18.0.12-20250902.2 | Bug fix |
| 18.0.13 | v1.0.15 | 18.0.13-20250925.165646 | Bug fix |
| 18.0.14 | v1.0.16 | 18.0.14-20251103.185748 | Feature Release 4 |
| 18.0.15 | v1.0.18 | 18.0.15-20251126.192455 | Bug fix |
| 18.0.16 | v1.0.19 | 18.0.16-20260205.180629 | Bug fix |
| 18.0.17 | v1.0.20 | 18.0.17-20260310.171110 | Feature Release 5 |
| **18.0.18** | **v1.18.0** | **18.0.18-20260422.194755** | **Bug fix — current** |

---

## Phase 0 — Pre-Upgrade Backups

> **Run these before touching anything.**
>
> Two independent backups are required — they protect different layers and neither
> substitutes for the other:
>
> | Backup | Tool | Protects | Restores |
> |---|---|---|---|
> | OCP cluster state | etcd `cluster-backup.sh` | API server, CVO, cluster operators, RBAC | Full OCP cluster |
> | OpenStack namespace | OADP (Velero) | All RHOSO CRs, secrets, configmaps, PVC data | `openstack` namespace only |
>
> **OADP is the primary recovery mechanism for any OpenStack / RHOSO issue.**
> It takes a complete, consistent snapshot of everything in the `openstack` namespace —
> operator configuration, credentials, and database contents — and restores with a single
> command. The etcd backup is the last-resort path only if OCP itself becomes unrecoverable.

---

### 0A. Install OADP Operator

OADP (OpenShift API for Data Protection) is the Red Hat-supported backup and restore solution
built on Velero. It must be installed before any backup can be taken.

```bash
cat > oadp-install.yaml <<'EOF'
---
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-adp
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-adp
  namespace: openshift-adp
spec:
  targetNamespaces:
    - openshift-adp
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: redhat-oadp-operator
  namespace: openshift-adp
spec:
  channel: stable-1.4
  name: redhat-oadp-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

oc apply -f oadp-install.yaml
```

**Verify the operator is ready before continuing:**

```bash
# Watch until Phase = Succeeded (typically 2-3 minutes)
watch oc get csv -n openshift-adp

# Expected final state:
# NAME                         DISPLAY   VERSION   PHASE
# redhat-oadp-operator.v1.4.x  OADP      1.4.x     Succeeded
```

---

### 0B. Configure Backup Storage (DataProtectionApplication)

OADP requires an S3-compatible object store to hold backup archives. Choose the option
that matches your environment.

**Create the storage credentials secret first:**

```bash
# Replace with actual access key and secret
cat > oadp-credentials.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: cloud-credentials
  namespace: openshift-adp
stringData:
  cloud: |
    [default]
    aws_access_key_id=<your-access-key>
    aws_secret_access_key=<your-secret-key>
EOF

oc apply -f oadp-credentials.yaml
```

**Create the DataProtectionApplication CR:**

> Choose the config block that matches the storage backend. Remove the unused options.

```bash
cat > oadp-dpa.yaml <<'EOF'
---
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: rhoso-dpa
  namespace: openshift-adp
spec:
  configuration:
    velero:
      defaultPlugins:
        - openshift    # required for OCP namespace restore
        - aws          # required for S3-compatible storage
        - csi          # required for CSI volume snapshots
      resourceTimeout: 10m
    nodeAgent:
      enable: true
      uploaderType: kopia    # kopia provides efficient incremental backups
  backupLocations:
    - name: default
      velero:
        provider: aws
        default: true
        objectStorage:
          bucket: <your-bucket-name>
          prefix: rhoso-backups
        config:
          region: <your-region>
          # --- For MinIO or Ceph RGW (self-hosted S3): uncomment these two lines ---
          # s3Url: http://<minio-or-rgw-host>:<port>
          # s3ForcePathStyle: "true"
        credential:
          name: cloud-credentials
          key: cloud
EOF

oc apply -f oadp-dpa.yaml
```

**Verify OADP is fully operational:**

```bash
# Check all OADP pods are Running (velero + node-agent daemonset)
oc get pods -n openshift-adp
# Expected pods: velero-xxx (1/1 Running), node-agent-xxx on each node

# BackupStorageLocation MUST show Available before taking any backup
oc get backupstoragelocation -n openshift-adp
# Expected:
# NAME      PHASE       LAST VALIDATED   AGE
# default   Available   <recent time>    ...

# If it shows Unavailable, check credentials and bucket connectivity:
oc logs -n openshift-adp deployment/velero | tail -20
```

**Expected outcome:** All pods Running, BackupStorageLocation `Available`.
Do not proceed until storage location is Available — a backup taken with an
Unavailable storage location will silently fail.

---

### 0C. Take Pre-Upgrade OADP Backup of the OpenStack Namespace

This backup captures the complete state of RHOSO:
- All operator CRs (OpenStack, OpenStackControlPlane, Galera, Keystone, Nova, Neutron, etc.)
- All secrets (database passwords, service credentials, TLS certificates)
- All configmaps and service accounts
- PVC data (Galera database contents, RabbitMQ state)

> **What this backup does NOT protect:** Nova instance data (stored in Ceph/Cinder,
> independent of the namespace), running instance state (survives in libvirt regardless).

```bash
cat > openstack-backup-pre-upgrade.yaml <<'EOF'
---
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: openstack-pre-upgrade
  namespace: openshift-adp
  labels:
    backup-type: pre-upgrade
spec:
  includedNamespaces:
    - openstack
  storageLocation: default
  ttl: 720h0m0s                  # retain for 30 days
  defaultVolumesToFsBackup: true  # backs up PVC contents via kopia file-system copy
  snapshotVolumes: false
  # Exclude ephemeral pod state — we only need CRs, secrets, and PVC data
  excludedResources:
    - pods
    - replicasets
    - endpoints
    - events
EOF

oc apply -f openstack-backup-pre-upgrade.yaml
```

**Monitor the backup to completion:**

```bash
# Watch status — typically takes 5-20 min depending on PVC data volume
oc get backup openstack-pre-upgrade -n openshift-adp -w

# Expected progression:
# NAME                     STATUS      ERRORS   WARNINGS
# openstack-pre-upgrade    New         0        0
# openstack-pre-upgrade    InProgress  0        0
# openstack-pre-upgrade    Completed   0        0
```

**Verify the backup is usable:**

```bash
# Check phase and counts
oc describe backup openstack-pre-upgrade -n openshift-adp | \
  grep -A5 "Status:"

# Key fields to confirm:
#   Phase:              Completed
#   Errors:             0
#   Items Backed Up:    <number> (should be > 0)
#   Start Timestamp:    <time>
#   Completion Timestamp: <time>
```

**If errors > 0**, do not proceed with the upgrade. Check:
```bash
oc logs -n openshift-adp deployment/velero | grep -i error | tail -30
```

**Expected outcome:** Phase `Completed`, Errors `0`. Warnings are acceptable.

---

### 0D. Configure Daily Scheduled Backups

Automated daily backups ensure you always have a recent restore point — not just the
pre-upgrade snapshot.

```bash
cat > openstack-backup-schedule.yaml <<'EOF'
---
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: openstack-daily
  namespace: openshift-adp
spec:
  schedule: "0 2 * * *"      # 02:00 UTC every day
  paused: false
  template:
    includedNamespaces:
      - openstack
    storageLocation: default
    ttl: 168h0m0s             # retain each backup for 7 days (rolling 7-day window)
    defaultVolumesToFsBackup: true
    snapshotVolumes: false
    excludedResources:
      - pods
      - replicasets
      - endpoints
      - events
EOF

oc apply -f openstack-backup-schedule.yaml
```

**Verify schedule and trigger a test run immediately:**

```bash
# Confirm schedule was created
oc get schedule -n openshift-adp

# Trigger an immediate backup from the schedule to confirm it works
oc create job --from=schedule/openstack-daily \
  openstack-daily-test -n openshift-adp 2>/dev/null || \
oc create -f - <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: openstack-daily-test
  namespace: openshift-adp
spec:
  includedNamespaces:
    - openstack
  storageLocation: default
  ttl: 24h0m0s
  defaultVolumesToFsBackup: true
  snapshotVolumes: false
EOF

oc get backup openstack-daily-test -n openshift-adp -w
```

**List all backups at any time:**

```bash
oc get backup -n openshift-adp \
  --sort-by='.metadata.creationTimestamp'
```

---

### 0E. Back Up OCP Cluster State (etcd)

Required separately from OADP — covers the OCP cluster itself, which OADP cannot restore.

```bash
# Run on any one master node
oc debug node/master-1 -- \
  chroot /host \
  /usr/local/bin/cluster-backup.sh /home/core/assets/backup

# Expected output:
# Snapshot saved at /home/core/assets/backup/snapshot_<timestamp>_openshift_v4.18.db
# Static pod resources backed up at /home/core/assets/backup/static_kuberesources_<timestamp>

# Copy off the node to safe external storage immediately
# The backup files are only on the node — they will be lost if the node fails
```

> Full procedure: https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/backup_and_restore/control-plane-backup-and-restore

---

### Phase 0 Gate Checklist

```
[ ] OADP operator CSV shows Succeeded
[ ] All OADP pods Running in openshift-adp namespace
[ ] BackupStorageLocation shows Available
[ ] openstack-pre-upgrade backup: Phase=Completed, Errors=0
[ ] openstack-daily schedule created and test backup verified
[ ] etcd snapshot taken and copied to off-cluster storage
```

**Do not proceed to Phase A until every item above is checked.**

---

## Phase A — RHOSO Readiness on OCP 4.16

### A1. Verify Operator Version and Health
**Date:** 2026-06-22  
**Status:** COMPLETE

```bash
oc get csv -n openstack | grep openstack
oc get pods -n openstack
oc get subscription openstack-operator -n openstack -o yaml
```

**Expected outcome:**
- CSV phase shows `Succeeded`
- At least one operator pod in `Running` state
- Subscription `state: AtLatestKnown`
- RHOSO version must be 18.0.6 or newer before OCP upgrade begins

**Actual result:**
- CSV: `openstack-operator.v1.18.0` — Phase: `Succeeded`
- RHOSO 18.0.18 already deployed — satisfies 18.0.6+ requirement
- Subscription: `AtLatestKnown`

> **Namespace note:** Operator deployed in `openstack` namespace, not `openstack-operators`.
> The target namespace varies depending on the original installation method.

---

### A2. Apply OpenStack Initialization Resource
**Date:** 2026-06-22  
**Status:** COMPLETE

Required from RHOSO 18.0.6 onwards. Creates the top-level `OpenStack` CR that the operator
uses to manage sub-operator deployments. Was not present prior to this step.

```bash
cat > openstack-init.yaml <<'EOF'
---
apiVersion: operator.openstack.org/v1beta1
kind: OpenStack
metadata:
  name: openstack
  namespace: openstack
EOF

oc apply -f ./openstack-init.yaml
oc get openstack openstack -n openstack
```

**Expected outcome:**
- CR created successfully
- `status.releaseVersion` reflects current RHOSO version
- `status.totalOperatorCount` shows number of sub-operators (23 in this environment)
- Condition type `Ready` may initially show `False` with reason `Requested` — this is normal
  while the operator initialises

**Actual result:**
```
openstack.operator.openstack.org/openstack created
releaseVersion: 18.0.18-20260422.194755
totalOperatorCount: 23
Condition: OpenStackOperator in progress (Requested) — expected
```

**Known issue discovered:** The OpenStack init CR immediately began trying to create
`cert-manager.io/v1 Issuer` resources for Barbican. cert-manager is not installed on this
cluster, causing the CR to error. This is a **pre-existing gap** unrelated to the OCP upgrade.
Resolution is in Phase C (post-upgrade tasks).

---

### Phase A Outcome

| Check | Expected | Actual |
|---|---|---|
| Operator version ≥ 18.0.6 | `Succeeded`, version ≥ 1.0.8 | PASS — 18.0.18 / v1.18.0 |
| Operator pod running | 1/1 Running | PASS |
| OpenStack init CR | Created, initialising | PASS — with cert-manager caveat |
| All 33 COs healthy | Available=True, no Degraded | PASS |

**Phase A complete. Proceed to Phase B.**

---

## Phase B — OCP Upgrade 4.16 → 4.18 (EUS-to-EUS)

> OCP 4.16 and 4.18 are both EUS (Extended Update Support) releases, enabling the
> controlled traversal through 4.17 with worker nodes pinned via MCP pause.

### B1. Confirm All Cluster Operators Healthy
**Date:** 2026-06-22  
**Status:** COMPLETE

```bash
oc get clusteroperators
# Must show ALL operators: Available=True  Progressing=False  Degraded=False
# Any Degraded=True is a hard blocker — resolve before continuing
```

**Expected outcome:** 33/33 operators green. If any operator is degraded, investigate and
resolve before proceeding. A degraded cluster entering an upgrade can result in an unrecoverable
state.

**Actual result:** 33/33 — all green.

---

### B2. Switch Channel to eus-4.18
**Date:** 2026-06-22  
**Status:** COMPLETE

```bash
oc patch clusterversion version \
  --type merge \
  -p '{"spec":{"channel":"eus-4.18"}}'

# Confirm
oc get clusterversion -o jsonpath='{.items[0].spec.channel}{"\n"}'
```

**Expected outcome:** Channel field updates immediately to `eus-4.18`. The CVO begins
consulting the Cincinnati update graph for the new channel. Available upgrade targets will
change within a few seconds.

**Actual result:** Channel confirmed as `eus-4.18`.

---

### B3. Check Required Admin Acknowledgments
**Date:** 2026-06-22  
**Status:** COMPLETE — none required

```bash
oc adm upgrade
oc -n openshift-config-managed get cm admin-gates -o yaml
```

**Expected outcome:** After switching to `eus-4.18`, the CVO may populate `admin-gates` with
keys requiring administrator acknowledgment before the upgrade graph opens. Common keys for a
4.16→4.18 skip relate to removed Kubernetes APIs. If keys are present, they must be added to
`admin-acks` in `openshift-config` before the upgrade will proceed.

If acks are required:
```bash
oc -n openshift-config patch cm admin-acks --type merge -p '{
  "data": {
    "<key-from-admin-gates>": "true"
  }
}'
```

**Actual result:** `admin-gates` had no data entries. No acknowledgments required.

**Discovery:** After channel switch, `oc adm upgrade` showed only 4.16.x and 4.17.x as
recommended updates — **4.18 was not yet visible**. See B6a for explanation.

---

### B4. Apply Admin Acknowledgments
**Date:** 2026-06-22  
**Status:** NOT REQUIRED — admin-gates empty at all stages

No admin acknowledgments were required at any point during this upgrade. This step is
documented for completeness and should be re-checked in future upgrades.

---

### B5. Pause Worker MachineConfigPool
**Date:** 2026-06-22  
**Status:** COMPLETE

```bash
oc patch mcp worker --type merge -p '{"spec":{"paused":true}}'
oc get mcp
```

**Expected outcome:** Worker MCP shows `UPDATED=True` with the paused flag set. Worker nodes
will not receive any MachineConfig updates until the MCP is resumed in B8. This ensures
worker nodes skip 4.17 machine configs entirely and only apply 4.18 configs after the full
upgrade completes.

**Actual result:** Worker MCP paused. This cluster has 0 worker MCP members (all nodes are
masters) so the pause is procedural — it still prevents any future worker nodes from
receiving 4.17 configs if added during the upgrade window.

---

### B6a. Upgrade to 4.16.62 (Latest 4.16 Z-stream)
**Date:** 2026-06-22  
**Status:** COMPLETE

After switching to `eus-4.18`, the upgrade graph did not show a direct path to 4.18 from
4.16.55. The EUS direct-skip path to 4.18 only opens from the **latest 4.16 z-stream**.

```bash
oc adm upgrade --to=4.16.62
watch oc get clusterversion
watch oc get clusteroperators
```

**Expected outcome:**
- `clusterversion` progresses through manifests (903 total for this hop)
- Control plane operators roll out one at a time — etcd and kube-apiserver update first
- Operators briefly show `Progressing=True` but must never show `Degraded=True`
- Master nodes reboot sequentially as MachineConfigs update
- Completes in 30–45 minutes
- Final state: `VERSION=4.16.62  AVAILABLE=True  PROGRESSING=False`

**Actual result:** Completed successfully. All 33 COs remained healthy throughout.

---

### B6b. Upgrade to 4.17.54 (Required EUS Intermediate Hop)
**Date:** 2026-06-22  
**Status:** COMPLETE

After reaching 4.16.62, `oc adm upgrade` showed 4.17.54 as the only recommended next step —
**not 4.18**. This is correct and expected EUS behaviour. See the note below.

```bash
oc adm upgrade --to=4.17.54
watch oc get clusterversion
watch oc get clusteroperators
```

**Expected outcome:**
- Same rollout pattern as B6a — 903 manifests, etcd/kube-apiserver first
- Master nodes reboot sequentially
- Completes in 60–90 minutes
- Final state: `VERSION=4.17.54  AVAILABLE=True  PROGRESSING=False`
- After completion, `oc adm upgrade` will show 4.18.x as available

**OpenStack operator during 4.17 (unsupported but transient):**
- OLM does NOT uninstall operators during an OCP upgrade
- The catalog source image (`redhat-operator-index:v4.16`) does not change — no 4.17
  incompatible version is pushed to the operator
- CSV remained `Succeeded` and pod remained `1/1 Running` throughout
- Subscription stayed `AtLatestKnown` — no unwanted version changes
- The only error was the pre-existing cert-manager issue, unrelated to 4.17

**Actual result:** Completed successfully. OpenStack operator survived the 4.17 hop intact.

---

> ### Note: How EUS-to-EUS Upgrade Actually Works
>
> The EUS "skip" does NOT mean the CVO avoids 4.17. It means:
>
> | Layer | What happens |
> |---|---|
> | CVO / control plane operators | Must traverse 4.16 → 4.17 → 4.18 — unavoidable |
> | Worker node MachineConfigs | Skip 4.17 entirely (MCPs are paused) |
> | Worker node reboots | Only once — for 4.18 configs |
> | RHOSO operator | Stays running via OLM throughout all hops |
>
> In a compact cluster (all nodes are masters), master nodes reboot at each hop because the
> master MCP cannot be paused. This means more reboots than a standard worker/master split
> cluster, but the final state is identical — fully on 4.18.

---

### B6c. Upgrade to 4.18.43 (Final EUS Hop)
**Date:** 2026-06-22  
**Status:** IN PROGRESS

After reaching 4.17.54, three 4.18 versions became available: 4.18.43, 4.18.42, 4.18.41.
No admin-acks were required. Targeting the latest.

```bash
# Confirm 4.18 is available
oc adm upgrade

# Check admin-gates one final time
oc -n openshift-config-managed get cm admin-gates -o yaml

# Fire the final hop
oc adm upgrade --to=4.18.43

# Monitor
watch oc get clusterversion
watch oc get clusteroperators
```

**Expected outcome:**
- 908 manifests for this hop
- Same rollout pattern — etcd and kube-apiserver first, then all other operators
- Master nodes reboot sequentially for 4.18 MachineConfigs
- Completes in 60–90 minutes
- Final state: `VERSION=4.18.43  AVAILABLE=True  PROGRESSING=False`
- All cluster operators on version 4.18.43

**Actual result:** Started 2026-06-22. IN PROGRESS.

---

### B7. Confirm 4.18.43 Complete and All Operators Healthy
**Date:** 2026-06-22  
**Status:** COMPLETE

```bash
oc get clusterversion
oc get clusteroperators
```

**Actual result:** All 34 cluster operators on `4.18.43` — Available=True, Progressing=False,
Degraded=False. `clusterversion` shows `4.18.43  Available=True  Progressing=False`.

---

### B8. Resume Worker MachineConfigPool
**Date:** 2026-06-22  
**Status:** COMPLETE

```bash
oc patch mcp worker --type merge -p '{"spec":{"paused":false}}'
oc get mcp
```

**Actual result:** Worker MCP unpaused and immediately `UPDATED=True` (0 members — instant).
Master MCP: 3/3 updated, no degraded.

---

### B9. Final Verification
**Date:** 2026-06-22  
**Status:** COMPLETE

```bash
oc get clusterversion
oc get clusteroperators
oc get nodes
oc get csv -n openstack
oc get pods -n openstack
oc get openstack openstack -n openstack
oc get subscription openstack-operator -n openstack \
  -o jsonpath='{.status.state}{"\n"}{.status.installedCSV}{"\n"}'
```

**Actual result:**

| Check | Expected | Actual |
|---|---|---|
| OCP version | 4.18.43 | **PASS — 4.18.43** |
| All COs healthy | 34/34 green on 4.18.43 | **PASS — 34/34** |
| All nodes Ready | 3/3 Ready on v1.31.14 | **PASS — master-1/2/3 Ready** |
| OpenStack CSV | Succeeded | **PASS — v1.18.0 Succeeded** |
| OpenStack pod | Running | **PASS — 1/1 Running** |
| Subscription state | AtLatestKnown | **PASS** |
| RHOSO releaseVersion | 18.0.18-20260422.194755 | **PASS** |
| Worker MCP | Resumed and Updated | **PASS** |

---

### Phase B Outcome — COMPLETE

**OCP upgraded from 4.16.55 to 4.18.43 on 2026-06-22.**  
**RHOSO 18.0.18 survived all three upgrade hops intact.**

---

## Phase C — Post-Upgrade Tasks

> These tasks are required before RHOSO services can be deployed. They are not part of the
> OCP upgrade itself but are blockers for a running OpenStackControlPlane.

### C1. Install cert-manager Operator

The OpenStack init CR requires cert-manager for TLS certificate management across all
OpenStack services. Without it, the OpenStack CR remains in an error state.

```bash
# Create the cert-manager namespace and operator group
cat > cert-manager-og.yaml <<'EOF'
---
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator
  namespace: cert-manager-operator
spec:
  targetNamespaces:
    - cert-manager-operator
EOF

oc apply -f cert-manager-og.yaml

# Subscribe to cert-manager
cat > cert-manager-sub.yaml <<'EOF'
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: stable-v1
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

oc apply -f cert-manager-sub.yaml

# Monitor installation
watch oc get csv -n cert-manager-operator
watch oc get pods -n cert-manager
```

**Expected outcome:**
- CSV reaches `Succeeded` in `cert-manager-operator` namespace
- Pods running in `cert-manager` namespace: `cert-manager`, `cert-manager-cainjector`,
  `cert-manager-webhook`
- cert-manager CRDs available: `Certificate`, `Issuer`, `ClusterIssuer`
- OpenStack init CR automatically re-reconciles and clears the cert-manager error

Verify:
```bash
oc get openstack openstack -n openstack -o jsonpath='{.status.conditions[0].message}{"\n"}'
# Should no longer show the cert-manager Issuer error
```

---

### C2. Install a StorageClass

MariaDB (Galera), RabbitMQ, Cinder, and other OpenStack services require PersistentVolumeClaims.
No StorageClass exists on this cluster. Choose one:

**Option A — NFS Provisioner (test environments):**
```bash
# Deploy NFS subdir external provisioner via Helm or manifest
# Requires an NFS server accessible from all nodes
helm repo add nfs-subdir-external-provisioner \
  https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/

helm install nfs-subdir-external-provisioner \
  nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
  --set nfs.server=<nfs-server-ip> \
  --set nfs.path=/exported/path \
  --set storageClass.defaultClass=true
```

**Option B — OpenShift Data Foundation / Ceph (production):**
```bash
# Install ODF operator from OperatorHub, then create StorageSystem
oc get csv -n openshift-storage | grep ocs
```

**Option C — local-storage (single-node test):**
```bash
# Install local-storage operator and create LocalVolume CRs
oc get csv -n openshift-local-storage | grep local
```

Verify a StorageClass is available:
```bash
oc get storageclass
```

---

### C3. Deploy a Minimal OpenStackControlPlane

Once cert-manager and a StorageClass are in place, a minimal OpenStackControlPlane can be
deployed to verify the operator is fully functional end-to-end.

Minimum viable stack: Keystone + MariaDB + RabbitMQ + Memcached

```bash
cat > openstack-controlplane-minimal.yaml <<'EOF'
---
apiVersion: core.openstack.org/v1beta1
kind: OpenStackControlPlane
metadata:
  name: openstack-galera-network-isolation
  namespace: openstack
spec:
  secret: osp-secret
  storageClass: <your-storage-class>
  keystone:
    enabled: true
    template:
      databaseInstance: openstack
      secret: osp-secret
  mariadb:
    enabled: false
  galera:
    enabled: true
    templates:
      openstack:
        storageRequest: 500M
  memcached:
    enabled: true
    templates:
      memcached:
        replicas: 1
  rabbitmq:
    enabled: true
    templates:
      rabbitmq:
        replicas: 1
EOF

oc apply -f openstack-controlplane-minimal.yaml
watch oc get openstackcontrolplane -n openstack
```

**Expected outcome:**
- OpenStackControlPlane CR created
- Galera, Memcached, RabbitMQ pods start and reach Ready
- Keystone pod starts and API becomes reachable
- `openstackcontrolplane` condition `Ready=True`

---

## Quick Reference: Gate Checklist

```
PHASE 0 — PRE-UPGRADE BACKUPS
[ ] 0A. OADP operator installed and CSV Succeeded
[ ] 0B. BackupStorageLocation Available
[ ] 0C. openstack-pre-upgrade backup: Phase=Completed, Errors=0
[ ] 0D. openstack-daily schedule created and test backup verified
[ ] 0E. etcd snapshot taken and copied off-node

PHASE A — RHOSO READINESS
[x] A1. Operator version confirmed 18.0.6+ (18.0.18 / v1.18.0) — 2026-06-22
[x] A2. OpenStack init CR applied — 2026-06-22

PHASE B — OCP UPGRADE
[x] B1. All 33 COs healthy
[x] B2. Channel switched to eus-4.18
[x] B3. Admin-gates checked — no acks required
[x] B4. Admin-acks — none needed
[x] B5. Worker MCP paused
[x] B6a. Upgrade to 4.16.62 — COMPLETE (2026-06-22)
[x] B6b. Upgrade to 4.17.54 — COMPLETE (2026-06-22)
[x] B6c. Upgrade to 4.18.43 — COMPLETE (2026-06-22)
[x] B7. All 34 COs healthy on 4.18.43 — COMPLETE (2026-06-22)
[x] B8. Worker MCP resumed — COMPLETE (2026-06-22)
[x] B9. All nodes and operators verified — COMPLETE (2026-06-22)

PHASE C — POST-UPGRADE TASKS
[ ] C1. cert-manager operator installed and healthy
[ ] C2. StorageClass available
[ ] C3. Minimal OpenStackControlPlane deployed and verified
```

---

## Phase D — Recovery Procedures

> **Primary recovery tool for all OpenStack / RHOSO issues: OADP.**
>
> OADP restores the complete `openstack` namespace — CRs, secrets, configmaps, and PVC
> data — with a single command. It handles every scenario from a single failed service
> through to a completely lost namespace, on either the original or upgraded OCP version.
>
> The etcd backup is only needed if OCP itself is unrecoverable — a separate, rarer problem.

---

### D0. Critical Principle — Compute Nodes are Independent of the Control Plane

> **This is the most important thing to understand before any recovery action.**

OpenStack has a fundamental architectural separation between the **control plane** (running
as pods in the `openstack` namespace on OCP) and the **dataplane** (compute nodes running
Nova instances via libvirt/KVM).

```
┌─────────────────────────────────────────────────────────┐
│  OCP Cluster                                            │
│  ┌─────────────────────────────────────────────────┐   │
│  │  openstack namespace (RHOSO Control Plane)       │   │
│  │  Keystone · Nova API · Neutron · Cinder · etc.   │   │  ← Can fail, be
│  │  Galera · RabbitMQ · Memcached                   │   │    restored, or
│  └─────────────────────────────────────────────────┘   │    be upgraded
└─────────────────────────────────────────────────────────┘
              │  management only — no data path
              ▼
┌─────────────────────────────────────────────────────────┐
│  Dataplane Compute Nodes (baremetal, outside OCP)       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │  libvirt/KVM │  │  libvirt/KVM │  │  libvirt/KVM │  │  ← ALWAYS RUNNING
│  │  Instance A  │  │  Instance B  │  │  Instance C  │  │    regardless of
│  │  Instance D  │  │  Instance E  │  │  Instance F  │  │    control plane
│  └──────────────┘  └──────────────┘  └──────────────┘  │    state
│  OVN southbound (local) · iSCSI/RBD direct to storage   │
└─────────────────────────────────────────────────────────┘
```

**What KEEPS RUNNING — unaffected by any control plane failure or OCP upgrade:**

| Component | Why it is unaffected |
|---|---|
| **Nova instances (VMs)** | Managed directly by `libvirt`/`KVM` on compute nodes. The hypervisor has no runtime dependency on the OpenStack API — instances run whether or not the control plane exists |
| **Instance network connectivity** | OVN southbound database is distributed to and cached on each compute node. Existing packet flows continue processing locally even if the OVN northbound (control plane) is gone |
| **Attached Cinder volumes** | Block storage connections (iSCSI, NVMe-oF, Ceph RBD) are established directly between the compute node and the storage backend. They persist across control plane restarts |
| **Swift object data** | Data lives on storage node disks. Only the Swift proxy API (a control plane component) becomes unavailable — the data itself is untouched |

**What STOPS WORKING — management operations only:**

| Component | Impact on running workloads |
|---|---|
| Keystone API | Auth tokens for NEW operations fail. Tokens already issued continue working until they expire. Instances are not affected |
| Nova API | Cannot create/delete/migrate/resize instances. **Existing instances keep running** |
| Neutron API | Cannot create/modify networks, ports, security groups. **Existing network flows continue** |
| Cinder API | Cannot create/delete/attach NEW volumes. **Existing volume attachments remain active** |
| Horizon | Dashboard unavailable. No workload impact |
| Heat / Octavia / Designate | Service APIs unavailable. No impact on running stacks, load balancers, or DNS records already provisioned |

**The critical point for upgrade operations:**
> If the RHOSO control plane fails at any point during the OCP upgrade — whether during the
> 4.16.62 hop, the 4.17.54 hop, or the final 4.18.43 hop — **every Nova instance continues
> running on its compute node without interruption.** The failure is a management outage
> only. OADP recovery restores the management plane without touching any instance.

---

### D0a. Recovery Paths if the Control Plane Fails During the OCP Upgrade

If the `openstack` namespace becomes non-functional at any point during the upgrade,
there are **two valid recovery paths** depending on the state of OCP at the time:

---

**RECOVERY PATH 1 — Restore the namespace on the CURRENT (possibly mid-upgrade) OCP version**

Use this when OCP itself is healthy but the OpenStack namespace is broken.
This works regardless of whether OCP is at 4.16, 4.17, or 4.18 at the time of failure.

```
OCP state:   4.16.x OR 4.17.54 OR 4.18.43  (any — OCP is healthy)
Namespace:   broken / corrupted / missing
Action:      OADP restore → namespace recovers on whichever OCP version is running
Then:        Continue or resume the OCP upgrade once namespace is healthy
```

Steps: Follow **D2 (Full OADP Restore)** below.

---

**RECOVERY PATH 2 — Roll OCP back to 4.16 via etcd restore, then restore the namespace**

Use this only when OCP itself is also unrecoverable (API server down, etcd quorum lost).

```
OCP state:   unrecoverable (API unreachable, etcd quorum lost)
Namespace:   irrelevant — OCP is gone
Action:      etcd restore → OCP returns to 4.16.55
             Then: OADP restore → namespace restored to pre-upgrade state on 4.16
Then:        Investigate root cause before attempting the upgrade again
```

Steps: Follow **D5 (Catastrophic Recovery)** then **D2**.

---

**In both paths:**
- Nova instances on compute nodes were running throughout and require no recovery
- OADP restores the namespace to the last known-good backup point
- The namespace is equally valid on 4.16 or 4.18 — RHOSO 18.0.18 supports both

---

### D1. Before Any Recovery — Assess and Choose Your Restore Point

Always assess before restoring. A restore returns the namespace to a specific point in
time — make sure you choose the right one.

```bash
# Step 1: Confirm the OCP API is reachable
oc get nodes
oc get clusteroperators | grep -v "True.*False.*False"

# Step 2: Assess the openstack namespace
oc get all -n openstack
oc get pods -n openstack
oc get csv -n openstack
oc get openstack openstack -n openstack \
  -o jsonpath='{.status.conditions[*].message}' | tr ' ' '\n'
oc get openstackcontrolplane -n openstack 2>/dev/null

# Step 3: List all available OADP backups, newest first
oc get backup -n openshift-adp \
  --sort-by='.metadata.creationTimestamp' \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,ERRORS:.status.errors,CREATED:.metadata.creationTimestamp,EXPIRES:.status.expiration'
```

**Choosing the right backup:**

| Situation | Backup to use |
|---|---|
| Issue appeared after the upgrade | Most recent daily backup from BEFORE the upgrade (`openstack-pre-upgrade`) |
| Issue appeared post-upgrade after several days | Most recent successful daily backup before the problem |
| Pre-upgrade backup is the only option | `openstack-pre-upgrade` |

**Never restore from a backup that itself has `Errors > 0`.**

---

### D2. OADP Restore — Complete OpenStack Namespace Recovery

This is the procedure for all scenarios where the namespace state needs to be recovered:
corrupted CRs, lost secrets, failed services, or a completely missing namespace.

**Step 1 — If the namespace still exists, remove it cleanly first:**

```bash
# Check if namespace exists and what state it's in
oc get ns openstack

# If it exists and is in a bad state, delete it
# WARNING: This is destructive — only do this after confirming your backup is good
oc delete ns openstack

# Wait for deletion to complete (finalizers may slow this down)
oc get ns openstack -w
# Wait until 'not found' — may take 2-5 minutes while operator finalizers run
```

**Step 2 — Verify the OADP backup you will use is healthy:**

```bash
BACKUP_NAME="openstack-pre-upgrade"    # change to the backup you selected in D1

oc describe backup ${BACKUP_NAME} -n openshift-adp | \
  grep -E "Phase:|Errors:|Items Backed Up:|Warnings:"

# Must show:
#   Phase:           Completed
#   Errors:          0
#   Items Backed Up: <number greater than 0>
```

**Step 3 — Create and apply the Restore CR:**

```bash
BACKUP_NAME="openstack-pre-upgrade"    # change as needed
RESTORE_NAME="openstack-recovery-$(date +%Y%m%d-%H%M)"

cat > /home/ansible/OCP-TEST/openstack-restore.yaml <<EOF
---
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${RESTORE_NAME}
  namespace: openshift-adp
spec:
  backupName: ${BACKUP_NAME}
  includedNamespaces:
    - openstack
  restorePVs: true                   # restores PVC data (Galera DB, etc.)
  restoreStatus:
    includedResources:
      - openstackcontrolplanes
      - openstacks
EOF

oc apply -f /home/ansible/OCP-TEST/openstack-restore.yaml
```

**Step 4 — Monitor the restore:**

```bash
# Watch overall restore status
oc get restore ${RESTORE_NAME} -n openshift-adp -w

# Expected progression:
# NAME                           STATUS      WARNINGS   ERRORS
# openstack-recovery-20260622    InProgress  0          0
# openstack-recovery-20260622    Completed   0          0

# If it stays on InProgress for >15 min, check velero logs:
oc logs -n openshift-adp deployment/velero --tail=50 | grep -i "restore\|error"
```

**Step 5 — Verify the operator reconciles successfully:**

```bash
# Give the operator 2-3 minutes to start after CRs are restored
watch oc get pods -n openstack

# Check the operator CSV is still Succeeded
oc get csv -n openstack

# Check the top-level OpenStack CR status
oc get openstack openstack -n openstack \
  -o jsonpath='{.status.conditions[0].message}{"\n"}'

# Check the OpenStackControlPlane if it was deployed
oc get openstackcontrolplane -n openstack \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}{"\n"}'

# All services should come back up within 15-30 minutes
watch oc get pods -n openstack
```

**Step 6 — Verify running instances are reconnected:**

```bash
# From a working OpenStack client, verify Keystone is responding
openstack token issue

# Verify Nova sees existing instances (they never stopped)
openstack server list --all-projects

# Verify Neutron has network state
openstack network list
```

**Expected outcome:**
- All pods return to Running state within 15–30 minutes
- `openstackcontrolplane` condition shows `Ready=True`
- Keystone token issue succeeds
- Nova server list shows all instances (still in their pre-outage state)
- No instance was rebooted or lost data

---

### D3. OADP Restore — Partial Recovery (Single Service)

If only one service is broken and you want to avoid a full namespace restore, you can
restore specific resource types only.

**Example: Keystone CR is corrupted:**

```bash
BACKUP_NAME="openstack-pre-upgrade"

cat > /home/ansible/OCP-TEST/openstack-restore-keystone.yaml <<EOF
---
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: openstack-keystone-recovery-$(date +%Y%m%d)
  namespace: openshift-adp
spec:
  backupName: ${BACKUP_NAME}
  includedNamespaces:
    - openstack
  includedResources:
    - keystoneapis
    - keystoneservices
    - keystoneendpoints
  restorePVs: false    # keystone is stateless — no PVCs needed
EOF

oc apply -f /home/ansible/OCP-TEST/openstack-restore-keystone.yaml
```

**Common single-service restores:**

| Broken service | Resources to restore |
|---|---|
| Keystone | `keystoneapis`, `keystoneservices`, `keystoneendpoints` |
| Galera / MariaDB | `galeras`, `mariadbaccounts`, `mariadbdatabases` + `restorePVs: true` |
| RabbitMQ | `rabbitmqs`, `rabbitmqpolicies`, `rabbitmqusers`, `rabbitmqvhosts` |
| Nova | `nova`, `novaapis`, `novacells`, `novaconductors`, `novaschedulers` |
| Neutron | `neutronapis` |
| All secrets | `secrets` (use when credentials are corrupted) |

---

### D4. Self-Healing — When OADP Restore is Not Needed

Not every failure requires a restore. OLM and the OpenStack operator self-heal many
failure modes automatically. Always try self-healing first — it's faster and has no
risk of data regression.

**Operator pod crashed:**
```bash
# OLM will restart it automatically — just wait and watch
watch oc get pods -n openstack
watch oc get csv -n openstack

# If it doesn't recover within 5 minutes, force a restart:
oc delete pod -n openstack \
  $(oc get pods -n openstack -o name | grep controller-init)
```

**Individual service pod stuck in CrashLoopBackOff:**
```bash
# Get the logs to understand why
SERVICE=keystone   # change to the failing service name
oc logs -n openstack -l service=${SERVICE} --previous --tail=50

# Check the service's own CR for error conditions
oc get keystoneapi -n openstack -o yaml | grep -A5 "conditions:"

# Delete the pod — the operator recreates it
oc delete pod -n openstack -l service=${SERVICE}

# If the CR itself is in an error state, force reconcile:
oc annotate keystoneapi keystone -n openstack \
  operator.openstack.org/reconcile="$(date +%s)" --overwrite
```

**Service in error state but namespace otherwise healthy:**
```bash
# Check what the operator is reporting
oc get openstack openstack -n openstack \
  -o jsonpath='{.status.conditions[*].message}' | tr ',' '\n'

# Delete and let the operator re-create the sub-CR
# Example for a stuck Galera:
oc delete galera openstack -n openstack
# Operator will recreate it within seconds
watch oc get galera -n openstack
```

---

### D5. Catastrophic Recovery — OCP Cluster Unrecoverable

This path is only needed if the OCP cluster itself has failed (etcd quorum lost, all
master nodes down). Running Nova instances survive this scenario — libvirt manages them
independently on compute nodes.

**Step 1 — Restore OCP from etcd backup:**

```bash
# Copy the etcd backup to the master node being recovered
scp <backup-server>:/backups/ocp-pre-upgrade/snapshot_*.db \
  core@master-1:/home/core/assets/backup/
scp -r <backup-server>:/backups/ocp-pre-upgrade/static_kuberesources_* \
  core@master-1:/home/core/assets/backup/

# Run the restore (on ONE master node only — do NOT run on all masters simultaneously)
ssh core@master-1
sudo /usr/local/bin/cluster-restore.sh /home/core/assets/backup

# Wait for the API to come back (5-10 min), then verify
oc get nodes
oc get clusteroperators | grep -v "True.*False.*False"
```

**Step 2 — Once OCP is recovered, use OADP to restore OpenStack:**

```bash
# Verify OADP itself recovered (it's an OCP operator — comes back with etcd restore)
oc get pods -n openshift-adp
oc get backupstoragelocation -n openshift-adp

# Then follow the full D2 procedure to restore the openstack namespace
```

> Full etcd restore guide:
> https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/backup_and_restore/control-plane-backup-and-restore

---

### D6. Upgrade Stalled — CVO Not Progressing

Use this if `oc get clusterversion` shows `Progressing=True` for more than 2 hours
without the manifest count advancing.

```bash
# Step 1: Identify what's blocking
oc get clusteroperators | grep -v "True.*False.*False"

# Step 2: Check CVO logs for the specific error
oc logs -n openshift-cluster-version \
  $(oc get pods -n openshift-cluster-version -o name | head -1) \
  --tail=50

# Step 3a: If a specific operator pod is stuck, restart it
# Replace <namespace> and <pod-name> with the actual values from step 1
oc delete pod -n openshift-<namespace> <pod-name>

# Step 3b: If the situation is unrecoverable, cancel the upgrade and stabilise
oc adm upgrade --clear
# The cluster stays at the version it last completed (e.g., 4.17.54)
# Investigate the failing operator before retrying the upgrade

# Step 4: Once the blocking issue is fixed, resume the upgrade
oc adm upgrade --to=<target-version>
```

---

### Recovery Decision Tree

```
Problem detected →

  Can you reach the OCP API?  (oc get nodes)
  │
  ├── NO ──→ D5: Restore OCP from etcd, then restore OpenStack with OADP (D2)
  │
  └── YES
        │
        Is the upgrade currently in progress and stalled?
        ├── YES ──→ D6: Upgrade recovery (cancel / restart / resume)
        │
        └── NO
              │
              Is the openstack namespace intact with CRs present?
              │
              ├── NO (namespace gone or all CRs missing)
              │     └──→ D2: Full OADP restore
              │
              └── YES (namespace exists)
                    │
                    Is it just pods crashing / one service failing?
                    ├── YES ──→ D4: Try self-healing first (pod delete / CR reconcile)
                    │           If self-healing fails after 10 min → D3: Partial OADP restore
                    │
                    └── NO (multiple services broken, secrets corrupted, CRs in bad state)
                          └──→ D2: Full OADP restore
```

---

### Post-Recovery Verification Checklist

Run after any recovery to confirm full service restoration:

```bash
# 1. OCP health
oc get clusteroperators | grep -v "True.*False.*False"
oc get nodes

# 2. RHOSO operator health
oc get csv -n openstack
oc get pods -n openstack
oc get openstack openstack -n openstack \
  -o jsonpath='{.status.releaseVersion}{"\n"}'

# 3. Control plane services
oc get openstackcontrolplane -n openstack
oc get pods -n openstack | grep -v Running | grep -v Completed

# 4. OpenStack API access (requires an openstack client configured)
openstack token issue
openstack endpoint list
openstack server list --all-projects
openstack network list
openstack volume list --all-projects

# 5. Confirm no instances were lost or rebooted
openstack server list --all-projects \
  -f value -c Name -c Status -c "Power State"
# All instances should show ACTIVE / Running — same as before the failure
```

---

## Known Issues and Lessons Learned

| Issue | Root Cause | Resolution |
|---|---|---|
| 4.18 not visible from 4.16.55 in eus-4.18 channel | EUS graph requires latest 4.16 z-stream first | Upgrade to 4.16.62, then 4.18 path opens |
| EUS shows 4.17.54 as next hop, not 4.18 directly | CVO must traverse 4.17 internally — this is correct | Proceed through 4.17.54; keep MCPs paused |
| OpenStack init CR errors on cert-manager | cert-manager not installed on this cluster | Phase C1 — install cert-manager post-upgrade |
| No StorageClass present | Cluster built without storage provisioner | Phase C2 — add StorageClass post-upgrade |
| ContainerStatusUnknown pods mid-upgrade | Normal — pods killed during node reboots, not failures | Ignore during upgrade; clean up post-upgrade |

---

## Useful Commands

```bash
# Re-login (token expires every ~24h)
oc login --token=<new-token> --server=https://api.ocp-upgrade.cluster.test:6443

# Upgrade status
oc get clusterversion
oc adm upgrade

# Operator health
oc get clusteroperators
oc get clusteroperators | grep -v "True.*False.*False"   # show only non-healthy

# RHOSO operator
oc get csv -n openstack
oc get pods -n openstack
oc get openstack openstack -n openstack
oc get subscription openstack-operator -n openstack \
  -o jsonpath='{.status.state}{"\n"}{.status.installedCSV}{"\n"}'

# MachineConfigPools and nodes
oc get mcp
oc get nodes

# etcd backup (run on each master)
oc debug node/master-1 -- chroot /host /usr/local/bin/cluster-backup.sh /home/core/assets/backup
```

---

## Reference

- RHOSO Version Map: https://access.redhat.com/articles/7125383
- OCP EUS Upgrade Guide: https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/updating_clusters/updating-cluster-between-minor
- OCP Backup and Restore: https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html/backup_and_restore/control-plane-backup-and-restore
- RHOSO Lifecycle Policy: https://access.redhat.com/support/policy/updates/openstack/platform#rhoso
