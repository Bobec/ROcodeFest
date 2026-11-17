-- =====================================================================
-- 0002 — messages left through the contact form
-- =====================================================================
-- /contact had e-mail addresses and nothing else. It now has a form,
-- and what it sends is kept here until an organiser has read it in
-- /admin. No account is needed to write one, so the table does not
-- reference accounts.
--
-- APPLIED BY:  pwsh db/migrate.ps1
-- ALSO IN:     db/01_oltp_schema.sql (the table) and the stamp in
--              db/00_app_schema.sql, so a from-scratch build has it too
-- =====================================================================

-- citext lives in public; the table belongs in oltp.
SET LOCAL search_path = oltp, public;

CREATE TABLE IF NOT EXISTS oltp.contact_messages (
  message_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sender_name   VARCHAR(120) NOT NULL,
  sender_email  CITEXT NOT NULL,
  body          TEXT NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  handled_at    TIMESTAMPTZ,
  CONSTRAINT ck_contact_messages_name_present CHECK (btrim(sender_name) <> ''),
  CONSTRAINT ck_contact_messages_email_shape
    CHECK (sender_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  CONSTRAINT ck_contact_messages_body_length
    CHECK (char_length(btrim(body)) BETWEEN 1 AND 5000)
);

CREATE INDEX IF NOT EXISTS ix_contact_messages_created
  ON oltp.contact_messages (created_at DESC);
CREATE INDEX IF NOT EXISTS ix_contact_messages_sender
  ON oltp.contact_messages (sender_email, created_at);
