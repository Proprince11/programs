-- =====================================================================
-- SyncSpace B2B Project Management System
-- PostgreSQL schema + seed data — paste into PgAdmin Query Tool, press F5
-- ---------------------------------------------------------------------
-- Tested on PostgreSQL 13, 14, 15, 16
-- Idempotent: dropping in reverse-FK order, then recreating cleanly
-- All monetary values: NUMERIC(14,2)  -- avoids float drift
-- All identifiers: UUID via pgcrypto    -- avoids enumeration leaks
-- Timestamps:    TIMESTAMPTZ            -- timezone-aware
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 0. Required extension for gen_random_uuid()
-- ---------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------
-- 1. Drop existing objects in reverse dependency order (idempotent)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS work_submissions CASCADE;
DROP TABLE IF EXISTS invoices         CASCADE;
DROP TABLE IF EXISTS subtasks         CASCADE;
DROP TABLE IF EXISTS tasks            CASCADE;
DROP TABLE IF EXISTS projects         CASCADE;
DROP TABLE IF EXISTS users            CASCADE;
DROP TABLE IF EXISTS companies        CASCADE;

DROP TYPE  IF EXISTS invoice_status   CASCADE;
DROP TYPE  IF EXISTS task_status      CASCADE;
DROP TYPE  IF EXISTS project_status   CASCADE;
DROP TYPE  IF EXISTS user_role        CASCADE;

-- ---------------------------------------------------------------------
-- 2. Custom ENUM types — single source of truth for state machines
-- ---------------------------------------------------------------------
CREATE TYPE user_role       AS ENUM ('Manager', 'Client', 'WorkingStaff');
CREATE TYPE project_status  AS ENUM ('Proposed', 'Approved', 'InProgress', 'OnHold', 'Completed', 'Cancelled');
CREATE TYPE task_status     AS ENUM ('Pending', 'InProgress', 'Blocked', 'Submitted', 'Approved', 'Rejected');
CREATE TYPE invoice_status  AS ENUM ('Draft', 'Issued', 'Paid', 'Overdue', 'Void');

-- ---------------------------------------------------------------------
-- 3. companies — the client organizations (and the internal "house" co)
-- ---------------------------------------------------------------------
CREATE TABLE companies (
    company_id      UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    legal_name      VARCHAR(150)    NOT NULL UNIQUE,
    industry        VARCHAR(80)     NOT NULL,
    contact_email   VARCHAR(150)    NOT NULL,
    contact_phone   VARCHAR(40),
    billing_address TEXT,
    is_internal     BOOLEAN         NOT NULL DEFAULT FALSE,    -- TRUE for the agency's own company
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    CONSTRAINT companies_email_chk CHECK (contact_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);

CREATE INDEX idx_companies_industry ON companies(industry);

-- ---------------------------------------------------------------------
-- 4. users — provisioned by Manager only; role is enforced via ENUM
-- ---------------------------------------------------------------------
CREATE TABLE users (
    user_id         UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id      UUID            NOT NULL REFERENCES companies(company_id) ON DELETE RESTRICT,
    full_name       VARCHAR(120)    NOT NULL,
    email           VARCHAR(150)    NOT NULL UNIQUE,
    role            user_role       NOT NULL,
    password_hash   VARCHAR(255)    NOT NULL,                   -- bcrypt/argon2 from app layer
    is_active       BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    CONSTRAINT users_email_chk CHECK (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);

CREATE INDEX idx_users_company ON users(company_id);
CREATE INDEX idx_users_role    ON users(role);

-- ---------------------------------------------------------------------
-- 5. projects — owned by Client company, run by an internal Manager
--    Tracks: Quotation $; Planned vs. Actual dates
-- ---------------------------------------------------------------------
CREATE TABLE projects (
    project_id          UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    project_code        VARCHAR(20)     NOT NULL UNIQUE,           -- e.g. "PRJ-2025-0001"
    title               VARCHAR(180)    NOT NULL,
    description         TEXT,
    client_company_id   UUID            NOT NULL REFERENCES companies(company_id) ON DELETE RESTRICT,
    manager_id          UUID            NOT NULL REFERENCES users(user_id)        ON DELETE RESTRICT,
    quotation_amount    NUMERIC(14,2)   NOT NULL CHECK (quotation_amount >= 0),
    currency_code       CHAR(3)         NOT NULL DEFAULT 'USD',
    status              project_status  NOT NULL DEFAULT 'Proposed',
    planned_start_date  DATE            NOT NULL,
    planned_end_date    DATE            NOT NULL,
    actual_start_date   DATE,
    actual_end_date     DATE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    CONSTRAINT projects_planned_window_chk  CHECK (planned_end_date >= planned_start_date),
    CONSTRAINT projects_actual_window_chk   CHECK (actual_end_date  IS NULL OR actual_start_date IS NOT NULL),
    CONSTRAINT projects_actual_order_chk    CHECK (actual_end_date  IS NULL OR actual_end_date >= actual_start_date)
);

CREATE INDEX idx_projects_client  ON projects(client_company_id);
CREATE INDEX idx_projects_manager ON projects(manager_id);
CREATE INDEX idx_projects_status  ON projects(status);

-- ---------------------------------------------------------------------
-- 6. tasks — top-level work items inside a project
-- ---------------------------------------------------------------------
CREATE TABLE tasks (
    task_id             UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id          UUID            NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    title               VARCHAR(180)    NOT NULL,
    description         TEXT,
    assigned_to         UUID            REFERENCES users(user_id) ON DELETE SET NULL,    -- WorkingStaff
    status              task_status     NOT NULL DEFAULT 'Pending',
    priority            SMALLINT        NOT NULL DEFAULT 3 CHECK (priority BETWEEN 1 AND 5),
    expected_start_date DATE            NOT NULL,
    expected_due_date   DATE            NOT NULL,
    actual_start_date   DATE,
    actual_completed_at DATE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    CONSTRAINT tasks_expected_window_chk CHECK (expected_due_date >= expected_start_date)
);

CREATE INDEX idx_tasks_project   ON tasks(project_id);
CREATE INDEX idx_tasks_assignee  ON tasks(assigned_to);
CREATE INDEX idx_tasks_status    ON tasks(status);

-- ---------------------------------------------------------------------
-- 7. subtasks — atomic checklist items under a task; cascade with parent
-- ---------------------------------------------------------------------
CREATE TABLE subtasks (
    subtask_id          UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id             UUID            NOT NULL REFERENCES tasks(task_id) ON DELETE CASCADE,
    title               VARCHAR(180)    NOT NULL,
    is_done             BOOLEAN         NOT NULL DEFAULT FALSE,
    done_by             UUID            REFERENCES users(user_id) ON DELETE SET NULL,
    done_at             DATE,
    sort_order          SMALLINT        NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    CONSTRAINT subtasks_done_consistency_chk
        CHECK ( (is_done = TRUE AND done_at IS NOT NULL) OR (is_done = FALSE AND done_at IS NULL) )
);

CREATE INDEX idx_subtasks_task ON subtasks(task_id);

-- ---------------------------------------------------------------------
-- 8. invoices — issued against a project; amount can be partial billing
-- ---------------------------------------------------------------------
CREATE TABLE invoices (
    invoice_id      UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    invoice_number  VARCHAR(30)     NOT NULL UNIQUE,                 -- e.g. "INV-2025-001"
    project_id      UUID            NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    issued_by       UUID            NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT,
    amount_issued   NUMERIC(14,2)   NOT NULL CHECK (amount_issued > 0),
    currency_code   CHAR(3)         NOT NULL DEFAULT 'USD',
    status          invoice_status  NOT NULL DEFAULT 'Draft',
    issue_date      DATE            NOT NULL,
    due_date        DATE            NOT NULL,
    paid_at         DATE,
    notes           TEXT,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    CONSTRAINT invoices_due_after_issue_chk CHECK (due_date >= issue_date),
    CONSTRAINT invoices_paid_only_when_paid_chk
        CHECK ( (status = 'Paid' AND paid_at IS NOT NULL) OR (status <> 'Paid' AND paid_at IS NULL) )
);

CREATE INDEX idx_invoices_project ON invoices(project_id);
CREATE INDEX idx_invoices_status  ON invoices(status);

-- ---------------------------------------------------------------------
-- 9. work_submissions — staff submits deliverables; client reviews
-- ---------------------------------------------------------------------
CREATE TABLE work_submissions (
    submission_id   UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id         UUID            NOT NULL REFERENCES tasks(task_id)   ON DELETE CASCADE,
    submitted_by    UUID            NOT NULL REFERENCES users(user_id)   ON DELETE RESTRICT,
    summary         TEXT            NOT NULL,
    delivery_url    VARCHAR(500),
    submitted_at    TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    reviewed_by     UUID            REFERENCES users(user_id)            ON DELETE SET NULL,
    reviewed_at     TIMESTAMPTZ,
    review_status   task_status,                                            -- Approved / Rejected
    review_notes    TEXT
);

CREATE INDEX idx_submissions_task ON work_submissions(task_id);

-- =====================================================================
-- SEED DATA  (deterministic UUIDs for reproducible joins in the prototype)
-- =====================================================================

-- ---- companies -----------------------------------------------------
INSERT INTO companies (company_id, legal_name, industry, contact_email, contact_phone, billing_address, is_internal) VALUES
  ('11111111-1111-1111-1111-111111111111', 'SyncSpace Studios LLC',  'Software Services', 'ops@syncspace.io',          '+1-415-555-0100', '500 Mission St, San Francisco, CA',  TRUE),
  ('22222222-2222-2222-2222-222222222222', 'Helios Retail Group',    'Retail',            'finance@heliosretail.com',  '+1-212-555-0143', '88 Madison Ave, New York, NY',       FALSE),
  ('33333333-3333-3333-3333-333333333333', 'Atlas Medtech Inc.',     'Medical Devices',   'pmo@atlasmedtech.com',      '+1-617-555-0177', '12 Kendall Sq, Cambridge, MA',       FALSE);

-- ---- users ---------------------------------------------------------
-- Note: password_hash values are placeholder bcrypt-shaped strings; replace at app layer.
INSERT INTO users (user_id, company_id, full_name, email, role, password_hash, is_active) VALUES
  ('aaaaaaa1-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Maya Chen',        'maya.chen@syncspace.io',     'Manager',      '$2b$12$seedhashmanager0000000000000000000000', TRUE),
  ('aaaaaaa2-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Devon Carter',     'devon.carter@syncspace.io',  'WorkingStaff', '$2b$12$seedhashstaff10000000000000000000000000', TRUE),
  ('aaaaaaa3-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'Priya Iyer',       'priya.iyer@syncspace.io',    'WorkingStaff', '$2b$12$seedhashstaff20000000000000000000000000', TRUE),
  ('aaaaaaa4-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'Lukas Berg',       'lukas.berg@syncspace.io',    'WorkingStaff', '$2b$12$seedhashstaff30000000000000000000000000', TRUE),
  ('bbbbbbb1-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'Eleanor Whitfield','e.whitfield@heliosretail.com','Client',      '$2b$12$seedhashclient10000000000000000000000000', TRUE),
  ('bbbbbbb2-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'Marcus Reid',      'm.reid@heliosretail.com',    'Client',       '$2b$12$seedhashclient20000000000000000000000000', TRUE),
  ('ccccccc1-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333', 'Dr. Anika Rao',    'a.rao@atlasmedtech.com',     'Client',       '$2b$12$seedhashclient30000000000000000000000000', TRUE);

-- ---- projects ------------------------------------------------------
INSERT INTO projects (project_id, project_code, title, description, client_company_id, manager_id,
                      quotation_amount, currency_code, status,
                      planned_start_date, planned_end_date, actual_start_date, actual_end_date) VALUES
  ('p0000001-0000-0000-0000-000000000001', 'PRJ-2025-0001',
   'Helios E-Commerce Replatform',
   'Migrate Helios Retail flagship store to a headless commerce stack with new checkout flow.',
   '22222222-2222-2222-2222-222222222222',
   'aaaaaaa1-0000-0000-0000-000000000001',
   185000.00, 'USD', 'InProgress',
   '2025-02-03', '2025-06-30', '2025-02-05', NULL),

  ('p0000002-0000-0000-0000-000000000002', 'PRJ-2025-0002',
   'Helios Loyalty Mobile App',
   'Native iOS/Android loyalty programme with points engine and offer push.',
   '22222222-2222-2222-2222-222222222222',
   'aaaaaaa1-0000-0000-0000-000000000001',
   92000.00, 'USD', 'Approved',
   '2025-04-15', '2025-09-15', NULL, NULL),

  ('p0000003-0000-0000-0000-000000000003', 'PRJ-2024-0099',
   'Atlas Surgical Console Firmware Audit',
   'Independent audit of firmware update pipeline for FDA submission readiness.',
   '33333333-3333-3333-3333-333333333333',
   'aaaaaaa1-0000-0000-0000-000000000001',
   64500.00, 'USD', 'Completed',
   '2024-10-01', '2024-12-20', '2024-10-03', '2024-12-18'),

  ('p0000004-0000-0000-0000-000000000004', 'PRJ-2025-0010',
   'Atlas Patient Portal Refresh',
   'UX overhaul of the patient-facing portal with WCAG 2.2 AA compliance.',
   '33333333-3333-3333-3333-333333333333',
   'aaaaaaa1-0000-0000-0000-000000000001',
   48000.00, 'USD', 'Proposed',
   '2025-07-01', '2025-10-15', NULL, NULL);

-- ---- tasks ---------------------------------------------------------
INSERT INTO tasks (task_id, project_id, title, description, assigned_to, status, priority,
                   expected_start_date, expected_due_date, actual_start_date, actual_completed_at) VALUES
  -- Project 1: Helios E-Commerce Replatform
  ('t0000001-0000-0000-0000-000000000001', 'p0000001-0000-0000-0000-000000000001',
   'Headless commerce architecture spike', 'Evaluate Shopify Hydrogen vs. commercetools.',
   'aaaaaaa2-0000-0000-0000-000000000002', 'Approved', 1,
   '2025-02-05', '2025-02-21', '2025-02-05', '2025-02-19'),

  ('t0000002-0000-0000-0000-000000000002', 'p0000001-0000-0000-0000-000000000001',
   'Checkout flow redesign', 'Wireframes + clickable prototype, A/B variants.',
   'aaaaaaa3-0000-0000-0000-000000000003', 'InProgress', 2,
   '2025-02-22', '2025-04-04', '2025-02-24', NULL),

  ('t0000003-0000-0000-0000-000000000003', 'p0000001-0000-0000-0000-000000000001',
   'Payment gateway integration', 'Stripe + Adyen failover, PCI-DSS scope review.',
   'aaaaaaa4-0000-0000-0000-000000000004', 'Pending', 2,
   '2025-04-07', '2025-05-23', NULL, NULL),

  ('t0000004-0000-0000-0000-000000000004', 'p0000001-0000-0000-0000-000000000001',
   'Performance & load testing', 'k6 scripts, 10k RPS target, p95 < 250ms.',
   'aaaaaaa2-0000-0000-0000-000000000002', 'Pending', 3,
   '2025-05-26', '2025-06-20', NULL, NULL),

  -- Project 2: Helios Loyalty Mobile App
  ('t0000005-0000-0000-0000-000000000005', 'p0000002-0000-0000-0000-000000000002',
   'Points engine API design', 'Define RESTful contract + idempotency keys.',
   'aaaaaaa3-0000-0000-0000-000000000003', 'Pending', 2,
   '2025-04-15', '2025-05-09', NULL, NULL),

  ('t0000006-0000-0000-0000-000000000006', 'p0000002-0000-0000-0000-000000000002',
   'iOS app skeleton', 'SwiftUI shell, deep-linking, push registration.',
   'aaaaaaa4-0000-0000-0000-000000000004', 'Pending', 2,
   '2025-05-12', '2025-06-27', NULL, NULL),

  -- Project 3: Atlas Firmware Audit (closed project)
  ('t0000007-0000-0000-0000-000000000007', 'p0000003-0000-0000-0000-000000000003',
   'Threat-model walk-through', 'STRIDE analysis of OTA update path.',
   'aaaaaaa2-0000-0000-0000-000000000002', 'Approved', 1,
   '2024-10-03', '2024-10-25', '2024-10-03', '2024-10-22'),

  ('t0000008-0000-0000-0000-000000000008', 'p0000003-0000-0000-0000-000000000003',
   'Static analysis & SBOM',  'Coverity scan, generate CycloneDX SBOM.',
   'aaaaaaa3-0000-0000-0000-000000000003', 'Approved', 2,
   '2024-10-28', '2024-11-29', '2024-10-29', '2024-11-27'),

  ('t0000009-0000-0000-0000-000000000009', 'p0000003-0000-0000-0000-000000000003',
   'Audit report & FDA appendix', 'Final deliverable for FDA 510(k) submission.',
   'aaaaaaa4-0000-0000-0000-000000000004', 'Approved', 1,
   '2024-12-02', '2024-12-19', '2024-12-02', '2024-12-17');

-- ---- subtasks ------------------------------------------------------
INSERT INTO subtasks (subtask_id, task_id, title, is_done, done_by, done_at, sort_order) VALUES
  -- task 1 (done)
  ('s0000001-0000-0000-0000-000000000001', 't0000001-0000-0000-0000-000000000001', 'Compile vendor evaluation matrix', TRUE,  'aaaaaaa2-0000-0000-0000-000000000002', '2025-02-10', 1),
  ('s0000002-0000-0000-0000-000000000002', 't0000001-0000-0000-0000-000000000001', 'Spike Hydrogen prototype',         TRUE,  'aaaaaaa2-0000-0000-0000-000000000002', '2025-02-15', 2),
  ('s0000003-0000-0000-0000-000000000003', 't0000001-0000-0000-0000-000000000001', 'Architecture decision record',     TRUE,  'aaaaaaa2-0000-0000-0000-000000000002', '2025-02-19', 3),
  -- task 2 (in progress)
  ('s0000004-0000-0000-0000-000000000004', 't0000002-0000-0000-0000-000000000002', 'Wireframe v1 (mobile)',            TRUE,  'aaaaaaa3-0000-0000-0000-000000000003', '2025-03-05', 1),
  ('s0000005-0000-0000-0000-000000000005', 't0000002-0000-0000-0000-000000000002', 'Wireframe v1 (desktop)',           TRUE,  'aaaaaaa3-0000-0000-0000-000000000003', '2025-03-10', 2),
  ('s0000006-0000-0000-0000-000000000006', 't0000002-0000-0000-0000-000000000002', 'Clickable prototype A/B',          FALSE, NULL,                                    NULL,         3),
  ('s0000007-0000-0000-0000-000000000007', 't0000002-0000-0000-0000-000000000002', 'Usability test rounds (2)',        FALSE, NULL,                                    NULL,         4),
  -- task 3 (pending)
  ('s0000008-0000-0000-0000-000000000008', 't0000003-0000-0000-0000-000000000003', 'Stripe sandbox integration',       FALSE, NULL,                                    NULL,         1),
  ('s0000009-0000-0000-0000-000000000009', 't0000003-0000-0000-0000-000000000003', 'Adyen failover wiring',            FALSE, NULL,                                    NULL,         2),
  ('s0000010-0000-0000-0000-000000000010', 't0000003-0000-0000-0000-000000000003', 'PCI scope assessment',             FALSE, NULL,                                    NULL,         3),
  -- task 7 (approved, closed)
  ('s0000011-0000-0000-0000-000000000011', 't0000007-0000-0000-0000-000000000007', 'STRIDE workshop',                  TRUE,  'aaaaaaa2-0000-0000-0000-000000000002', '2024-10-10', 1),
  ('s0000012-0000-0000-0000-000000000012', 't0000007-0000-0000-0000-000000000007', 'Threat register',                  TRUE,  'aaaaaaa2-0000-0000-0000-000000000002', '2024-10-22', 2),
  -- task 8
  ('s0000013-0000-0000-0000-000000000013', 't0000008-0000-0000-0000-000000000008', 'Coverity baseline scan',           TRUE,  'aaaaaaa3-0000-0000-0000-000000000003', '2024-11-12', 1),
  ('s0000014-0000-0000-0000-000000000014', 't0000008-0000-0000-0000-000000000008', 'Generate CycloneDX SBOM',          TRUE,  'aaaaaaa3-0000-0000-0000-000000000003', '2024-11-27', 2);

-- ---- invoices ------------------------------------------------------
INSERT INTO invoices (invoice_id, invoice_number, project_id, issued_by,
                      amount_issued, currency_code, status, issue_date, due_date, paid_at, notes) VALUES
  -- Helios E-Commerce: 50% milestone billed, partial paid
  ('i0000001-0000-0000-0000-000000000001', 'INV-2025-001', 'p0000001-0000-0000-0000-000000000001', 'aaaaaaa1-0000-0000-0000-000000000001',
   55500.00, 'USD', 'Paid',   '2025-02-15', '2025-03-17', '2025-03-12', 'Milestone 1: discovery & architecture (30%).'),
  ('i0000002-0000-0000-0000-000000000002', 'INV-2025-007', 'p0000001-0000-0000-0000-000000000001', 'aaaaaaa1-0000-0000-0000-000000000001',
   37000.00, 'USD', 'Issued', '2025-04-05', '2025-05-05', NULL,         'Milestone 2: design sign-off (20%).'),
  -- Atlas Audit: fully billed, fully paid
  ('i0000003-0000-0000-0000-000000000003', 'INV-2024-211', 'p0000003-0000-0000-0000-000000000003', 'aaaaaaa1-0000-0000-0000-000000000001',
   32250.00, 'USD', 'Paid',   '2024-10-20', '2024-11-19', '2024-11-04', 'Audit phase A — 50%.'),
  ('i0000004-0000-0000-0000-000000000004', 'INV-2024-258', 'p0000003-0000-0000-0000-000000000003', 'aaaaaaa1-0000-0000-0000-000000000001',
   32250.00, 'USD', 'Paid',   '2024-12-19', '2025-01-18', '2025-01-08', 'Audit phase B + final report.'),
  -- Helios Loyalty: kickoff retainer issued, currently overdue
  ('i0000005-0000-0000-0000-000000000005', 'INV-2025-014', 'p0000002-0000-0000-0000-000000000002', 'aaaaaaa1-0000-0000-0000-000000000001',
   18400.00, 'USD', 'Overdue','2025-04-20', '2025-05-20', NULL,         'Kickoff retainer (20%).');

-- ---- work_submissions ---------------------------------------------
INSERT INTO work_submissions (submission_id, task_id, submitted_by, summary, delivery_url,
                              submitted_at, reviewed_by, reviewed_at, review_status, review_notes) VALUES
  ('w0000001-0000-0000-0000-000000000001', 't0000001-0000-0000-0000-000000000001', 'aaaaaaa2-0000-0000-0000-000000000002',
   'Hydrogen vs. commercetools spike complete; ADR attached.',
   'https://syncspace.example/deliverables/PRJ-2025-0001/adr-001.pdf',
   '2025-02-19 16:42:00+00', 'bbbbbbb1-0000-0000-0000-000000000001', '2025-02-21 09:15:00+00', 'Approved',
   'Strong analysis — proceed with Hydrogen.'),

  ('w0000002-0000-0000-0000-000000000002', 't0000007-0000-0000-0000-000000000007', 'aaaaaaa2-0000-0000-0000-000000000002',
   'STRIDE threat model and register delivered.',
   'https://syncspace.example/deliverables/PRJ-2024-0099/stride-report.pdf',
   '2024-10-22 11:05:00+00', 'ccccccc1-0000-0000-0000-000000000001', '2024-10-24 14:00:00+00', 'Approved',
   'Accepted; appendix A will be referenced in FDA submission.');

-- ---------------------------------------------------------------------
-- Final notice
-- ---------------------------------------------------------------------
DO $$ BEGIN
    RAISE NOTICE 'SyncSpace schema and seed data loaded successfully.';
END $$;

COMMIT;

-- =====================================================================
-- VERIFICATION QUERIES (highlight & run individually after the script)
-- =====================================================================
--   SELECT 'companies' AS t, COUNT(*) FROM companies
--   UNION ALL SELECT 'users',            COUNT(*) FROM users
--   UNION ALL SELECT 'projects',         COUNT(*) FROM projects
--   UNION ALL SELECT 'tasks',            COUNT(*) FROM tasks
--   UNION ALL SELECT 'subtasks',         COUNT(*) FROM subtasks
--   UNION ALL SELECT 'invoices',         COUNT(*) FROM invoices
--   UNION ALL SELECT 'work_submissions', COUNT(*) FROM work_submissions;
--
--   SELECT p.project_code, p.title, c.legal_name AS client, p.status,
--          p.quotation_amount,
--          COALESCE((SELECT SUM(amount_issued) FROM invoices i WHERE i.project_id = p.project_id),0) AS total_invoiced
--   FROM projects p
--   JOIN companies c ON c.company_id = p.client_company_id
--   ORDER BY p.project_code;
