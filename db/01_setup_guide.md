# SyncSpace — PgAdmin & PostgreSQL Setup Guide

> **Audience:** Developer / DBA bringing up a fresh local environment for the SyncSpace B2B Project Management System.
> **Prerequisites:** PostgreSQL 13+ installed and running; PgAdmin 4 installed; you know your `postgres` superuser password.
> **Deliverables produced by this guide:** A working `syncspace_db` database populated with mock enterprise records ready to query.

---

## Step 1 — Launch PgAdmin and create a Server Connection

1. Open **PgAdmin 4**. On first launch you will be prompted for a **master password** — set and remember this; it protects saved server credentials.
2. In the left **Object Explorer** pane, right-click on **Servers** → **Register** → **Server…**.
3. In the dialog:
   - **General tab → Name:** `Local SyncSpace` (any human-friendly label).
   - **Connection tab → Host name/address:** `localhost`
   - **Connection tab → Port:** `5432` (default).
   - **Connection tab → Maintenance database:** `postgres`
   - **Connection tab → Username:** `postgres`
   - **Connection tab → Password:** *your superuser password* — tick **Save password**.
4. Click **Save**. The server appears in the Object Explorer tree and connects automatically.

> ✅ **Verification:** Expand `Servers → Local SyncSpace → Databases`. You should see at least the default `postgres` database.

---

## Step 2 — Create the blank `syncspace_db` database

1. In Object Explorer, right-click on **Databases** under your server → **Create** → **Database…**.
2. Fill in the dialog:
   - **General tab → Database:** `syncspace_db`
   - **General tab → Owner:** `postgres`
   - **Definition tab → Encoding:** `UTF8`
   - **Definition tab → Template:** `template0` (clean baseline).
3. Click **Save**. The new database `syncspace_db` appears under `Databases` in the tree.

> ✅ **Verification:** Right-click `syncspace_db` → **Properties** → confirm encoding is `UTF8` and the database is empty (no schemas other than `public`).

---

## Step 3 — Open the Query Tool

1. In Object Explorer, **left-click on `syncspace_db`** to select it (this is critical — the Query Tool runs against whichever database is selected).
2. Open the Query Tool in either of these ways:
   - **Top menu:** `Tools` → `Query Tool`, **or**
   - **Right-click** on `syncspace_db` → `Query Tool`.
3. A new tab opens titled `Query - syncspace_db/postgres@Local SyncSpace`. The bottom-right status bar should read **Connected** in green.

> ⚠️ If the Query Tool says it is connected to `postgres` instead of `syncspace_db`, close the tab and repeat Step 3 — the database must be selected in the tree first.

---

## Step 4 — Execute the schema + seed script

1. Open the file `db/02_schema_and_seed.sql` in any text editor.
2. **Copy the entire file** (Ctrl+A, Ctrl+C).
3. **Paste** it into the PgAdmin Query Tool editor (Ctrl+V).
4. Click the **▶ Execute / Refresh** button on the Query Tool toolbar (keyboard shortcut **F5**).
5. The **Messages** pane at the bottom will stream results. A successful run ends with:

   ```
   NOTICE:  SyncSpace schema and seed data loaded successfully.
   Query returned successfully in <X> ms.
   ```

> 🛑 If you see `ERROR: extension "pgcrypto" is not available`, run this single line first as the `postgres` superuser, then re-run the script:
>
> ```sql
> CREATE EXTENSION IF NOT EXISTS pgcrypto;
> ```

---

## Step 5 — Verify table creation in the Object Explorer

1. In the Object Explorer tree, expand:

   ```
   Servers
    └─ Local SyncSpace
        └─ Databases
            └─ syncspace_db
                └─ Schemas
                    └─ public
                        └─ Tables
   ```

2. Right-click `Tables` → **Refresh…** (or press F5 with the node selected).
3. You should now see **seven tables**, in alphabetical order:

   - `companies`
   - `invoices`
   - `projects`
   - `subtasks`
   - `tasks`
   - `users`
   - `work_submissions`

4. Optionally expand `Types` under `public` to confirm the four custom ENUMs exist:

   - `invoice_status`
   - `project_status`
   - `task_status`
   - `user_role`

> ✅ **Visual confirmation:** Each table shows a small grid icon. Right-click any table → **View/Edit Data → All Rows** to inspect contents directly.

---

## Step 6 — Run a basic verification query

1. Return to the Query Tool tab connected to `syncspace_db`.
2. Clear the editor (Ctrl+A, Delete) and paste the following verification block:

   ```sql
   -- Sanity check: row counts per seeded table
   SELECT 'companies'         AS table_name, COUNT(*) AS rows FROM companies
   UNION ALL SELECT 'users',                COUNT(*) FROM users
   UNION ALL SELECT 'projects',             COUNT(*) FROM projects
   UNION ALL SELECT 'tasks',                COUNT(*) FROM tasks
   UNION ALL SELECT 'subtasks',             COUNT(*) FROM subtasks
   UNION ALL SELECT 'invoices',             COUNT(*) FROM invoices
   UNION ALL SELECT 'work_submissions',     COUNT(*) FROM work_submissions
   ORDER BY table_name;

   -- Business sanity: every project has its client and manager joined
   SELECT
       p.project_code,
       p.title,
       c.legal_name           AS client_company,
       mgr.full_name          AS manager,
       p.quotation_amount,
       p.status
   FROM projects p
   JOIN companies c   ON c.company_id = p.client_company_id
   JOIN users mgr     ON mgr.user_id  = p.manager_id
   ORDER BY p.project_code;
   ```

3. Press **F5** to execute. The **Data Output** pane will show:

   - Row counts: `companies = 3`, `users = 7`, `projects = 4`, `tasks = 9`, `subtasks = 14`, `invoices = 5`, `work_submissions = 2`.
   - A second result set listing all four projects with their joined client company and manager name.

> ✅ If both result sets render, the database is fully provisioned and ready for the SyncSpace application layer.

---

## Optional — Inspect ENUM values

```sql
SELECT typname AS enum_type,
       array_agg(enumlabel ORDER BY enumsortorder) AS values
FROM pg_type t
JOIN pg_enum  e  ON t.oid = e.enumtypid
WHERE typname IN ('user_role','project_status','task_status','invoice_status')
GROUP BY typname
ORDER BY typname;
```

Expected output: each ENUM type listed with its allowed labels, confirming role and status constraints are in force at the database level.

---

## Troubleshooting reference

| Symptom | Likely cause | Fix |
|---|---|---|
| `ERROR: type "user_role" already exists` | Script run twice without the `DROP IF EXISTS` block reaching that step. | Re-run the **entire** script from line 1 — it is idempotent and drops in the correct order. |
| `permission denied for schema public` | Connected as a non-owner role. | Reconnect as `postgres` (or grant `ALL ON SCHEMA public TO <user>`). |
| Verification query returns 0 rows | Script aborted mid-way; transaction rolled back. | Scroll up in the **Messages** pane to find the first `ERROR:` line and resolve it. |
| Query Tool shows the wrong database name in its tab | Wrong database was selected before opening the tool. | Close the tab; click `syncspace_db` once in the tree; reopen Query Tool. |
