# DPE Oracle OTP — SSH One-Time-Password Setup for ExaCC

> **Note for whoever pastes this in:** Confluence's editor will pick up this markdown reasonably well (headings, tables, code blocks). The mermaid diagram will only render if your instance has a Mermaid macro/app installed — otherwise, drop it in as a code block or swap it for the exported PNG in `dpe_oracle_otp/README.md`.

## Summary

`dpe_oracle_otp` is an Ansible playbook that configures and validates **HashiVault SSH OTP** authentication on Oracle DPE ExaCC hosts. It replaces static SSH passwords with short-lived, Vault-issued one-time passwords for both the `ans_oracle` service account and root (via `su`).

It's run from AAP (Ansible Automation Platform) against a list of target hosts and can operate in four modes: **check**, **setup**, **test**, and **verify**.

| | |
|---|---|
| **Repo path** | `dpe_oracle_otp/` |
| **Entry point** | `main.yml` |
| **Owning team** | *(fill in — DPE / Oracle platform engineering)* |
| **Run via** | AAP job template, or `ansible-playbook` directly against a bastion with Vault network access |

## What problem this solves

ExaCC hosts previously relied on static SSH credentials for the automation landing account. This playbook moves those hosts to Vault-brokered OTP auth:

- A Vault SSH secrets engine issues a **single-use password** per login, scoped to a specific host and account.
- The host's PAM stack (via a custom `authselect` profile) validates that OTP against `vault-ssh-helper` instead of a static password hash.
- Every login is short-lived and auditable in Vault — no long-lived shared secret sits on the host.

## How it works

The play runs as four sequential Ansible plays:

1. **Build in-memory inventory** — loads vars, validates required inputs, and registers `target_hosts` into an in-memory group (no static inventory needed).
2. **Check OTP client set-up status** — read-only audit of each host's current state (landing account, `vault-ssh-helper` install, PAM config, sshd config). Runs for `check` and `setup`.
3. **Set-up and post-verify** — for `setup`, provisions the host (account, package, authselect profile, PAM/sshd changes) as root, rolled out in batches (`1 → 10% → 25% → 100%`, zero tolerance for failures mid-batch). Then, for `setup`/`test`/`verify`, it pulls a Vault login token and per-account OTPs and **actually logs in over SSH** as `ans_oracle` and as root to prove the setup works.
4. **Report** — aggregates a per-host `otp_report` (setup status, reachability, full validation breakdown, OS facts) into the job's stats output.

Full task-by-task breakdown, all input variables, and a sequence diagram of the Vault/host interaction are maintained in the repo README: `dpe_oracle_otp/README.md`.

## Inputs

**Required extra-vars for every run:**

- `_action` — `check` | `setup` | `test` | `verify`
- `target_hosts` — list of hostnames to operate on
- `_ansibleukenv` — `dev` | `uat` | `prod` (selects `vars/<env>.yml`)

**Environment variables (set on the AAP execution environment / controller):**

- `_CLIENT__HASHI_URL`, `_CLIENT__HASHI_NAMESPACE`, `_CLIENT__HASHI_ROLE`

**Vars files:** `vars/dpe_otp.yml` (Vault URL) and `vars/<env>.yml` (per-environment account, package, PAM, and authselect settings).

## Outputs

- **`otp_report`** stat — per host: `otp_setup_ok`, `otp_reachable`, full `otp_validation` breakdown (user/group, helper package/binary/config, PAM contents, sshd flags, Vault reachability, ssh service state), and OS facts.
- Job log shows the literal `id` command output from both the `ans_oracle` and root OTP logins, as human-readable proof the connection worked.
- A host fails the run outright if OTP login doesn't succeed on anything other than the very first attempt (first-attempt failures are expected pre-setup and are cleared rather than failing the batch).

## Running it

```
ansible-playbook main.yml \
  -e "_action=setup" \
  -e "_ansibleukenv=dev" \
  -e '{"target_hosts":["exacc-node01","exacc-node02"]}'
```

| `_action` | Use when you want to... |
|---|---|
| `check` | Audit current OTP readiness without changing anything. |
| `setup` | Provision the host for OTP *and* prove the login works. |
| `verify` / `test` | Re-confirm OTP login on an already-provisioned host. |

Prefer running via the AAP job template so credentials, environment variables, and the execution environment (with `community.hashi_vault`, `community.general`, and the client's Vault OTP lookup collection) are already wired up correctly.

## Known gaps / things to check before relying on this in prod

- `server_otp_setup.yml` templates four files (`vault-helper.hcl.j2`, `password-auth.j2`, `system-auth.j2`, `postlogin.j2`) from a `templates/` directory that isn't present in this checkout yet — confirm it's supplied by the execution environment or add it before running `setup`.
- `tasks/get_from_vault.yml` (fetches a separate `build_credentials` secret) exists in the repo but isn't currently called from `main.yml` — treat it as unused/leftover unless someone confirms otherwise.
- Only `vars/dev.yml` exists today; `uat.yml` and `prod.yml` will need to be created (mirroring the same keys) before this can target those environments.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `Missing sudo password` on the ans_oracle-only step | `become` was applied to the wrong scope — it must wrap only `server_otp_setup.yml`, not the whole play (see comment in `main.yml`). |
| Host fails on first `setup` run with "OTP failed Pre OTP set-up" | Expected — the host isn't OTP-enabled yet. The error is cleared automatically when `first_attempt` is true. |
| `otp_validation.vault_reachable` is false | Host can't reach the Vault URL from `vars/dpe_otp.yml` — check network/firewall path from the ExaCC host to Vault, not just from the controller. |
| Setup runs but connection test still fails | Check `otp_validation.sshd_usepam_ok` / `sshd_passwordauth_ok` and whether the `authselect` profile actually activated (`authselect_otp_profile_exists`). |

## Related

- Repo README with full variable reference and Mermaid sequence diagram: `dpe_oracle_otp/README.md`
- *(Add links here to: the AAP job template, the Vault SSH secrets engine config, and any runbook for onboarding a new environment.)*
