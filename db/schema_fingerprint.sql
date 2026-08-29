-- =====================================================================
-- A canonical description of this database's structure
-- =====================================================================
-- Printed as sorted text so two databases can be compared with `diff`.
--
-- WHY NOT pg_dump --schema-only
-- -----------------------------
-- pg_dump emits statements in dependency order, which is stable for one
-- database and not between two built different ways -- so a textual diff
-- of two dumps is full of differences that are only ordering. This asks
-- the catalogue instead and sorts everything, so a difference in the
-- output is a difference in the schema.
--
-- WHAT IS DELIBERATELY NOT HERE
-- -----------------------------
--   * row data -- app.schema_migrations holds different rows depending
--     on how the database was built, and that is expected: a migrated
--     database records checksums, a from-scratch one records NULLs
--   * object OIDs and sequence positions, which differ by construction
--   * comments, which are documentation rather than structure
--
-- USED BY: the `migrations` job in .github/workflows/qa.yml, which
-- builds one database the from-scratch way and another by migrating the
-- previous commit's schema forward, then diffs these two outputs.
-- =====================================================================

\pset pager off
\pset tuples_only on
\pset format unaligned

-- Enum types and their labels, in declaration order -- adding a value in
-- the wrong position is a real difference.
SELECT 'ENUM    ' || n.nspname || '.' || t.typname || ' = ' ||
       string_agg(e.enumlabel, ',' ORDER BY e.enumsortorder)
  FROM pg_type t
  JOIN pg_namespace n ON n.oid = t.typnamespace
  JOIN pg_enum e      ON e.enumtypid = t.oid
 WHERE n.nspname IN ('app', 'oltp', 'analytics')
 GROUP BY n.nspname, t.typname
 ORDER BY 1;

-- Columns: name, type, nullability, default. The default is included
-- because a column that gained one is a different column.
SELECT 'COLUMN  ' || c.table_schema || '.' || c.table_name || '.' || c.column_name ||
       ' :: ' || c.data_type ||
       coalesce('(' || c.character_maximum_length || ')', '') ||
       ' null=' || c.is_nullable ||
       ' default=' || coalesce(regexp_replace(c.column_default, '::[a-z_ ]+', '', 'g'), '-')
  FROM information_schema.columns c
 WHERE c.table_schema IN ('app', 'oltp', 'analytics')
 ORDER BY 1;

-- Constraints by definition rather than by name alone: two constraints
-- can share a name across tables, and a CHECK whose expression changed
-- keeps its name.
SELECT 'CONSTR  ' || n.nspname || '.' || rel.relname || ' ' || con.conname ||
       ' = ' || pg_get_constraintdef(con.oid)
  FROM pg_constraint con
  JOIN pg_class rel     ON rel.oid = con.conrelid
  JOIN pg_namespace n   ON n.oid = rel.relnamespace
 WHERE n.nspname IN ('app', 'oltp', 'analytics')
 ORDER BY 1;

-- Indexes, definition and all. Partial indexes carry their WHERE clause
-- here, which is how uq_seasons_single_active differs from a plain
-- unique index.
SELECT 'INDEX   ' || schemaname || '.' || tablename || ' ' || indexname || ' = ' || indexdef
  FROM pg_indexes
 WHERE schemaname IN ('app', 'oltp', 'analytics')
 ORDER BY 1;

-- Triggers with the function they call. A trigger pointing at a
-- different function is a different trigger.
SELECT 'TRIGGER ' || n.nspname || '.' || rel.relname || ' ' || tg.tgname ||
       ' -> ' || p.proname
  FROM pg_trigger tg
  JOIN pg_class rel   ON rel.oid = tg.tgrelid
  JOIN pg_namespace n ON n.oid = rel.relnamespace
  JOIN pg_proc p      ON p.oid = tg.tgfoid
 WHERE n.nspname IN ('app', 'oltp', 'analytics')
   AND NOT tg.tgisinternal
 ORDER BY 1;

-- Function bodies. A trigger that still points at the right function
-- while the function itself changed would otherwise slip through, and
-- most of this schema's rules live in those bodies.
SELECT 'FUNC    ' || n.nspname || '.' || p.proname || ' = ' ||
       md5(pg_get_functiondef(p.oid))
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname IN ('app', 'oltp', 'analytics')
 ORDER BY 1;

-- Views, by the definition Postgres normalises them to.
SELECT 'VIEW    ' || schemaname || '.' || viewname || ' = ' || md5(definition)
  FROM pg_views
 WHERE schemaname IN ('app', 'oltp', 'analytics')
 ORDER BY 1;
