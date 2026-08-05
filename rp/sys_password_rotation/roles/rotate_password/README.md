# rotate_password — Ansible Role

## Objective

Rotates an Oracle user's password on a single ExaCC database node. The role is generic — it defaults to `SYS` but can rotate any Oracle account by passing `target_user`. It is called once per confirmed PRIMARY database by the driving playbook (`main.yml`). All phases run inside a single `block/rescue` so any failure is captured and reported to the end-of-run summary without aborting the remaining estate.

All pre-checks run before any mutation. The password is only changed if all checks pass and `rotation_required` evaluates to true.

---

## Role Structure

```
roles/rotate_password/
├── tasks/
│   ├── main.yml                     # Entry point — block/rescue wrapper
│   ├── precheck_vault.yml           # Phase 1  — Vault role reachability + age gate
│   ├── detect_topology.yml          # Phase 2  — dbaascli topology (role, SCAN, PDBs)
│   ├── precheck_oracle.yml          # Phase 3  — Credential validation, account status
│   ├── precheck_dataguard.yml       # Phase 4  — DG lag check (conditional)
│   ├── precheck_password_policy.yml # Phase 5  — PASSWORD_ROLLOVER_TIME profile check
│   ├── precheck_sessions.yml        # Phase 6  — Active sessions + RMAN gate
│   ├── evaluate_rotation.yml        # Phase 7  — Age gate + break-glass write
│   ├── rotate.yml                   # Phase 8  — dbaascli changePassword (conditional)
│   ├── action_dataguard.yml         # Phase 9  — Blob or direct propagation to standbys
│   ├── action_commvault.yml         # Phase 10 — Commvault notification (conditional)
│   └── post_validate.yml            # Phase 11 — New cred test + Vault version confirm
├── defaults/main.yml                # User-configurable defaults
├── vars/main.yml                    # Internal constants (sqlplus preamble, oracle_env)
├── files/
├── templates/
└── meta/main.yml
```

---

## Inputs

### Required Hostvars (supplied by the driving playbook via `add_host`)

| Variable | Description |
|---|---|
| `db_unique_name` | Oracle DB_UNIQUE_NAME |
| `oracle_db_name` | Oracle DB_NAME (used with dbaascli `--dbname`) |
| `node_fqdn` | FQDN of the cluster node to SSH to |
| `current_oracle_password` | Current password from Vault `/cred/` endpoint |
| `secret_age_days` | Age of the current Vault secret in days |
| `vault_role_name` | Vault role name (e.g. `SYS_<DB_UNIQUE_NAME>_EXACC`) |
| `vault_engine_url` | Vault base URL |
| `vault_engine_mount` | Vault engine mount path |
| `vault_namespace` | Vault namespace |
| `login_token` | Vault login token (used for OTP lookups and Vault API calls) |

### Configurable Defaults (`defaults/main.yml`)

#### Vault

| Variable | Default | Description |
|---|---|---|
| `vault_engine_url` | `""` | Vault base URL |
| `vault_engine_mount` | `secrets/static-database` | Engine mount point |
| `vault_namespace` | `""` | Vault namespace header |
| `vault_token_ttl` | `6h` | Login token TTL |

#### Rotation Policy

| Variable | Default | Description |
|---|---|---|
| `target_user` | `SYS` | Oracle account to rotate |
| `password_max_age_days` | `90` | Rotate if credential age exceeds this (days) |
| `password_min_age_days` | `1` | Skip if rotated more recently than this (days) |
| `password_length` | `20` | Generated password character length |
| `min_rollover_time_days` | `1/24` (1 hour) | Minimum `PASSWORD_ROLLOVER_TIME` expected on the Oracle profile |

#### Pre-check Thresholds

| Variable | Default | Description |
|---|---|---|
| `dg_max_lag_seconds` | `300` | Maximum tolerated Data Guard apply lag |
| `sys_session_warning_threshold` | `5` | Warn (not fail) if active sessions exceed this |
| `fail_on_active_rman` | `true` | Abort rotation if an RMAN backup job is running |

#### Topology Overrides

| Variable | Default | Description |
|---|---|---|
| `dg_enabled` | `false` | Force DG path regardless of auto-detection |
| `commvault_enabled` | `false` | Force Commvault path regardless of auto-detection |

#### Break-Glass

| Variable | Default | Description |
|---|---|---|
| `breakglass_backup_enabled` | `true` | Write backup of current password before rotation |
| `breakglass_backup_path` | `/etc/oracle/breakglass` | Directory for break-glass files (root-owned, `0600`) |

Break-glass filenames: `<db_unique_name>_<target_user_lower>_breakglass_<date>.txt`

#### Commvault

| Variable | Default | Description |
|---|---|---|
| `commvault_registry_path` | `/etc/CommVaultRegistry` | Path used to detect Commvault installation |
| `commvault_process_name` | `cvd` | Process name used to confirm Commvault is running |
| `commvault_ora_user` | `sysbackup` | Oracle account Commvault connects with |
| `commvault_notify_only` | `true` | Log notification only; do not update Commvault credentials |
| `commvault_notification_log` | `/var/log/ansible/commvault_rotation_notice.log` | Notification log path |

### Internal Variables (`vars/main.yml`)

| Variable | Description |
|---|---|
| `sqlplus_preamble` | Standard silent sqlplus header (`WHENEVER`, `SET` commands) |
| `oracle_env` | Shell command to source the per-DB env file (sets `ORACLE_SID`, `ORACLE_HOME`) |
| `sqlplus_connect` | `/ as sysdba` — OS authentication, no password required |

---

## Outputs

The role writes its result back to `localhost` using `delegate_to: localhost` + `delegate_facts: true`. The driving playbook's Phase 3 reads these accumulated facts to build the final report.

### On success (Phase 12)

Appended to `hostvars['localhost']['rotation_summary']`:

```json
{
  "DBNAME": {
    "status": "ROTATED",
    "host": "node.example.com",
    "vault_role": "SYS_DBNAME_EXACC",
    "node": "node.example.com",
    "db_role": "PRIMARY",
    "dg": false,
    "commvault": false,
    "secret_age": 94.3
  }
}
```

`status` is `ROTATED` if rotation ran, `SKIPPED` if the age gate determined rotation was not yet due.

### On failure (rescue block)

Appended to `hostvars['localhost']['rotation_failures']`:

```json
{
  "DBNAME": {
    "host": "node.example.com",
    "failed_task": "Phase 3 | Oracle DB pre-checks",
    "error": "Current SYS password from Vault does not authenticate against Oracle..."
  }
}
```

The host is then re-failed so it counts against `max_fail_percentage` in the driving playbook.

---

## Phase Detail

| Phase | File | Runs when | Description |
|---|---|---|---|
| 1 | `precheck_vault.yml` | Always | Assert Vault hostvars present; GET role metadata; capture pre-rotation version |
| 2 | `detect_topology.yml` | Always | `dbaascli database getDetails`; set `db_role`, `scan_address`, `dg_detected`, `commvault_detected` |
| 3 | `precheck_oracle.yml` | Always | Validate current Vault credential via sqlplus; SYS uses `CONNECT sys/... as sysdba`, others use `CONNECT user/...`; assert `db_role == PRIMARY` |
| 4 | `precheck_dataguard.yml` | `dg_detected == true` | Check DG apply lag ≤ `dg_max_lag_seconds`; assert no gap sequences |
| 5 | `precheck_password_policy.yml` | Always | Assert `PASSWORD_ROLLOVER_TIME` is set on `account_profile` and meets minimum; warn on unsupported Oracle versions |
| 6 | `precheck_sessions.yml` | Always | Count active sessions (warn if above threshold); assert no running RMAN jobs |
| 7 | `evaluate_rotation.yml` | Always | Compare age vs threshold; set `rotation_required`; write break-glass if rotating |
| 8 | `rotate.yml` | `rotation_required == true` | `dbaascli changePassword --user {{ target_user }}`; SYS+DG uses `--prepareStandbyBlob`; non-SYS or non-DG uses standard change |
| 9 | `action_dataguard.yml` | `rotation_required and dg_detected` | **SYS**: SCP blob to standbys; `dbaascli changePassword --standbyBlobFromPrimary`; **non-SYS**: direct `dbaascli changePassword` on each standby; Vault updated for all standby roles |
| 10 | `action_commvault.yml` | `rotation_required and commvault_detected and commvault_ora_user == target_user` | Append notification to `commvault_notification_log` |
| 11 | `post_validate.yml` | `rotation_required == true` | Connect sqlplus with new credential; assert `CONNECTION_OK`; confirm Vault `current_version` incremented; delete break-glass |
| 12 | `main.yml` (inline) | Always | `set_fact` → `rotation_summary` on localhost |

---

## Sequence Diagram

```mermaid
sequenceDiagram
    autonumber
    participant PB as Playbook (Phase 2)
    participant Vault as HashiCorp Vault
    participant ExaCC as ExaCC Node (root)
    participant Oracle as Oracle DB (sqlplus)
    participant DG as DG Standby Nodes
    participant CV as Commvault Log

    rect rgb(230, 240, 255)
        Note over PB,Vault: Phase 1 — Vault Pre-check
        PB->>Vault: GET /role/{vault_role_name}
        Vault-->>PB: created_at, current_version (pre-rotation baseline)
        PB->>PB: Assert hostvars present; assert age ≥ min_age_days
    end

    rect rgb(230, 255, 230)
        Note over PB,ExaCC: Phase 2 — Topology Detection
        PB->>ExaCC: dbaascli database getDetails --dbname
        ExaCC-->>PB: dbRole, SCAN, PDB list, topology flags
        PB->>PB: Set db_role, dg_detected, commvault_detected
    end

    rect rgb(255, 245, 230)
        Note over PB,Oracle: Phase 3 — Oracle Pre-check
        PB->>ExaCC: source .env → sqlplus / as sysdba (OS auth)
        ExaCC->>Oracle: CONNECT {target_user}/"$CRED"[ as sysdba if SYS]
        Oracle-->>ExaCC: CREDENTIAL_OK
        PB->>PB: Assert db_role == PRIMARY
    end

    opt dg_detected == true
        rect rgb(255, 230, 230)
            Note over PB,Oracle: Phase 4 — Data Guard Pre-check
            PB->>Oracle: SELECT lag from v$dataguard_stats
            Oracle-->>PB: Apply lag in seconds
            PB->>PB: Assert lag ≤ dg_max_lag_seconds; assert no gap sequences
        end
    end

    rect rgb(245, 230, 255)
        Note over PB,Oracle: Phase 5 — Password Policy
        PB->>Oracle: SELECT from dba_profiles WHERE profile = account_profile
        Oracle-->>PB: PASSWORD_ROLLOVER_TIME and other limits
        PB->>PB: Assert PASSWORD_ROLLOVER_TIME ≥ min_rollover_time_days
    end

    rect rgb(230, 255, 255)
        Note over PB,Oracle: Phase 6 — Session and RMAN Gate
        PB->>Oracle: SELECT from gv$session WHERE username = target_user
        Oracle-->>PB: Active session count
        PB->>Oracle: SELECT from v$rman_backup_job_details WHERE status = 'RUNNING'
        Oracle-->>PB: RMAN job count
        PB->>PB: Warn if sessions > threshold; fail if RMAN running
    end

    rect rgb(255, 255, 220)
        Note over PB,ExaCC: Phase 7 — Evaluate Rotation
        PB->>PB: Compare secret_age_days vs password_max_age_days → set rotation_required
        alt rotation_required == true
            PB->>ExaCC: Write break-glass → breakglass_backup_path/{db}__{user}_breakglass_{date}.txt
        end
    end

    opt rotation_required == true

        rect rgb(255, 220, 180)
            Note over PB,ExaCC: Phase 8 — Rotate
            alt dg_detected and target_user == SYS
                PB->>ExaCC: printf new_pass | dbaascli changePassword --user SYS --prepareStandbyBlob
            else non-DG or non-SYS
                PB->>ExaCC: printf new_pass | dbaascli changePassword --user {target_user}
            end
            ExaCC-->>PB: RC 0
        end

        opt dg_detected == true
            rect rgb(220, 220, 255)
                Note over PB,DG: Phase 9 — Data Guard Propagation
                alt target_user == SYS
                    PB->>ExaCC: SCP blob file to each standby node
                    loop Each standby
                        PB->>DG: dbaascli changePassword --standbyBlobFromPrimary
                        DG-->>PB: RC 0
                    end
                    PB->>ExaCC: Delete blob from primary and standbys
                else non-SYS
                    loop Each standby
                        PB->>DG: printf new_pass | dbaascli changePassword --user {target_user}
                        DG-->>PB: RC 0
                    end
                end
                loop Each standby
                    PB->>Vault: POST /role/{target_user}_{standby}_EXACC (new credential)
                    Vault-->>PB: 200 OK
                end
            end
        end

        opt commvault_detected and commvault_ora_user == target_user
            rect rgb(220, 255, 220)
                Note over PB,CV: Phase 10 — Commvault Notification
                PB->>CV: Append rotation notice to commvault_notification_log
            end
        end

        rect rgb(200, 240, 200)
            Note over PB,Vault: Phase 11 — Post-Validation
            PB->>Oracle: sqlplus CONNECT {target_user}/"$new_cred"[ as sysdba if SYS]
            Oracle-->>PB: CONNECTION_OK; account_status = OPEN (not LOCKED)
            PB->>Vault: GET /role/{vault_role_name}
            Vault-->>PB: current_version (assert > pre-rotation baseline)
            PB->>ExaCC: Delete break-glass backup file
        end

    end

    rect rgb(220, 220, 220)
        Note over PB: Phase 12 — Record Result
        PB->>PB: set_fact rotation_summary → localhost (ROTATED or SKIPPED)
    end
```

---

## Error Handling

All phases run inside a `block/rescue`. If any phase fails:

1. The rescue block captures `ansible_failed_task.name` and `ansible_failed_result.msg`
2. The failure is recorded to `hostvars['localhost']['rotation_failures']` via `delegate_facts: true`
3. The host is re-failed so it registers against `max_fail_percentage` in the driving playbook
4. Other databases in the estate are unaffected (unless `max_fail_percentage` is breached)

The break-glass backup file is **only deleted on confirmed success** (Phase 11). If the role fails after Phase 8 (password changed in Oracle but Vault write failed), the break-glass file remains on the target host for manual recovery.

---

## Connection Model

The role executes on the target ExaCC node via SSH. The driving playbook supplies OTP credentials at the play level:

```
SSH login   : ans_oracle   (OTP from Vault)
become      : root         (su, OTP from Vault)
become user : oracle       (task-level su override for sqlplus tasks)
```

Oracle OS authentication (`/ as sysdba`) is used for account-status and profile queries — no TNS listener is required. Credential validation (Phase 3) and post-rotation connectivity (Phase 11) connect as `target_user` directly via sqlplus. The per-database environment file (`/home/oracle/<db_unique_name>.env`) is sourced to set `ORACLE_SID` and `ORACLE_HOME` before each sqlplus call.
