# Cross-Database Access Using Module Signing on Amazon RDS for SQL Server

A hands-on lab that demonstrates how to achieve cross-database access on Amazon RDS for SQL Server **without** the `TRUSTWORTHY` property, using certificate-based module signing. All credentials are auto-generated and stored in AWS Secrets Manager — zero hardcoded passwords.

## Overview

SQL Server DBAs migrating to Amazon RDS discover that `ALTER DATABASE ... SET TRUSTWORTHY ON` fails because the RDS master user does not have the `sysadmin` server role. This breaks any stored procedure that queries tables in another database. Module signing with certificates is the RDS-compatible, least-privilege alternative.

This lab deploys a fully automated environment where you can:

1. Reproduce the cross-database access failure (Error 916)
2. Apply certificate-based module signing as the fix
3. Verify that only the signed procedure gains cross-database access

You run the walkthrough interactively in **SQL Server Management Studio (SSMS)** on a **Windows** workload host, using the queries in `blog-demo-queries.sql`.

## Architecture

```
┌────────────────────────────────────────────────────────────────────────┐
│                          VPC (10.0.0.0/16)                             │
│                                                                        │
│  ┌────────────────────────────┐    ┌─────────────────────────────────┐ │
│  │  EC2 Workload Host         │    │  RDS SQL Server Express         │ │
│  │  (Windows Server 2022)     │    │  (SQL Server 2022)              │ │
│  │                            │    │                                 │ │
│  │  • SSMS 20.2 (auto-install)│    │  • DatabaseA                    │ │
│  │    via boot scheduled task │───▶│    └─ dbo.GetSecretData (proc)  │ │
│  │  • labadmin local admin    │    │  • DatabaseB                    │ │
│  │    (for RDP login)         │    │    └─ dbo.SecretData (table)    │ │
│  │                            │    │                                 │ │
│  │  Access: Systems Manager   │    │  Access: port 1433 from         │ │
│  │  Fleet Manager Remote      │    │  EC2 security group only        │ │
│  │  Desktop (RDP over SSM)    │    └─────────────────────────────────┘ │
│  │  + SSM Session Manager     │                                        │
│  │  No inbound ports open     │                                        │
│  └──────────┬─────────────────┘                                        │
│             │                                                          │
│             ▼                                                          │
│  ┌────────────────────────────┐                                        │
│  │  AWS Secrets Manager       │                                        │
│  │                            │                                        │
│  │  • rds-master-password     │                                        │
│  │  • app-user-password       │                                        │
│  │  • db-master-key-a         │                                        │
│  │  • db-master-key-b         │                                        │
│  │  • cert-transfer-password  │                                        │
│  │  • windows-admin-password  │                                        │
│  └────────────────────────────┘                                        │
└────────────────────────────────────────────────────────────────────────┘
```

The workload host sits in a private subnet with **no public IP and no inbound ports**. Outbound internet (SSM registration, Secrets Manager, and the SSMS download) is via a NAT gateway. You reach the desktop through **Fleet Manager Remote Desktop**, which tunnels RDP over the SSM channel.

## Secrets Manager integration

All credentials are auto-generated at stack creation and retrieved at runtime. No passwords appear in the template or command history.

| Secret | Purpose |
|--------|---------|
| `rds-master-password` | RDS `admin` login (also enriched with host/port via `SecretTargetAttachment`) |
| `app-user-password` | AppUser SQL login (the limited user) |
| `db-master-key-a` | Database master key for DatabaseA |
| `db-master-key-b` | Database master key for DatabaseB |
| `cert-transfer-password` | Private key encryption during certificate transfer |
| `windows-admin-password` | Local Windows `labadmin` account for Fleet Manager Remote Desktop login |

> **Note:** The Windows AMI ships **AWS Tools for PowerShell**, not the `aws` CLI. On the box, retrieve secrets with `Get-SECSecretValue`, not `aws secretsmanager`.

## Prerequisites

1. **AWS account** with permissions to create VPCs, EC2, IAM roles, RDS instances, KMS keys, and Secrets Manager secrets.
2. **AWS CLI v2** installed and configured (for deploying the stack and reading secrets from your workstation).
   ```bash
   aws --version
   aws sts get-caller-identity
   ```
3. **Session Manager plugin** for the AWS CLI (used by Fleet Manager and for optional RDP port-forwarding).
   ```bash
   # macOS
   brew install --cask session-manager-plugin
   session-manager-plugin --version
   ```
   Other platforms: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
4. A **web browser** for the Fleet Manager Remote Desktop console session. (Optional: a native RDP client such as **Microsoft Remote Desktop** if you prefer full clipboard/keyboard support over an SSM port-forward.)

## Deploy the lab

### 1. Set your region

```bash
export AWS_REGION=us-west-2
```

### 2. Create the stack

No password parameter needed — Secrets Manager generates all credentials automatically.

```bash
aws cloudformation create-stack \
  --stack-name rds-crossdb-lab \
  --template-body file://rds-crossdb-lab-secretsmanager-test-passed.yaml \
  --capabilities CAPABILITY_IAM \
  --region $AWS_REGION
```

### 3. Wait for completion (15–25 minutes)

```bash
aws cloudformation wait stack-create-complete \
  --stack-name rds-crossdb-lab --region $AWS_REGION \
  && echo "Stack ready!"
```

### 4. Get the stack outputs

```bash
aws cloudformation describe-stacks \
  --stack-name rds-crossdb-lab --region $AWS_REGION \
  --query 'Stacks[0].Outputs' --output table
```

Useful outputs: `WorkloadDriverInstanceId`, `RdsEndpoint`, `WindowsAdminSecretArn`, `RdsMasterSecretArn`, and `GetWindowsAdminPasswordCommand`.

## Connect to the workload host

The instance registers with Systems Manager a few minutes after it reaches **running / 2 status checks**. SSMS installs in the background via a one-time scheduled task and appears **~10–15 minutes** after boot (it does not block login).

### 1. Get the Windows login (`labadmin`)

```bash
aws secretsmanager get-secret-value \
  --secret-id rds-crossdb-lab/windows-admin-password \
  --region $AWS_REGION --query SecretString --output text
```
Copy the `password` value (username is `labadmin`).

### 2. Open Fleet Manager Remote Desktop

Systems Manager console → **Fleet Manager** → select the node → **Node actions → Connect with Remote Desktop** → **Authentication type: User credentials** → `labadmin` + the password above.

> No key pair exists on this instance, so the "Get Windows password" (key-pair) path does not apply — use **User credentials** with `labadmin`.

### 3. (Optional) Native RDP client instead of the browser

If the browser client's keyboard/clipboard is awkward, port-forward RDP over SSM and use a native client:

```bash
aws ssm start-session \
  --target <WorkloadDriverInstanceId> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["3389"],"localPortNumber":["13389"]}' \
  --region $AWS_REGION
```
Then connect your RDP client to `localhost:13389` as `labadmin`.

## Run the lab (in SSMS)

Launch **SQL Server Management Studio 20** from the Start menu, then open `blog-demo-queries.sql`. You will use **two connections**: one as `admin` for setup/signing, and a second as `AppUser` for the failure/success tests.

### Connect SSMS to RDS (admin)

Get the endpoint and admin password (the RDS master secret is enriched with host/port). On the box:

```powershell
$secret = (Get-SECSecretValue -SecretId 'rds-crossdb-lab/rds-master-password' -Region 'us-west-2').SecretString | ConvertFrom-Json
"Server : {0},{1}" -f $secret.host, $secret.port
"Login  : {0}"      -f $secret.username   # admin
$secret.password | Set-Clipboard          # paste into SSMS with Ctrl+V
```

In **Connect to Server**: Server name `endpoint,1433`, Authentication **SQL Server Authentication**, Login `admin`, Encryption **Mandatory**. Leave **Trust server certificate** *unchecked* — instead, download the [Amazon RDS CA bundle](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html) and import it into the Windows **Trusted Root Certification Authorities** store so SSMS can validate the RDS server certificate. Checking "Trust server certificate" bypasses TLS certificate validation and must not be used.

### Walkthrough (sections in `blog-demo-queries.sql`)

| Part | Run as | What it does | Expected result |
|------|--------|--------------|-----------------|
| 1. Setup | admin | Create DatabaseA/B, `dbo.SecretData`, `AppUser`, unsigned `dbo.GetSecretData` | Objects created; `TRUSTWORTHY` = 0 |
| 2a/2b | admin | Confirm TRUSTWORTHY off; try to enable it | `is_trustworthy_on` = 0; `ALTER ... TRUSTWORTHY ON` fails with **Msg 15247** |
| 2c | **AppUser** | `EXEC dbo.GetSecretData` | **Msg 916** — cross-DB access denied |
| 3. Sign | admin | Master keys, `CrossDBCert` in DatabaseB, transfer to DatabaseA via `sp_executesql`, sign the proc | Signature attached |
| 4. Verify | **AppUser** | `EXEC dbo.GetSecretData` | Returns Acme Corp (780), Globex Inc (720) |
| 5. Least privilege | **AppUser** | `EXEC dbo.GetSecretUnsigned` | **Msg 916** — only the *signed* proc gains access |
| 6. Cleanup | admin | Drop databases + login | See below |

Notes for running in SSMS:
- **Placeholders:** replace `<APP_USER_PASSWORD>`, `<MK_A_PASSWORD>`, `<MK_B_PASSWORD>`, and both `<CERT_TRANSFER_PASSWORD>` occurrences with the matching Secrets Manager values (fetch with `Get-SECSecretValue`). The two cert-transfer values **must match**.
- **Run as AppUser** = open a second query window (**File → New → Database Engine Query**) with SQL auth as `AppUser`. Error 916 only appears for `AppUser`; running as `admin` always succeeds.
- **Batch scope:** the certificate-transfer block (`DECLARE @cert ... EXEC DatabaseA.dbo.sp_executesql @sql;`) must run as **one selection** — a `GO` in the middle drops the variables (Msg 137). Run it while connected to **DatabaseB** so `CERT_ID('CrossDBCert')` resolves.
- **Object Explorer** doesn't auto-refresh after DDL — right-click **Databases → Refresh** to see new/removed objects.

## Files

| File | Purpose |
|------|---------|
| `rds-crossdb-lab-secretsmanager-test-passed.yaml` | CloudFormation template (VPC, RDS, Windows workload host, KMS, Secrets Manager) |
| `blog-demo-queries.sql` | The full demo: setup, failure, module signing, verification, least-privilege proof, cleanup |
| `final_blog.md` | The blog post write-up |

## Clean up

### Option A: Delete the CloudFormation stack (recommended)

Removes RDS, EC2, secrets, KMS key, networking — everything — in one step.

```bash
aws cloudformation delete-stack \
  --stack-name rds-crossdb-lab --region $AWS_REGION

aws cloudformation wait stack-delete-complete \
  --stack-name rds-crossdb-lab --region $AWS_REGION \
  && echo "Stack deleted!"
```

### Option B: Manual SQL cleanup (if keeping the RDS instance)

Run Part 6 in `blog-demo-queries.sql` from an **admin** query window connected to `master`. The script:

1. Kills any sessions connected to DatabaseA/DatabaseB or logged in as AppUser (this prevents "database is currently in use" errors).
2. Forces `SET SINGLE_USER WITH ROLLBACK IMMEDIATE` + `DROP DATABASE` for each database — cascading removes all contained procedures, certificates, users, master keys, and tables automatically.
3. Drops the server-level `AppUser` login.
4. Ends with a verify query returning no rows.

The cleanup is idempotent — safe to re-run with no "does not exist" errors.

> **Important:** close any SSMS tabs connected as AppUser or connected *to* DatabaseA/DatabaseB before running cleanup (or let the `KILL` block handle them). A bare `DROP DATABASE` will fail with "database is currently in use" if leftover sessions exist.

## Estimated cost

| Resource | Sizing | Approx. hourly cost |
|----------|--------|---------------------|
| RDS SQL Server Express | db.t3.xlarge, 100 GB gp3 | ~$0.35/hr |
| EC2 workload host | t3.large (Windows Server 2022) | ~$0.10/hr |
| NAT Gateway | per-hour + per-GB | ~$0.05/hr |
| Secrets Manager | 6 secrets | ~$0.00 |
| Data transfer (intra-VPC) | Minimal | ~$0.00 |

A few hours of testing costs roughly **$3–5**. Delete the stack when done. Prices based on us-west-2. Use the [AWS Pricing Calculator](https://calculator.aws/) for current estimates.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| **Fleet Manager doesn't show the node** | Wait 3–5 minutes after 2/2 status checks. If still absent after 10+ minutes, stop/start the instance (not terminate — just stop → start) to force SSM re-registration. |
| **"Unable to establish Remote Desktop connection"** | Either UserData hasn't finished (give it 3–5 min), or the password is wrong. Verify `labadmin` exists via Session Manager: `Get-LocalUser labadmin`. |
| **SSMS not in Start menu** | The background scheduled task installs it ~10–15 min after boot. Check progress: `Get-Content C:\Windows\Temp\ssms-install.log -Wait`. If it failed, re-run manually: see Troubleshooting SSMS install below. |
| **SSMS Connect fails (timeout)** | Make sure you use the RDS endpoint (not instance ID) and port 1433. The RDS SG only allows connections from the EC2 SG. |
| **Msg 916 as admin** | Not expected. Double-check you're running as `AppUser` — admin always succeeds. |
| **"database is currently in use" on cleanup** | Close extra SSMS tabs or run the KILL block in Part 6. See the cleanup section above. |
| **`Get-SECSecretValue` errors** | Ensure you're running on the EC2 box (not your laptop) and the stack name in the secret-id is correct. |
| **Stack creation fails** | `aws cloudformation describe-stack-events --stack-name rds-crossdb-lab --query 'StackEvents[?ResourceStatus==\`CREATE_FAILED\`]'` |
| **Can't type in Fleet Manager RDP session** | Click into the remote desktop area to give it focus. If keyboard remains unresponsive, try a different browser or use the native RDP port-forward (see Connect section). |

### Troubleshooting SSMS install

If SSMS didn't install automatically (the scheduled task failed), install manually from PowerShell on the box:

```powershell
$out = "$env:TEMP\SSMS-Setup-ENU.exe"
Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2313753&clcid=0x409' -OutFile $out -UseBasicParsing
Start-Process -FilePath $out -ArgumentList '/Install','/Quiet','/Norestart' -Wait
```
This installs SSMS 20.2.1 (self-contained, ~660 MB, no runtime download). Takes ~10 min.

## Security

- All passwords are randomly generated (24–30 characters, no special-character conflicts)
- EC2 IAM role has least-privilege access: only `secretsmanager:GetSecretValue` on the 6 lab secrets + `kms:Decrypt` on the lab CMK
- `AmazonSSMManagedInstanceCore` managed policy for SSM / Fleet Manager connectivity
- RDS instance is not publicly accessible — reachable only from the EC2 security group on port 1433
- No inbound ports on the EC2 security group — Fleet Manager tunnels RDP over SSM (no port 3389 open)
- RDS master secret is attached to the instance via `SecretTargetAttachment` (enables future rotation)
- No passwords are logged, printed to stdout, or stored in plain text on disk
- The `labadmin` local account password is fetched from Secrets Manager at boot and set securely; it never appears in the template

## Related resources

- [AWS Blog: Cross-database access using module signing on Amazon RDS for SQL Server](final_blog.md)
- [Microsoft: Module signing](https://learn.microsoft.com/en-us/sql/relational-databases/security/authentication-access/module-signing)
- [Microsoft: CERTENCODED function](https://learn.microsoft.com/en-us/sql/t-sql/functions/certencoded-transact-sql)
- [AWS: Amazon RDS for SQL Server](https://aws.amazon.com/rds/sqlserver/)
- [AWS: Systems Manager Fleet Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/fleet-manager.html)
- [AWS: Secrets Manager](https://docs.aws.amazon.com/secretsmanager/latest/userguide/intro.html)
