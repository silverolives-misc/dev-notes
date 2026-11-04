# OLVM OS Patching Workflow

## Objective

Jira-gated OS patching of Oracle Linux VMs on Oracle Linux Virtualization Manager (OLVM), run from Ansible Automation Platform (Azure Marketplace managed app, on AKS). Device42 supplies inventory and patch groups. A disk snapshot is taken of every VM before it is patched and kept for an agreed period. Snapshots are deleted only after approval.

Each step of the agreed process maps to one AAP workflow node, so the AAP workflow visualiser shows exactly where a run stopped. Every route through the workflow, including a refusal at the change gate, ends at the report node, so the Jira ticket is always updated.

---

## Architecture

```
OS Patching workflow (survey: change_ticket, patch_group, patch_limit, patch_serial, patch_reboot)

  01 Change gate ─ok─► Device42 sync ─ok─► 02 Pre-check ─ok─► 03 Snapshot ─ok─► 04 Patch ─always─► 05 Report
        └──fail────────────┴──fail─────────────┴──fail───────────┴──fail──────────────────────────►┘

OLVM Snapshot Cleanup workflow (daily schedule)

  06 Cleanup (dry run) ─ok─► Approval node ─approved─► 06 Cleanup (delete)
```

The jobs pass data to each other with `set_stats` artifacts. AAP gives each later node these artifacts as extra-vars.

| Artifact | Set by | Contents |
|---|---|---|
| `patch_change` | 01 | ticket, summary, status, patch_group, ticket_hosts, window |
| `patch_scope` | 02 | `[{host, in_scope, reason}]` |
| `patch_precheck` | 02 | per host: status, reasons, warnings, os, kernel, updates |
| `patch_targets` | 02, narrowed by 03 | hosts that are ready **and** have a confirmed snapshot |
| `patch_snapshots` | 03 | per host: vm, vm_id, snapshot_id, description, status |
| `patch_results` | 04 (published per host inside the role) | per host: status, stage, error, kernels, rebooted, packages |
| `patch_report` | 05 | overall outcome, counts, per-host rows |

### Step mapping

| # | Agreed step | Where |
|---|---|---|
| 1 | Confirm approved change; halt if not | `01_change_gate.yml`: issue type, status, change window |
| 2 | Select patch group from Device42 | Device42 inventory source sync node + `patch_group_<name>` group |
| 5 | Target host in scope | `02_precheck.yml` play 1: group ∩ ticket hosts − `patch_exclude` tag, run **first** |
| 4 | Host connectivity | `patch_precheck`: `wait_for_connection` (before facts) |
| 3 | Gather facts | `patch_precheck`: `setup` |
| 8 | Check available updates | `patch_precheck`: `dnf check-update`, run **before** the snapshot |
| 6 | Pre-patch snapshot | `03_snapshot.yml` → `olvm_snapshot/create.yml` |
| 7 | Confirm snapshot | `ovirt_snapshot_info` until `snapshot_status == ok` |
| 9 | Apply approved updates | `os_patch/apply.yml` |
| 10–11 | Reboot, wait for host | `os_patch/reboot.yml` (`ansible.builtin.reboot`) |
| 12 | Validate SSH | `os_patch/validate.yml`: port check from the execution node, fresh session, kernel check |
| 13 | Optional service / process checks | `patch_required_services`, `patch_required_processes`, `patch_validation_commands` |
| 14 | Record outcome | `os_patch` → `set_stats patch_results`; `05_report.yml` per-host outcome |
| 15 | Generate report | `templates/patch_report.html.j2` |
| 16 | Update Jira | comment (wiki markup) + HTML attachment + optional transition |
| 18 | Retain snapshot | `snapshot_retention_days` (default 7) |
| 19 | Delete after retention, with approval | Cleanup workflow: dry run → approval node → delete |

The proposed list has no step 17.

### Ordering changes from the proposed list

- **Scope (5) runs before connectivity (4) and facts (3).** Scope comes from Jira and Device42 and does not need to touch the host.
- **Connectivity (4) runs before facts (3).** `setup` needs a working connection.
- **Available updates (8) runs before the snapshot (6).** Hosts with nothing to install are not snapshotted.

---

## Behaviour

### Per-host outcomes (report)

| Outcome | Meaning |
|---|---|
| `excluded` | Not in scope (exclude tag, not on ticket, outside `patch_limit`, or on ticket but not in the group) |
| `precheck_failed` | Unreachable, unsupported OS, low disk, or a repo error |
| `no_updates` | Healthy, nothing to install, so no snapshot was taken |
| `snapshot_failed` | No confirmed snapshot, so the host was **not patched** |
| `patched` | Updated, rebooted and validated |
| `patch_failed` | Failed at `stage` (apply / reboot / validate); see `error` |
| `not_attempted` | Ready, but the run stopped first (`max_fail_percentage`) |

Overall outcome: `SUCCESS` (every in-scope host is patched or has no updates), `PARTIAL`, `FAILED`, or `HALTED` (the run stopped before any host was assessed).

### Pre-flight checks

The aim is that a host never fails mid-patch for a reason that could have been detected first. Every check below runs **before anything changes**. A host that fails any check is not snapshotted or patched, and the reason appears in the report.

**Inside the VM** (`02_precheck.yml` → `patch_precheck`)

| Area | Check |
|---|---|
| Access | SSH and sudo within 60 s |
| OS | Oracle Linux 8 or 9 |
| Filesystems | `/`, `/boot`, `/var`, `/tmp`: minimum free MB **and** maximum % used **and** maximum % inodes; not mounted read-only |
| Package manager | No dnf/yum/rpm process running; `dnf check` clean (no broken dependencies or duplicates); warns if `dnf-automatic` is enabled |
| Repos | `dnf check-update` succeeds |
| Major release guard | No pending update tagged for another major release (e.g. `.el9` on OL8, which means the repos are misconfigured) |
| Update size | Dry run of the exact update (`dnf update --assumeno`). Download size on the filesystem holding `/var/cache/dnf`, installed size on the one holding `/usr`, plus a new kernel on `/boot`. Each must leave the headroom free, with needs added together where they share a filesystem. Installed size is the full size of the new packages, so this deliberately overestimates |
| Tooling | `qemu-guest-agent` running (warning, or failure if required); `needs-restarting` and `grubby` present (warning) |

**On OLVM** (`03_snapshot.yml`)

| Area | Check |
|---|---|
| Storage domains | For **all** target VMs together: expected snapshot growth per storage domain (25% of each VM disk's used size) must leave at least 15% **and** 100 GiB free. If a domain fails, every target VM on it is blocked: a full storage domain pauses every VM on it |
| Disks a snapshot can't cover | VMs with direct-LUN or shareable disks are blocked, because the snapshot wouldn't be a full rollback point |
| VM state | VM is up; no existing snapshot is locked or in preview; at most `olvm_max_existing_snapshots` snapshots already exist |

Every limit is a variable and can be overridden per Device42 group.

### Failure handling

- **Pre-check and snapshot failures are recorded per host and the run continues** with the remaining hosts. To fail the whole job instead, set `precheck_fail_on_any_error` / `snapshot_fail_on_any_error` to true.
- **Patch** runs in batches of `patch_serial`. With the default `patch_max_fail_pct: 0`, any failure stops later batches. Each host's result is published from inside the role before the failure is re-raised, so the report still sees it.
- **No automatic rollback.** If a host fails, the snapshot ID is in the report and the Jira comment. A person decides whether to revert in OLVM.

---

## Prerequisites

### Network: decide this first

The managed AAP control plane runs in an Azure-managed resource group. AAP must reach three things:

- the OLVM engine API (HTTPS)
- Device42 (HTTPS)
- every target VM (SSH)

If these are on-premises, either add **execution or hop nodes inside the client network** (automation mesh), or arrange VNet peering plus ExpressRoute or VPN from the managed app's VNet. Execution nodes are usually simpler and keep SSH traffic on-site.

### Execution environment

Build it from `execution-environment.yml` and push it to the private automation hub. `ovirt-engine-sdk-python` compiles against libcurl and libxml2; the build dependencies are already listed.

### Credentials and secrets (Azure Key Vault)

Secrets live only in Azure Key Vault. AAP's built-in **Microsoft Azure Key Vault** lookup credential fetches them when each job launches. `aap/configure_controller.yml` creates the credentials below with their non-secret fields set and each secret field linked to a Key Vault secret. Rotating a secret in Key Vault needs no change in AAP.

| Credential | Type | Secret fields → Key Vault secret | Used by |
|---|---|---|---|
| Oracle Linux SSH | Machine (sudo) | `ssh_key_data` → `patching-ssh-private-key` (`become_password` optional) | 02, 04 |
| Jira | custom, `aap/credential_types.yml` | `token` → `patching-jira-api-token` | 01, 05, 06 delete |
| Device42 | custom | `password` → `patching-device42-password` | inventory source |
| OLVM | custom | `password` → `patching-olvm-password`, `ca_pem` → `patching-olvm-ca-pem` | 03, 06 |

Secret names are set in `aap/vars.yml` (`aap_credential_secrets`). Store multi-line values (the SSH key and CA PEM) as-is, for example with `az keyvault secret set --file`.

The lookup credential authenticates with an Entra ID service principal that needs **Key Vault Secrets User** on the vault (RBAC), or Get on secrets (access policy). Its client secret is the only value supplied outside Key Vault: pass it once as `AZURE_KV_CLIENT_SECRET` when running `configure_controller.yml`. The Key Vault needs network access from wherever jobs run (AAP on AKS and any execution nodes), through a private endpoint or the vault firewall rules.

OLVM account: create a dedicated user with a custom role limited to logging in, reading VMs, and creating, deleting and manipulating VM snapshots. Assign it only on the clusters or data centres in scope.

### Device42

`inventory/device42.d42.yml` assumes a custom field `patch_group` and a tag `patch_exclude`. It also builds `ansible_host` and `olvm_vm_name` from Device42 fields. **Check the variable names after the first sync and adjust them.**

### Jira

Set the custom field IDs in `group_vars/all/main.yml`. Find them with `GET /rest/api/2/field`. Then set the approved statuses and the change issue type to match the client's workflow. Use `jira_auth_type: basic` for Jira Cloud and `bearer` for Data Center.

### Target hosts

Oracle Linux 8 or 9, with these installed:

- `dnf-utils` (for `needs-restarting`)
- `grubby`
- `qemu-guest-agent`, running, so OLVM can freeze filesystems during the snapshot

---

## Inputs

### Survey (OS Patching workflow)

| Variable | Default | Description |
|---|---|---|
| `change_ticket` | (required) | Jira change key |
| `patch_group` | from ticket | Overrides the ticket's patch group field |
| `patch_limit` | none | Narrow the run to these short hostnames |
| `patch_serial` | `5` | Hosts per batch (number or `"20%"`) |
| `patch_reboot` | `always` | `always` or `if_required` |

### Key variables (`group_vars/all/main.yml` and role defaults)

| Variable | Default | Description |
|---|---|---|
| `patch_mode` | `all` | `all`, `security` or `list` (with `patch_packages`) |
| `patch_exclude` | `[]` | dnf exclude globs |
| `enforce_change_window` | `true` | Halt outside the ticket's planned window |
| `snapshot_retention_days` | `7` | Retention before cleanup can delete a snapshot |
| `olvm_snapshot_concurrency` | `5` | Snapshot requests in flight at once |
| `patch_max_fail_pct` | `0` | Failure percentage at which later batches stop |
| `patch_required_services` | `[]` | systemd units that must be active after reboot |
| `precheck_filesystems` | `/`, `/boot`, `/var`, `/tmp` | Per path: min free MB, max % used, max % inodes |
| `precheck_tx_headroom_mb` | `1024` | Space that must remain after the update (50 MB on a separate `/boot`) |
| `olvm_storage_min_free_pct` / `_gb` | `15` / `100` | Storage domain floor after expected snapshot growth |
| `olvm_snapshot_growth_pct` | `25` | Expected snapshot growth as % of each disk's used size |
| `olvm_max_existing_snapshots` | `1` | Snapshots already on a VM before ours |

"Approved updates" is whatever the enabled repos offer under `patch_mode`. For the same package set in every environment, point hosts at a frozen repo snapshot (a ULN channel clone or a mirror) and promote it.

---

## Deploying

```bash
ansible-builder build -t <hub>/ee-olvm-patching:1.0.0 && podman push <hub>/ee-olvm-patching:1.0.0
# load the secrets into Key Vault, fill in aap/vars.yml, then:
export CONTROLLER_HOST=https://<aap> CONTROLLER_OAUTH_TOKEN=<token> AZURE_KV_CLIENT_SECRET=<sp-secret>
ansible-playbook aap/configure_controller.yml
```

Lab run without AAP: `site.yml` runs 01–05 in one go. It has no inventory sync and no failure routing to the report. To develop and test outside the client environment (OCI dev box, mock Jira, snapshot test mode, AAP trial), see [dev/README.md](dev/README.md).

---

## Test status

| Area | Status |
|---|---|
| All playbooks | `--syntax-check` passes |
| 01 → 02 → 05 against a mock Jira | Passed: approved path, scope exclusions (tag, not on ticket, not in group), host-list parsing, update parsing, Jira comment + attachment |
| Unapproved ticket | Passed: gate halts; report posts `HALTED` |
| 06 description parsing and ageing | Passed in isolation; manual snapshots are ignored |
| VM pre-checks | Passed with faked system commands: healthy, tight disk (MB, %, inodes, read-only), busy package manager, foreign-release packages, oversized update on a shared filesystem |
| OLVM storage and disk preflight | Logic passed with synthetic OLVM data: domain over the limit, direct LUN, shareable disk, VM with no disks. The OLVM API calls themselves (`vm_names=` disk search, attribute names) still need checking on the first phase 1 run |
| 03 / 04 / 06 against OLVM and real OL hosts | **Not yet run.** Test first on a non-production VM |
| `aap/configure_controller.yml` | **Not yet run.** Check the `workflow_nodes` format against the installed `ansible.controller` version |

---

## Snapshot notes

- Snapshots are disk-only (`use_memory: false`). Without `qemu-guest-agent` they are crash-consistent only; the pre-check warns about this. Set `precheck_require_guest_agent: true` to make it a failure instead.
- Deleting a snapshot on a running VM triggers a live merge, which loads storage. Schedule the cleanup workflow out of hours.
- Long-lived snapshots grow qcow2 chains and use up storage-domain space. Keep retention short.
- Database VMs: a disk snapshot is not a database backup. Make sure RMAN or equivalent backups are in place separately.
