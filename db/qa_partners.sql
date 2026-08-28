-- =====================================================================
-- QA — partners
-- =====================================================================
-- The least-tested domain in the schema: before this file, the whole
-- ledger contained ONE case mentioning partners, and it was about a
-- view's provenance rather than about partners at all.
--
-- The table is small, and that is the point. oltp.partners has:
--   * one FK, to accounts
--   * ZERO foreign keys pointing at it
-- so it is a leaf. Nothing in the database can say which club a sponsor
-- supports, which season they backed, or what a mentor mentored. Group Q
-- is about what that costs; group P is about whether the little the
-- table does claim actually holds.
--
-- The subtype rule it shares with members, clubs and judges turns out to
-- be enforceable from one side only. That finding is recorded here
-- because partners is where it was found, but it is NOT a partners
-- defect -- see P3.
--
--   psql -d qa_pt -f db/01_oltp_schema.sql
--   psql -d qa_pt -f db/qa_partners.sql
-- =====================================================================

\set ON_ERROR_STOP on
\ir _qa_harness.sql
SELECT qa.suite('partners');

-- ---------------------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------------------
INSERT INTO oltp.accounts(email,password_hash,role) VALUES
  ('pt-sponsor@t','x','partner'),   -- the ordinary case
  ('pt-spare@t','x','partner'),     -- a partner account with no row yet
  ('pt-drift@t','x','partner'),     -- P3 changes this one's role underneath
  ('pt-doomed@t','x','partner'),    -- P5 deletes this one's account
  ('pt-member@t','x','member'),     -- the wrong role, for the negatives
  ('pt-club@t','x','club');
INSERT INTO oltp.clubs(account_id,club_name)
  SELECT account_id,'PtClub' FROM oltp.accounts WHERE email='pt-club@t';
INSERT INTO oltp.members(account_id,full_name)
  SELECT account_id,'PtMember' FROM oltp.accounts WHERE email='pt-member@t';


-- =====================================================================
-- P — the partner record
-- =====================================================================
DO $$
DECLARE
  v_sponsor BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='pt-sponsor@t');
  v_spare   BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='pt-spare@t');
  v_drift   BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='pt-drift@t');
  v_member  BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='pt-member@t');
  v_bare BIGINT; v_n INT;
BEGIN
  -- P1 the subtype rule, on INSERT
  PERFORM qa_pre('P','P1 two accounts differing only in role',
    (SELECT role FROM oltp.accounts WHERE account_id=v_spare)::text = 'partner'
    AND (SELECT role FROM oltp.accounts WHERE account_id=v_member)::text = 'member',
    format('account %s is a partner, account %s is a member', v_spare, v_member));
  PERFORM qa_pair('P','P1 only an account with role=partner may have a partner record',
    'enforce_subtype_role(''partner'') -- identical inserts differing only in the account''s role',
    format('INSERT INTO oltp.partners(account_id,contact_name,partner_type) VALUES (%s,''Spare Contact'',''sponsor'')', v_spare),
    format('INSERT INTO oltp.partners(account_id,contact_name,partner_type) VALUES (%s,''Wrong Role'',''sponsor'')', v_member));

  INSERT INTO oltp.partners(account_id,org_name,contact_name,partner_type,message)
    VALUES (v_sponsor,'Acme Robotics SRL','Ana Contact','sponsor','glad to support');

  PERFORM qa_true('P','P1 the record reads back exactly as written',
    'the ordinary path, asserted so the negatives above are not the only thing exercised',
    (SELECT org_name='Acme Robotics SRL' AND contact_name='Ana Contact'
            AND partner_type::text='sponsor' AND created_at IS NOT NULL
       FROM oltp.partners WHERE account_id=v_sponsor),
    (SELECT format('%s / %s / %s', org_name, contact_name, partner_type)
       FROM oltp.partners WHERE account_id=v_sponsor));

  -- P2 the rule is re-checked on UPDATE, not only at insert time
  PERFORM qa_pair('P','P2 a partner record cannot be moved onto a non-partner account',
    'the trigger is BEFORE INSERT OR UPDATE, so re-pointing the row is checked too',
    format('UPDATE oltp.partners SET contact_name=''Ana Contact (renamed)'' WHERE account_id=%s', v_sponsor),
    format('UPDATE oltp.partners SET account_id=%s WHERE account_id=%s', v_member, v_sponsor));

  -- P3 THE ONE THAT MATTERS: the invariant has an unguarded side ------
  --
  -- enforce_subtype_role sits on the SUBTYPE tables. Nothing sits on
  -- accounts.role, so the pair can be broken from the other end -- and
  -- the row that results is exactly the one P1 and P2 exist to refuse.
  INSERT INTO oltp.partners(account_id,contact_name,partner_type)
    VALUES (v_drift,'Drift Contact','mentor');
  PERFORM qa_pre('P','P3 a valid partner record exists',
    EXISTS (SELECT 1 FROM oltp.partners p JOIN oltp.accounts a USING (account_id)
             WHERE p.account_id=v_drift AND a.role='partner'),
    'account '||v_drift||' is a partner and has a partner record -- the pair is currently consistent');

  -- Was P3-GAP: enforce_subtype_role fired on all four subtype tables but
  -- accounts.role had no trigger of its own, so changing the role left the
  -- subtype row attached and the database ended up holding precisely the
  -- shape its own trigger exists to reject -- silently, because nothing
  -- re-checked the pair afterwards. The account could then carry a members
  -- row as well, making one identity two subtypes at once.
  --
  -- R8 closed the other side. The control is an account with nothing
  -- attached, which still changes role freely: this is a guard, not a
  -- freeze.
  -- a bare account for the control: pt-spare@t received a partner record
  -- from P1's own control, so it is no longer "nothing attached"
  INSERT INTO oltp.accounts(email,password_hash,role) VALUES ('pt-bare@t','x','partner')
    RETURNING account_id INTO v_bare;
  PERFORM qa_pre('P','P3 one account has a partner record, one has nothing attached',
    EXISTS (SELECT 1 FROM oltp.partners WHERE account_id=v_drift)
    AND NOT EXISTS (SELECT 1 FROM oltp.partners WHERE account_id=v_bare),
    format('account %s holds a partner record; account %s holds none', v_drift, v_bare));
  PERFORM qa_pair('P','P3 an account cannot change role while a subtype record exists',
    'enforce_role_change_has_no_subtype -- the invariant now holds from BOTH sides',
    format('UPDATE oltp.accounts SET role=''judge'' WHERE account_id=%s', v_bare),
    format('UPDATE oltp.accounts SET role=''member'' WHERE account_id=%s', v_drift));

  PERFORM qa_accept('P','P3 removing the record first makes the change possible',
    format('DELETE FROM oltp.partners WHERE account_id=%s; '
           ||'UPDATE oltp.accounts SET role=''member'' WHERE account_id=%s', v_drift, v_drift));

  PERFORM qa_true('P','P3 no mismatched pair exists anywhere',
    'the shape enforce_subtype_role refuses on one side is now unreachable on both',
    (SELECT count(*) FROM (
       SELECT 1 FROM oltp.members  s JOIN oltp.accounts a USING (account_id) WHERE a.role <> 'member'
       UNION ALL
       SELECT 1 FROM oltp.clubs    s JOIN oltp.accounts a USING (account_id) WHERE a.role <> 'club'
       UNION ALL
       SELECT 1 FROM oltp.judges   s JOIN oltp.accounts a USING (account_id) WHERE a.role <> 'judge'
       UNION ALL
       SELECT 1 FROM oltp.partners s JOIN oltp.accounts a USING (account_id) WHERE a.role <> 'partner'
     ) x) = 0,
    'members, clubs, judges and partners all agree with their accounts');

  -- restore, so later groups start from a consistent fixture
  UPDATE oltp.accounts SET role='partner' WHERE account_id=v_drift;
  UPDATE oltp.accounts SET role='partner' WHERE account_id=v_spare;

  -- P4 one partner record per account
  PERFORM qa_pre('P','P4 the sponsor already has a record',
    EXISTS (SELECT 1 FROM oltp.partners WHERE account_id=v_sponsor),
    'so the duplicate below has something to collide with');
  PERFORM qa_pair('P','P4 an account cannot hold two partner records',
    'account_id is the primary key -- the account IS the partner identity',
    format('INSERT INTO oltp.partners(account_id,contact_name,partner_type) VALUES (%s,''Second Contact'',''vendor'')', v_drift),
    format('INSERT INTO oltp.partners(account_id,contact_name,partner_type) VALUES (%s,''Duplicate'',''vendor'')', v_sponsor));
END $$;

DO $$
DECLARE
  v_doomed BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='pt-doomed@t');
  v_before INT; v_after INT;
BEGIN
  -- P5 the account is the owner, and the cascade says so
  INSERT INTO oltp.partners(account_id,contact_name,partner_type)
    VALUES (v_doomed,'Doomed Contact','speaker');
  SELECT count(*) INTO v_before FROM oltp.partners WHERE account_id=v_doomed;
  PERFORM qa_pre('P','P5 the doomed account has a partner record', v_before = 1,
    'so the cascade has something to remove');

  DELETE FROM oltp.accounts WHERE account_id=v_doomed;
  SELECT count(*) INTO v_after FROM oltp.partners WHERE account_id=v_doomed;
  PERFORM qa_true('P','P5 deleting the account removes the partner record',
    'ON DELETE CASCADE -- the partner has no existence apart from its account',
    v_after = 0, format('%s -> %s partner row(s)', v_before, v_after));
END $$;

DO $$
DECLARE
  v_spare2 BIGINT;
  v_t TEXT;
BEGIN
  -- P6 the required fields
  INSERT INTO oltp.accounts(email,password_hash,role) VALUES ('pt-req@t','x','partner')
    RETURNING account_id INTO v_spare2;
  PERFORM qa_pair('P','P6 contact_name is required',
    'a partner with nobody to contact is not a usable record',
    format('INSERT INTO oltp.partners(account_id,contact_name,partner_type) VALUES (%s,''Has Contact'',''other'')', v_spare2),
    'INSERT INTO oltp.partners(account_id,contact_name,partner_type) '
      ||'SELECT account_id,NULL,''other'' FROM oltp.accounts WHERE email=''pt-spare@t''');

  PERFORM qa_reject('P','P6 partner_type is required',
    'INSERT INTO oltp.partners(account_id,contact_name,partner_type) '
      ||'SELECT account_id,''No Type'',NULL FROM oltp.accounts WHERE email=''pt-drift@t''',
    '23502');

  -- P7 the enum: every declared value is usable, and only those
  PERFORM qa_true('P','P7 partner_type declares five kinds of partner',
    'the enum is the whole vocabulary, so the suite should know its size',
    (SELECT count(*) FROM pg_enum e JOIN pg_type t ON t.oid=e.enumtypid
      WHERE t.typname='partner_type') = 5,
    (SELECT string_agg(e.enumlabel,', ' ORDER BY e.enumsortorder)
       FROM pg_enum e JOIN pg_type t ON t.oid=e.enumtypid WHERE t.typname='partner_type'));

  FOR v_t IN SELECT e.enumlabel FROM pg_enum e JOIN pg_type t ON t.oid=e.enumtypid
             WHERE t.typname='partner_type' ORDER BY e.enumsortorder
  LOOP
    INSERT INTO oltp.accounts(email,password_hash,role) VALUES ('pt-type-'||v_t||'@t','x','partner');
    EXECUTE format('INSERT INTO oltp.partners(account_id,contact_name,partner_type) '
                   ||'SELECT account_id,''Contact %s'',%L FROM oltp.accounts WHERE email=%L',
                   v_t, v_t, 'pt-type-'||v_t||'@t');
  END LOOP;
  PERFORM qa_true('P','P7 every declared partner_type is actually insertable',
    'an enum value nobody can use is a value that does not exist',
    (SELECT count(DISTINCT partner_type) FROM oltp.partners) = 5,
    (SELECT string_agg(DISTINCT partner_type::text,', ' ORDER BY partner_type::text) FROM oltp.partners));

  PERFORM qa_reject('P','P7 a type outside the enum is refused',
    'INSERT INTO oltp.partners(account_id,contact_name,partner_type) '
      ||'SELECT account_id,''Bad Type'',''platinum'' FROM oltp.accounts WHERE email=''pt-spare@t''',
    '22P02');
END $$;


-- ---------------------------------------------------------------------
-- P3b — the fix is a CLASS fix, evidenced rather than asserted
-- ---------------------------------------------------------------------
-- This block used to prove the OMISSION was the same on all four subtype
-- tables, by drifting all four and counting -- because saying so from
-- reading the schema is not the same as showing it, and this suite has
-- already been wrong once about what a catalogue query implies (see
-- qa_lifecycle's note on partial unique indexes).
--
-- R8 closed it with ONE trigger on accounts. The same loop now proves the
-- opposite, and proves it the same way: reading the CASE expression and
-- concluding "it handles all four" is exactly the reasoning that was
-- wrong before.
DO $$
DECLARE
  v_pairs TEXT[][] := ARRAY[['members','member'],['clubs','club'],
                            ['judges','judge'],['partners','partner']];
  v_tbl TEXT; v_role TEXT; v_id BIGINT; v_held INT := 0; v_which TEXT := '';
  v_drifted BOOLEAN;
BEGIN
  FOR i IN 1..array_length(v_pairs,1) LOOP
    v_tbl := v_pairs[i][1]; v_role := v_pairs[i][2];
    INSERT INTO oltp.accounts(email,password_hash,role)
      VALUES ('pt-drift-'||v_tbl||'@t','x',v_role::oltp.account_role)
      RETURNING account_id INTO v_id;

    -- each subtype table needs its own required columns
    EXECUTE CASE v_tbl
      WHEN 'members'  THEN format('INSERT INTO oltp.members(account_id,full_name) VALUES (%s,''Drift'')', v_id)
      WHEN 'clubs'    THEN format('INSERT INTO oltp.clubs(account_id,club_name) VALUES (%s,''Drift Club %s'')', v_id, v_id)
      WHEN 'judges'   THEN format('INSERT INTO oltp.judges(account_id,full_name) VALUES (%s,''Drift'')', v_id)
      WHEN 'partners' THEN format('INSERT INTO oltp.partners(account_id,contact_name,partner_type) VALUES (%s,''Drift'',''other'')', v_id)
    END;

    -- try to walk the role out from under the subtype row
    BEGIN
      EXECUTE format('UPDATE oltp.accounts SET role = %L WHERE account_id = %s',
                     CASE WHEN v_role='member' THEN 'judge' ELSE 'member' END, v_id);
      v_drifted := TRUE;    -- it went through: still open on this table
    EXCEPTION WHEN others THEN
      v_drifted := FALSE;   -- refused: closed on this table
    END;

    IF NOT v_drifted THEN
      v_held := v_held + 1;
      v_which := v_which || CASE WHEN v_which = '' THEN '' ELSE ', ' END || v_tbl;
    END IF;
  END LOOP;

  PERFORM qa_true('P','P3b the guard covers ALL FOUR subtype tables',
    'the difference between "partners is fixed" and "the subtype pattern is fixed" -- '
    ||'one trigger on accounts stands in for four, and that claim needs showing',
    v_held = 4,
    format('%s of 4 subtype tables refused the role change: %s', v_held, v_which));

  PERFORM qa_true('P','P3b the refusal cost nothing else',
    'a guard that rolled back more than the UPDATE would satisfy the count above too',
    (SELECT count(*) FROM oltp.accounts WHERE email LIKE 'pt-drift-%') = 4,
    'all four drift accounts still stand, each with its original role and subtype row');
END $$;


-- =====================================================================
-- Q — what the model cannot say about a partner
-- =====================================================================
-- Group P showed the table holds what it claims. This group is about the
-- claims it never makes -- and for a festival that exists partly on
-- sponsorship, they are the ones a reader would expect.
-- =====================================================================
DO $$
DECLARE v_out INT; v_in INT; v_org INT;
BEGIN
  -- Q1 the identity is inverted for an organisation
  SELECT count(*) INTO v_org FROM oltp.partners
   WHERE partner_type IN ('sponsor','vendor') AND org_name IS NULL;
  PERFORM qa_pre('Q','Q1 an organisation-type partner exists with no organisation named',
    v_org >= 1,
    format('%s sponsor/vendor record(s) carry org_name = NULL', v_org));
  PERFORM qa_gap('Q','Q1-GAP a sponsor need not name the organisation it sponsors on behalf of',
    'which field is the partner -- the person or the organisation?',
    format('contact_name is NOT NULL and org_name is nullable, so %s sponsor/vendor row(s) name a '
           ||'person and no organisation; P1 showed the insert path itself works, so this is the '
           ||'shape of the record and not a broken write', v_org),
    'For a speaker or a mentor the person IS the partner and a NULL org_name is right. For a '
    ||'sponsor or a vendor the organisation is the partner and the contact is a person at it, so '
    ||'the two columns are the wrong way round for exactly the types that matter most to a '
    ||'festival''s finances. The rule is conditional on partner_type and is expressible as a '
    ||'one-row CHECK: org_name IS NOT NULL for sponsor and vendor, free for the rest. Whether '
    ||'those are the right two types is a business call; that the constraint is currently absent '
    ||'for all five is not.');

  -- Q2 the leaf problem
  SELECT count(*) INTO v_out FROM pg_constraint
   WHERE conrelid='oltp.partners'::regclass AND contype='f';
  SELECT count(*) INTO v_in FROM pg_constraint WHERE confrelid='oltp.partners'::regclass;
  PERFORM qa_true('Q','Q2-FIXTURE partners is a leaf in the schema graph',
    'the structural fact the finding below rests on',
    v_out = 1 AND v_in = 0,
    format('%s FK out (to accounts), %s FKs in', v_out, v_in));

  PERFORM qa_gap('Q','Q2-GAP nothing connects a partner to what they support',
    'can the database answer "which clubs does this sponsor back?"',
    format('partners has %s outgoing FK and %s incoming; every other participant in this schema '
           ||'is reachable from the work it does -- a team through match_teams, a judge through '
           ||'match_judges, a member through memberships', v_out, v_in),
    'A partner is stored and then disconnected. There is no sponsorship table, no partner_id on '
    ||'clubs, teams, seasons or challenges, so "which clubs does Acme back", "who sponsored the '
    ||'2026 season" and "what did this vendor supply" are all unanswerable from the data. The '
    ||'consequence is visible two layers up: analytics.vw_partner_dashboard and '
    ||'vw_partner_club_summary both carry "partner" in their names and neither references the '
    ||'table -- they cannot, because there is no join to make. They return EVERY club to EVERY '
    ||'partner. A junction at the (partner, club, season) grain would be the smallest thing that '
    ||'makes the two views mean what their names say.');

  -- Q3 the identity is single-valued, and that has a cost
  INSERT INTO oltp.accounts(email,password_hash,role) VALUES ('pt-realclub@t','x','club');
  PERFORM qa_pre('Q','Q3 one partner account and one club account, neither with a club row yet',
    (SELECT role FROM oltp.accounts WHERE email='pt-sponsor@t')::text = 'partner'
    AND (SELECT role FROM oltp.accounts WHERE email='pt-realclub@t')::text = 'club'
    AND NOT EXISTS (SELECT 1 FROM oltp.clubs c JOIN oltp.accounts a USING (account_id)
                     WHERE a.email IN ('pt-sponsor@t','pt-realclub@t')),
    'so the two inserts below differ in exactly one thing: the role of the account they name');
  PERFORM qa_pair('Q','Q3 a partner account cannot also be a club',
    'accounts.role is a single enum value, not a set -- so one identity fills one role',
    'INSERT INTO oltp.clubs(account_id,club_name) '
      ||'SELECT account_id,''A genuine club'' FROM oltp.accounts WHERE email=''pt-realclub@t''',
    'INSERT INTO oltp.clubs(account_id,club_name) '
      ||'SELECT account_id,''Sponsor''''s own club'' FROM oltp.accounts WHERE email=''pt-sponsor@t''');
  PERFORM qa_note('Q','Q3-NOTE one identity, one role',
    'a consequence to be aware of, not a defect',
    'accounts.role holds one value, and enforce_subtype_role keeps the subtype table matching it. '
    ||'A company that both sponsors the festival and enters a team of its own therefore needs two '
    ||'accounts with two email addresses, and nothing records that they are the same organisation. '
    ||'That is a defensible model -- roles as accounts is simpler than roles as a set -- but it is '
    ||'a choice, and P3 shows the enforcement behind it is one-sided.');

  -- Q4 no lifecycle, no season
  PERFORM qa_true('Q','Q4-FIXTURE the partner record has no lifecycle column',
    'the finding below is about absent columns, so it must be stated as an absence',
    NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='oltp' AND table_name='partners'
                   AND column_name IN ('is_active','season_id','ended_at','valid_from')),
    (SELECT 'partners holds: '||string_agg(column_name,', ' ORDER BY ordinal_position)
       FROM information_schema.columns
      WHERE table_schema='oltp' AND table_name='partners'));

  PERFORM qa_gap('Q','Q4-GAP a partner is permanent and season-less',
    'is this sponsor still a sponsor?',
    'the column list above carries created_at and nothing else about time; accounts.is_active '
    ||'exists but describes the login, not the sponsorship',
    'Sponsorship is renewed or dropped every year, and the record cannot express either. There is '
    ||'no season_id, so "the sponsors of the 2026 festival" is not a query; and no is_active or '
    ||'ended_at, so a partner from a season that has finished is indistinguishable from a current '
    ||'one. Every other seasonal thing in this schema -- challenges, certificates -- carries a '
    ||'season_id. Deactivating the ACCOUNT is not a substitute: it would remove their login rather '
    ||'than end the sponsorship, and the two are different facts. This compounds with Q2: a '
    ||'junction at (partner, club, season) would close both at once, which is an argument for '
    ||'treating them as one decision.');
END $$;


-- =====================================================================
-- Report
-- =====================================================================
\echo ''
\echo '===================== RESULTS ====================='
SELECT seq, grp, status, kind, tc, intent FROM qa.results ORDER BY seq;
\echo ''
\echo '--- control + result, per case ---'
SELECT seq, grp, status, control, result FROM qa.results ORDER BY seq;
\echo ''
SELECT * FROM qa_summary();
\echo ''
\echo '--- harness lint (method hygiene, not schema findings) ---'
SELECT * FROM qa_lint();
\echo ''
\echo '========== SCHEMA GAPS DISCOVERED =========='
SELECT seq, grp, tc, result FROM qa.results WHERE status='GAP' ORDER BY seq;
SELECT qa_finish();
