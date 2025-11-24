# ⚠️ Critical Notes on replace_stack Role

## 🚨 Warning

This role is **extremely sensitive to order of operations**. Altering task sequence, skipping UID rewrites, or changing file ownership/permissions has been proven to cause:

- Dashboards failing to import (`restricted database access`)
- Alert rules failing (`invalid alert query`, `receiver does not exist`)
- Datasource misalignment (no data, duplicate UIDs)
- Endless cycles of “no data” troubleshooting

⚠️ **Do not reorder tasks casually. Precision here is surgical.**

---

## 🏁 Quick Start

1. Ensure dependencies are installed:
   - Docker CE + Docker Compose v2
   - Python modules: `docker`, `requests`
   - Tools: `jq`, `ipmitool`

2. Place container tarballs and config files under `/opt/ansible/files/std1/`.

3. Run the playbook:
   ```bash
   ansible-playbook -i inventory.yml replace_stack.yml
   ```

4. Log into Grafana (port 3000). Default admin password may still prompt for reset, but can be skipped.

---

## 🛠️ Purpose

The `replace_stack` role automates a full containerized monitoring environment using:

- Grafana `11.4`
- Prometheus `2.54.1`
- InfluxDB `2.7.11`
- Telegraf `1.18.3`
- NGINX `1.27.4`
- IPMI `1.10.1`
- SNMP `v0.29.0`

It ensures:

- Datasources are provisioned (`prometheus.yml`, `idrac.yml`)
- Alert rules are UID-corrected for datasource mappings
- Dashboards are cleaned, stripped of embedded datasources, UID-rewritten, and safely imported
- InfluxDB org/bucket/token are created and injected into configs
- Plugins and provisioning files are installed with correct ownership/permissions

---

## ✅ Challenges Overcome

1. **UID Rewrites**
   - Problem: Grafana alert rules and dashboards referenced non-existent datasources.
   - Fix: Targeted `jq` rewrites against `.datasourceUid` fields inside alert rules and dashboards.
   - Why UID logic is critical:
     - Grafana provisioning references datasources by UID, **not by name**.
     - If an alert rule or panel references `prometheus` but the provisioned datasource UID is `ds-prometheus`, Grafana treats it as missing.
     - Therefore:
       - Alert rules targeting Prometheus must use `ds-prometheus`.
       - iDRAC rules must use `idrac-influxdb`.
     - Dashboards embed old UIDs — stripping and rewriting aligns them with provisioned datasources.
   **Variables defined in replace_stack/vars/main.yml that define dashboard names with UID correlations.

2. **Dashboard Import Failures**
   - Problem: Dashboards refused import (`restricted database access`, `duplicate UID`).
   - Fix:
     - Strip `.id` and `.version` from JSON
     - Remove embedded datasource blocks
     - Rewrite datasource UIDs to match provisioned ones

3. **Alert Rules “Receiver Does Not Exist”**
   - Problem: Contact points and notification policies missing.
   - Fix: Provisioned with explicit filenames (`00-notification-policies.yml`, `01-contacts.yml`) to guarantee load order.

4. **InfluxDB Org/Bucket/Token Mismatch**
   - Problem: Telegraf 401 errors, Grafana “bucket not found” errors.
   - Fix: Force creation of `ccop-org` + `idrac` bucket and generate a fresh token injected into both `influxdb.conf` and `telegraf.conf`.

5. **Permissions Errors**
   - Problem: `permission denied` when provisioning alert rules.
   - Fix: Explicit recursive `file` tasks set ownership to Grafana UID `472` and appropriate modes for all provisioning directories.

---

## 🔗 Order of Operations

1. **Render Telegraf placeholder config** (dummy token)
2. **Start containers** (`docker_compose_v2`)
3. **Wait for InfluxDB health endpoint**
4. **Force InfluxDB org, bucket, and token creation**
5. **Re-render configs** (`influxdb.conf`, `telegraf.conf`) with live token
6. **Restart InfluxDB & Telegraf**
7. **Copy Grafana plugins** and clean up tarball
8. **Provision Datasources** (`prometheus.yml`, `idrac.yml`)
9. **Restart Grafana** so datasources are available
10. **Copy Alert Rules** → Fix permissions → UID rewrite
11. **Clean & Import Dashboards** → Strip IDs, rewrite UIDs → Fix permissions
12. **Provision Notification Policies + Contacts**
13. **Final Container Restarts** (Grafana mandatory, others optional)
14. **Sanity Checks** (Grafana API query confirms presence of datasources, dashboards, rules)

---

## 📂 Essential File Tree

```text
/opt/ansible/files/std1/
├── grafana/
│   ├── datasources/
│   │   ├── prometheus.yml
│   │   └── idrac.yml.j2
│   ├── dashboards/
│   │   ├── default.yml
│   │   ├── idrac_dashboard.json
│   │   ├── nuc_linux_dashboard.json
│   │   └── nuc_windows_dashboard.json
│   ├── alerting/
│   │   ├── contact-points.yml
│   │   ├── notification-policies.yml
│   │   └── *.json (alert rules)
│   └── plugins/plugins.tar.gz
├── influxdb/
│   └── influxdb.conf.j2
└── telegraf/
    └── telegraf.conf.j2
```

---

## 📋 To-Do

1. **Variablize Role**
   - Replace hardcoded values (`ccop-org`, `idrac`, passwords, IPs) with variables.
   - Add defaults in `defaults/main.yml`.

2. **Interactive Setup Role**
   - Prompt for org, bucket, admin creds, and container versions.
   - Update `docker-compose.yml`, templates, and provisioning files dynamically.

3. **Dependency Verification Role**
   - Check and install:
     - Docker CE + Compose v2
     - Python requirements (`docker`, `requests`, etc.)
     - System tools (`jq`, `ipmitool`)

4. **Container Versioning**
   - Currently pinned: Grafana `11.4`, InfluxDB `2.7.11`, Prometheus `2.54.1`, Telegraf `1.18.3`, NGINX `1.27.4`.
   - Add variable support to test newer container versions without breaking UID rewrites.

---

## ✅ Conclusion

This role is a **fragile but powerful orchestration tool**. It stitches together multiple monitoring containers, forces consistent UID rewrites, ensures Grafana provisioning works, and eliminates the constant manual debugging of missing datasources and failed dashboards.

⚠️ Future modifications must respect the **order of operations** or risk weeks of troubleshooting regressions.
