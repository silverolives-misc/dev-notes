# Developing outside the client environment

The client's AAP isn't ready, so development runs in three stages. Each stage proves something the previous one couldn't.

| Stage | Where | Proves | Can't prove |
|---|---|---|---|
| **1. Dev box** | OCI: Ansible control node + an OL test VM | Playbook logic: gate, scope, every VM pre-check, dnf update, reboot, validation, report, Jira update | OLVM snapshots (no OLVM), AAP workflow routing, artifacts passed between jobs, credentials and Key Vault |
| **2. AAP trial** | Red Hat AAP trial | `aap/configure_controller.yml`, the workflow (failure and "always" paths), artifacts between nodes, survey, approval node, credential types, Key Vault links, the EE | OLVM, real Device42, the client's network |
| **3. Client** | Azure managed AAP + OLVM + Device42 | Snapshot preflight and create/delete against real OLVM, the Device42 plugin output, execution reaching the hosts | — |

Before phase 1, run at least one non-production OLVM VM through the whole workflow **with** snapshots.

---

## Stage 1: OCI dev box

### Control node setup (OL9)

Use ansible-core **2.16**, the same version as the EE. 2.17 can't manage OL8 hosts. 2.16 needs Python 3.10 or later on the control node, and OL9's default Python is 3.9:

```bash
sudo dnf install -y python3.11 python3.11-pip git
python3.11 -m venv ~/venv-ansible && source ~/venv-ansible/bin/activate
pip install 'ansible-core>=2.16,<2.17' requests ovirt-engine-sdk-python
ansible-galaxy collection install -r collections/requirements.yml
```

`ovirt-engine-sdk-python` isn't needed in snapshot test mode, but installing it now means stage 3 needs no change. If it fails to build, install `gcc libcurl-devel libxml2-devel python3.11-devel` first.

### Test VM setup

- Put its private IP in `dev/inventory/hosts.yml`. The SSH user is `opc` on OCI images.
- The `opc` user needs passwordless sudo, which OCI images have by default.
- Optionally install `qemu-guest-agent`. On OCI the package installs but the service won't run, because OCI has no agent channel. The resulting warning is expected.

### Credentials

```bash
cp dev/env.example dev/env      # git-ignored
vi dev/env                      # Jira details, or the mock below
source dev/env
```

For Jira, use either a free Jira Cloud site (create a "Change" issue type and the four custom fields, then put their IDs in `dev/vars.yml`) or the local mock:

```bash
python3 dev/mock_jira.py 8765 &
export JIRA_URL=http://127.0.0.1:8765 JIRA_USER=mock-user JIRA_TOKEN=mock-token-x7
```

The mock covers the gate's paths by ticket number:

| Ticket | Behaviour |
|---|---|
| `CHG-1` | Approved, window open, scope from the patch group alone |
| `CHG-2` | Awaiting approval (gate halts) |
| `CHG-3` | Outside the change window (gate halts) |
| `CHG-4` | Approved, with a host list on the ticket |

Comments and attachments it receives are written to `dev/mock_jira.log`.

**Avoid short or common words as test tokens.** Ansible masks every occurrence of a secret in its output, so a token of `dev` turns the patch group `dev_oci` into `********_oci`.

### Run

The whole chain (gate, scope and pre-checks, snapshot in **test mode**, patch, report):

```bash
ansible-playbook -i dev/inventory/hosts.yml site.yml -e @dev/vars.yml -e change_ticket=CHG-1
```

A single stage, passing in what the earlier jobs would have produced:

```bash
ansible-playbook -i dev/inventory/hosts.yml 02_precheck.yml -e @dev/vars.yml \
  -e '{"patch_change": {"ticket": "CHG-1", "patch_group": "dev_oci", "ticket_hosts": []}}'
```

### Breaking the test VM on purpose

The pre-checks are the main thing worth exercising. On the test VM:

| To test | Do |
|---|---|
| Free space and % used | `fallocate -l 20G /var/tmp/fill` (size it to the disk) |
| Inode limit | Create many small files in `/tmp` |
| Busy package manager | Run `dnf -y install <pkg>` in another session while the pre-check runs |
| `dnf check` failure | `rpm -i --nodeps --force` an older duplicate package |
| Wrong major release | Add an OL9 repo file to an OL8 VM |
| Update too large for free space | Combine the space filler with a large pending update |
| Reboot / validation failure | Set `patch_required_services: [does-not-exist]` |
| Gate halts | Tickets `CHG-2` and `CHG-3` |
| Test mode refused | `-e '{"patch_change": {"patch_group": "prod_wave1", ...}}'` on `03_snapshot.yml` |

Take an OCI boot volume backup of the test VM first, so it can be reset between runs.

---

## Snapshot test mode

Set `snapshot_test_mode: true` (in `dev/vars.yml`) to skip OLVM entirely. Safeguards:

- **Refused unless the patch group matches `snapshot_test_mode_group_regex`** (`dev`, `test` or `lab` prefix). A production group fails the snapshot job.
- **Every affected host is flagged "NO SNAPSHOT — test mode"** in the report, and the Jira comment carries a red test-mode banner.
- **Off by default in `group_vars`.** Never set it on a production job template.

---

## Stage 2: AAP trial

- Red Hat offers a 60-day AAP trial. Install with the AAP 2.5 containerized installer on a RHEL 9 VM; a free Red Hat Developer subscription covers the RHEL. The installer's "growth" topology includes automation hub for the EE.
- Build the EE from `execution-environment.yml` (`podman login registry.redhat.io` first) and push it to that hub.
- Point `CONTROLLER_HOST` at the trial's platform gateway and run `aap/configure_controller.yml`. It's the same playbook that will configure the client's AAP.
- Use the mock Jira or the Jira Cloud site, the dev static inventory as an AAP inventory (in place of the Device42 source), and `snapshot_test_mode: true` as an extra var on the snapshot job template.
- **Worth proving here:**
  - the failure routes: a gate halt still reaches the report node
  - artifacts reaching every node
  - the cleanup workflow's approval node
  - Key Vault links, using a small Azure Key Vault and service principal of your own

Differences from the client's Azure managed AAP: jobs run on the trial's local execution node, not as pods on AKS, and the network paths are different. Neither affects the playbooks or the config-as-code. Both matter for stage 3.
