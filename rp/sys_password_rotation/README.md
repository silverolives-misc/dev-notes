# sys_password_rotation

Ansible role for automated SYS password rotation on Oracle ExaCC databases.

Vault KV2 drives the process end-to-end — Ansible reads the estate from Vault,
builds an in-memory inventory, and rotates any database whose secret has exceeded
the configured age threshold. Topology (Data Guard, Commvault) is auto-detected
and appropriate actions taken for each.

---

## Role Structure

```
sys_password_rotation/
├── defaults/main.yml              # All configurable variables
├── vars/main.yml                  # Internal variables (sqlplus preamble etc)
├── meta/main.yml                  # Role metadata and dependencies
├── tasks/
│   ├── main.yml                   # Entry point — ordered phase execution
│   ├── precheck_vault.yml         # Vault connectivity, metadata, secret age
│   ├── detect_topology.yml        # Auto-detect Data Guard and Commvault
│   ├── precheck_oracle.yml        # RAC instances, DB role, PDBs, SYS account
│   ├── precheck_dataguard.yml     # DG errors, lag, MRP (when DG detected)
│   ├── precheck_password_policy.yml  # Profile limits, rollover time, complexity
│   ├── precheck_sessions.yml      # SYS sessions, RMAN jobs, dbaascli check
│   ├── evaluate_rotation.yml      # Decide, generate password, break-glass
│   ├── rotate.yml                 # dbaascli password change + Vault PRIMARY write
│   ├── action_dataguard.yml       # Blob propagation to standbys + Vault writes
│   ├── action_commvault.yml       # Commvault notification or credential update
│   └── post_validate.yml          # Connect with new password, verify Vault
└── rotate_sys_password.yml        # Example Vault-driven playbook
```

---

## Execution Phases

```
Phase 1  — Vault pre-checks         (connectivity, age, readable)
Phase 2  — Topology detection       (Data Guard, Commvault)
Phase 3  — Oracle DB pre-checks     (RAC instances, role, PDBs, SYS account)
Phase 4  — Data Guard pre-checks    (DG errors, lag, MRP) [if detected]
Phase 5  — Password policy checks   (rollover time, complexity, no mid-rollover)
Phase 6  — Session/backup checks    (SYS sessions, RMAN, dbaascli available)
Phase 7  — Evaluate rotation        (needed? generate password, break-glass)
Phase 8  — Rotate                   (dbaascli, Vault write PRIMARY)
Phase 9  — DG post-rotation         (blob to standbys, Vault write per member)
Phase 10 — Commvault post-rotation  (notify or update credentials)
Phase 11 — Post-validation          (connect new password, Vault version check)
```

---

## Topology Detection

### Data Guard
Detected by querying (any one is sufficient):
- `v$dataguard_config` — DG broker member list
- `v$parameter` — `dg_broker_start`, `log_archive_config`, `log_archive_dest_2`
- `v$standby_log` — standby redo logs present

**Action when detected:**
- `dbaascli` called with `--prepareStandbyBlob` on the primary
- Blob file SCP'd to each standby node
- `dbaascli --standbyBlobFromPrimary` applied on each standby
- Vault KV2 updated for **each** DG member (primary + all standbys)
- Blob files cleaned up on all nodes

### Commvault
Detected by any of:
- `/etc/CommVaultRegistry` directory exists
- `cvd` process is running
- `/usr/bin/simpana` binary exists
- SBT_TAPE RMAN backup jobs found in last 30 days

**Action when detected (commvault_notify_only: true — default):**
- Detailed notice written to `commvault_notification_log`
- DBA/Commvault admin must update credentials in CommCell Console
- Last SBT backup status logged for reference

**Action when detected (commvault_notify_only: false):**
- Commvault service restarted via simpana
- Notice still written — manual credential update in CommCell still required
- Last SBT backup status logged

> **Note:** Full automated credential update in CommCell requires either the
> Commvault REST API or qcommand CLI, which are environment-specific.
> The role provides the notification scaffolding and restart hook as a starting
> point. Extend `action_commvault.yml` with your CommCell API details.

---

## Vault Payload (per database)

```json
{
  "password": "...",
  "db_unique_name": "FINDB_PRIMARY",
  "db_role": "PRIMARY",
  "node_fqdn": "exacc-node1.example.com",
  "scan_address": "findb-scan.example.com",
  "oracle_version": "19.30.0.0.0",
  "rotated_by": "ansible-automation",
  "rotated_at": "2026-05-11T13:00:00Z"
}
```

## Vault Path Convention

```
<environment>/exacc/<region>/<db_unique_name>/sys

Examples:
  prod/exacc/uk-london-1/FINDB_PRIMARY/sys
  prod/exacc/uk-london-1/FINDB_STANDBY/sys    ← written by action_dataguard
  nonprod/exacc/uk-london-1/FINDB_DEV/sys
  dr/exacc/eu-frankfurt-1/FINDB_DR/sys
```

---

## Key Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `vault_url` | (required) | Vault server URL |
| `vault_role_id` | (required) | AppRole role ID |
| `vault_secret_id` | (required) | AppRole secret ID |
| `vault_mount_point` | `secret` | KV2 mount point |
| `oracle_home` | `/u01/app/oracle/product/19.0.0/dbhome_1` | Oracle home path |
| `oracle_port` | `1521` | Listener port |
| `password_max_age_days` | `90` | Rotation trigger threshold |
| `password_min_age_days` | `1` | Minimum age before re-rotation |
| `password_length` | `20` | Generated password length |
| `min_rollover_time_days` | `1/24` | Minimum PASSWORD_ROLLOVER_TIME |
| `fail_on_active_rman` | `true` | Fail if RMAN is running |
| `dg_enabled` | `false` | Force DG mode (auto-detected normally) |
| `commvault_enabled` | `false` | Force CV mode (auto-detected normally) |
| `commvault_notify_only` | `true` | Notify only vs attempt credential update |
| `breakglass_backup_enabled` | `true` | Store current password before rotation |
| `dbaascli_path` | `/usr/local/bin/dbaascli` | Path to dbaascli binary |

---

## Requirements

```bash
# Ansible collections
ansible-galaxy collection install community.hashi_vault

# Python on control node
pip install hvac

# Oracle sqlplus available on DB nodes (standard on ExaCC)
# dbaascli available on DB nodes (standard on ExaCC)
```

---

## Usage

```bash
# Set AppRole credentials
export VAULT_ROLE_ID="your-role-id"
export VAULT_SECRET_ID="your-secret-id"

# Pre-checks only — no changes
ansible-playbook rotate_sys_password.yml --tags precheck

# Full run
ansible-playbook rotate_sys_password.yml

# DG and Commvault actions only (after a partial run)
ansible-playbook rotate_sys_password.yml --tags action_dg,action_commvault

# Force topology detection output only
ansible-playbook rotate_sys_password.yml --tags detect_topology
```
