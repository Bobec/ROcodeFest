-- =====================================================================
-- QA — the notification layer
-- =====================================================================
-- Starting point (NOT retested here): T4 proved that on
-- submission_reviews a requires_resubmission = TRUE produces zero
-- notifications, and that the table carries no non-internal trigger.
-- This suite asks whether that absence is universal across all four
-- link tables, or partial.
--
-- WHY THIS LAYER: join requests, appeals, forum comments and judge
-- feedback all deliver through oltp.notifications. A defect here is not
-- one domain's problem, it is every domain's.
--
-- ---------------------------------------------------------------------
-- THE ORACLE RULE FOR THIS SUITE (the T4 trap, not to be repeated)
-- ---------------------------------------------------------------------
-- The failure mode is SILENCE. In T4 the leg "a FALSE review produces 0
-- notifications" came out green -- and proved nothing, because nothing
-- produces a notification under any condition. An existence oracle is
-- vacuous precisely when the absence is universal.
--
-- So every "0 notifications" claim below is paired with a POSITIVE that
-- actually delivers: a manual insert into notifications + the link
-- table. If that positive works, the zero is attributable to a missing
-- emitter. If it did not, the zero would only mean the plumbing is
-- broken, which is a different finding entirely.
--
--   psql -d qa_notif -f db/01_oltp_schema.sql
--   psql -d qa_notif -f db/qa_notifications.sql
-- =====================================================================

\set ON_ERROR_STOP on
\ir _qa_harness.sql
SELECT qa.suite('notifications');

-- ---------------------------------------------------------------------
-- Fixture: one live example of every domain that notifies
-- ---------------------------------------------------------------------
INSERT INTO oltp.accounts(email,password_hash,role) VALUES
  ('nc@t','x','club'), ('nm1@t','x','member'), ('nm2@t','x','member'), ('nj@t','x','judge');
INSERT INTO oltp.clubs(account_id,club_name)   SELECT account_id,'NC' FROM oltp.accounts WHERE email='nc@t';
INSERT INTO oltp.members(account_id,full_name) SELECT account_id,email FROM oltp.accounts WHERE role='member';
INSERT INTO oltp.judges(account_id,full_name)  SELECT account_id,'NJ' FROM oltp.accounts WHERE email='nj@t';
INSERT INTO oltp.teams(club_id,category_id,team_name,participation_code)
  SELECT c.account_id,tc.category_id,'NT','NT-1'
  FROM oltp.clubs c, oltp.team_categories tc WHERE tc.code='ROBOTICS';
INSERT INTO oltp.seasons(name,start_date) VALUES ('NS','2026-01-01');
INSERT INTO oltp.challenges(season_id,name,stage) SELECT season_id,'NCH','final' FROM oltp.seasons;
INSERT INTO oltp.matches(challenge_id,round_name,status) SELECT challenge_id,'NR1','completed' FROM oltp.challenges;
INSERT INTO oltp.match_teams(match_id,team_id) SELECT m.match_id,t.team_id FROM oltp.matches m, oltp.teams t;
INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id)
  SELECT t.team_id,c.challenge_id,'NS v1',a.account_id
  FROM oltp.teams t, oltp.challenges c, oltp.accounts a WHERE a.email='nm1@t';
INSERT INTO oltp.forum_categories(code,label) VALUES ('NGEN','General');
INSERT INTO oltp.forum_posts(category_id,author_account_id,title,body)
  SELECT fc.category_id,a.account_id,'A post','body'
  FROM oltp.forum_categories fc, oltp.accounts a WHERE fc.code='NGEN' AND a.email='nm1@t';


-- =====================================================================
-- N1 — the 4x3 matrix: does anything emit, on any link table?
-- =====================================================================
-- Columns: does a trigger exist on the SOURCE table / is it non-internal
-- / does a real domain event actually produce a notifications row.
CREATE TABLE qa.emitter_matrix(
  link_table   TEXT PRIMARY KEY,
  source_table TEXT,
  trg_any      INT,
  trg_noninternal INT,
  trg_notify   INT,   -- non-internal triggers that actually mention notifications
  event_fired  TEXT,
  rows_emitted INT
);

DO $$
DECLARE
  r RECORD;
  v_before INT; v_after INT;
  v_m1 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='nm1@t');
  v_m2 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='nm2@t');
  v_j  BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='nj@t');
  v_t  BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='NT-1');
  v_s  BIGINT := (SELECT submission_id FROM oltp.submissions LIMIT 1);
  v_p  BIGINT := (SELECT post_id FROM oltp.forum_posts LIMIT 1);
  v_mt BIGINT := (SELECT match_id FROM oltp.matches LIMIT 1);
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('notification_join_request_links',      'join_requests'),
      ('notification_appeal_links',            'appeals'),
      ('notification_forum_links',             'forum_comments'),
      ('notification_submission_review_links', 'submission_reviews')
    ) AS t(link, src)
  LOOP
    SELECT count(*) INTO v_before FROM oltp.notifications;

    -- fire a REAL domain event for this source
    IF r.src = 'join_requests' THEN
      INSERT INTO oltp.join_requests(member_id,team_id,status) VALUES (v_m2, v_t, 'pending');
    ELSIF r.src = 'appeals' THEN
      INSERT INTO oltp.appeals(team_id,filed_by_account_id,reason) VALUES (v_t, v_m1, 'matrix probe');
    ELSIF r.src = 'forum_comments' THEN
      INSERT INTO oltp.forum_comments(post_id,author_account_id,body) VALUES (v_p, v_m2, 'matrix probe');
    ELSE
      INSERT INTO oltp.submission_reviews(submission_id,judge_id,requires_resubmission,feedback)
        VALUES (v_s, v_j, TRUE, 'matrix probe');
    END IF;

    SELECT count(*) INTO v_after FROM oltp.notifications;

    INSERT INTO qa.emitter_matrix(link_table, source_table, trg_any, trg_noninternal, trg_notify, event_fired, rows_emitted)
    SELECT r.link, r.src,
      (SELECT count(*) FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid
        JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname='oltp' AND c.relname=r.src),
      (SELECT count(*) FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid
        JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname='oltp' AND c.relname=r.src AND NOT tg.tgisinternal),
      -- the precise question. A non-internal trigger is NOT necessarily
      -- an emitter: appeals carries trg_appeals_limit, which enforces the
      -- 3-rejected rule and has nothing to do with notifying anyone.
      -- Counting only "non-internal" would read as if appeals were
      -- partly wired up. It is not.
      (SELECT count(*) FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid
        JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname='oltp' AND c.relname=r.src AND NOT tg.tgisinternal
          AND pg_get_triggerdef(tg.oid) ILIKE '%notif%'),
      'yes', v_after - v_before;
  END LOOP;
END $$;

DO $$
DECLARE v_emitting INT; v_noninternal INT; v_total INT;
BEGIN
  SELECT count(*) FILTER (WHERE rows_emitted > 0),
         count(*) FILTER (WHERE trg_noninternal > 0),
         count(*)
    INTO v_emitting, v_noninternal, v_total FROM qa.emitter_matrix;

  PERFORM qa_pre('N1','N1 a real domain event fired for all four links',
    (SELECT count(*) FROM qa.emitter_matrix WHERE event_fired='yes') = 4,
    '4/4 source events inserted -- the matrix is worthless if the events never happened');

  PERFORM qa_gap('N1','N1-GAP the absence is UNIVERSAL, not partial',
    'is the missing emitter specific to submission_reviews, or the whole layer?',
    (SELECT string_agg(source_table||'='||rows_emitted, ', ' ORDER BY source_table) FROM qa.emitter_matrix),
    format('%s of %s link tables emitted a notification. %s of %s source tables carry a non-internal '
           ||'trigger. The defect T4 found on submission_reviews is not local -- NO domain event '
           ||'anywhere produces a notification. The four link tables are reachable only by an '
           ||'application that does not exist yet.',
           v_emitting, v_total, v_noninternal, v_total));

  PERFORM qa_note('N1','N1-NOTE what the matrix does and does not say',
    'scope of the finding',
    'The schema is not wrong -- notifications are modelled correctly and the link tables enforce '
    ||'their invariants. What is missing is the EMITTER. Whether that belongs in a trigger or in '
    ||'the service layer is a design decision; this suite only establishes that it exists nowhere '
    ||'today, so no caller can rely on it.');
END $$;


-- =====================================================================
-- N2 — the positives that make N1's zeros mean something
-- =====================================================================
-- Without these, "0 notifications" could equally mean the plumbing is
-- broken. Each one delivers manually, end to end, and reads back.
DO $$
DECLARE
  v_m1 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='nm1@t');
  v_n BIGINT; v_src BIGINT; v_read BIGINT;
BEGIN
  -- join request link
  SELECT request_id INTO v_src FROM oltp.join_requests ORDER BY request_id LIMIT 1;
  INSERT INTO oltp.notifications(recipient_account_id,title,body)
    VALUES (v_m1,'Join request','manual delivery') RETURNING notification_id INTO v_n;
  INSERT INTO oltp.notification_join_request_links(notification_id,event_type,join_request_id)
    VALUES (v_n,'join_request_received',v_src);
  SELECT join_request_id INTO v_read FROM oltp.notification_join_request_links WHERE notification_id=v_n;
  PERFORM qa_true('N2','N2 join-request delivery works when someone performs it',
    'the machinery is sound; only the automatic trigger is missing',
    v_read = v_src, 'notification '||v_n||' resolves to join_request '||v_read);

  -- appeal link
  SELECT appeal_id INTO v_src FROM oltp.appeals ORDER BY appeal_id LIMIT 1;
  INSERT INTO oltp.notifications(recipient_account_id,title)
    VALUES (v_m1,'Appeal decided') RETURNING notification_id INTO v_n;
  INSERT INTO oltp.notification_appeal_links(notification_id,event_type,appeal_id)
    VALUES (v_n,'appeal_accepted',v_src);
  SELECT appeal_id INTO v_read FROM oltp.notification_appeal_links WHERE notification_id=v_n;
  PERFORM qa_true('N2','N2 appeal delivery works when someone performs it',
    'same, for the appeals branch', v_read = v_src,
    'notification '||v_n||' resolves to appeal '||v_read);

  -- forum link
  SELECT comment_id INTO v_src FROM oltp.forum_comments ORDER BY comment_id LIMIT 1;
  INSERT INTO oltp.notifications(recipient_account_id,title)
    VALUES (v_m1,'New reply') RETURNING notification_id INTO v_n;
  INSERT INTO oltp.notification_forum_links(notification_id,event_type,forum_comment_id)
    VALUES (v_n,'reply_posted',v_src);
  SELECT forum_comment_id INTO v_read FROM oltp.notification_forum_links WHERE notification_id=v_n;
  PERFORM qa_true('N2','N2 forum delivery works when someone performs it',
    'same, for the forum branch', v_read = v_src,
    'notification '||v_n||' resolves to comment '||v_read);

  -- submission review link
  SELECT review_id INTO v_src FROM oltp.submission_reviews ORDER BY review_id LIMIT 1;
  INSERT INTO oltp.notifications(recipient_account_id,title)
    VALUES (v_m1,'Judge feedback') RETURNING notification_id INTO v_n;
  INSERT INTO oltp.notification_submission_review_links(notification_id,event_type,submission_review_id)
    VALUES (v_n,'judge_feedback_given',v_src);
  SELECT submission_review_id INTO v_read FROM oltp.notification_submission_review_links WHERE notification_id=v_n;
  PERFORM qa_true('N2','N2 judge-feedback delivery works when someone performs it',
    'the exact path T4 found silent -- proving the silence is the emitter, not the tables',
    v_read = v_src, 'notification '||v_n||' resolves to review '||v_read);

  PERFORM qa_true('N2','N2 all four branches delivered under manual control',
    'THIS is what makes N1''s four zeros attributable rather than vacuous',
    (SELECT count(*) FROM oltp.notifications) >= 4,
    (SELECT count(*)::text FROM oltp.notifications)||' notifications exist -- all created by this test, none by the schema');
END $$;


-- =====================================================================
-- N3 — the 30-minute buffer
-- =====================================================================
-- Specified for comments and replies: the app inserts with
-- notify_after = now() + interval '30 minutes' so a flurry inside the
-- window collapses into ONE delivered notification. A dispatch worker
-- sends only rows where notify_after <= now().
--
-- 99_tests checks only that a future-dated row is not yet due. The
-- collapsing -- the entire point of the rule -- is untested.
DO $$
DECLARE
  v_m1 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='nm1@t');
  v_m2 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='nm2@t');
  v_p  BIGINT := (SELECT post_id FROM oltp.forum_posts LIMIT 1);
  v_due INT; v_pending INT; v_burst INT; v_after INT; v_n BIGINT; i INT;
BEGIN
  -- ---- the dispatch predicate, both directions -------------------------
  INSERT INTO oltp.notifications(recipient_account_id,title,notify_after)
    VALUES (v_m1,'due now', now() - interval '1 minute');
  SELECT count(*) INTO v_due FROM oltp.notifications
   WHERE title='due now' AND notify_after <= now();
  PERFORM qa_true('N3','N3 a past-dated notification IS due',
    'the positive half: the dispatch predicate must select something, or "not due" proves nothing',
    v_due = 1, v_due||' row(s) selected by notify_after <= now()');

  INSERT INTO oltp.notifications(recipient_account_id,title,notify_after)
    VALUES (v_m1,'buffered', now() + interval '30 minutes');
  SELECT count(*) INTO v_pending FROM oltp.notifications
   WHERE title='buffered' AND notify_after <= now();
  PERFORM qa_true('N3','N3 a buffered notification is NOT yet due',
    'paired with the row above, so the zero is a schedule and not an empty table',
    v_pending = 0, 'held back by 30 minutes');

  -- ---- the burst: five replies inside one window -----------------------
  FOR i IN 1..5 LOOP
    INSERT INTO oltp.forum_comments(post_id,author_account_id,body)
      VALUES (v_p, v_m2, 'burst reply '||i);
  END LOOP;

  SELECT count(*) INTO v_burst FROM oltp.forum_comments WHERE body LIKE 'burst reply%';
  PERFORM qa_pre('N3','N3 five replies landed inside one window', v_burst = 5,
    v_burst||' replies within seconds of each other -- a collapsing test needs something to collapse');

  -- Nothing emits, so the honest measurement is of the MECHANISM: if the
  -- app created one notification per reply, would anything stop it?
  FOR i IN 1..5 LOOP
    INSERT INTO oltp.notifications(recipient_account_id,title,body,notify_after)
      VALUES (v_m1,'reply on your post','burst '||i, now() + interval '30 minutes');
  END LOOP;
  SELECT count(*) INTO v_after FROM oltp.notifications WHERE title='reply on your post';

  PERFORM qa_gap('N3','N3-GAP nothing collapses a burst',
    'five events in the window must yield one notification, not five',
    format('the paired positive above proves delivery works, so these %s rows are real deliveries', v_after),
    format('%s separate notifications were accepted for %s replies to the same post, same recipient, '
           ||'all inside the 30-minute window. There is no unique constraint, no partial index and no '
           ||'trigger on (recipient_account_id, source) to prevent it. The recipient would receive %s '
           ||'messages where the rule specifies one.', v_after, v_burst, v_after));

  -- ---- but collapsing IS expressible: prove it, so the gap is
  --      "not automated" and not "not possible"
  DELETE FROM oltp.notifications WHERE title='reply on your post';
  INSERT INTO oltp.notifications(recipient_account_id,title,body,notify_after)
    VALUES (v_m1,'collapsed','first reply', now() + interval '30 minutes')
    RETURNING notification_id INTO v_n;
  FOR i IN 2..5 LOOP
    UPDATE oltp.notifications
       SET body = 'replies so far: '||i, notify_after = now() + interval '30 minutes'
     WHERE notification_id = v_n;
  END LOOP;
  SELECT count(*) INTO v_after FROM oltp.notifications WHERE title='collapsed';
  PERFORM qa_true('N3','N3 collapsing works when the caller does it',
    'reschedule-in-place is available; only the automation is missing',
    v_after = 1 AND (SELECT body FROM oltp.notifications WHERE notification_id=v_n) = 'replies so far: 5',
    'one row, rescheduled four times, body reflects the whole burst');
END $$;


-- =====================================================================
-- N4 — is the buffer itself constrained, or only a convention?
-- =====================================================================
DO $$
DECLARE
  v_m1 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='nm1@t');
  v_ck INT; v_cols TEXT;
BEGIN
  SELECT count(*) INTO v_ck FROM pg_constraint
   WHERE conrelid='oltp.notifications'::regclass AND contype='c'
     AND pg_get_constraintdef(oid) ILIKE '%notify_after%';
  PERFORM qa_gap('N4','N4-GAP notify_after is unconstrained',
    'is the 30-minute window enforceable, or only documented?',
    format('%s CHECK constraint(s) mention notify_after', v_ck),
    'Any value is accepted -- the past, or years ahead. The "30 minutes" lives in a comment and in '
    ||'whatever the caller passes. A CHECK cannot express it either, since the correct delay depends '
    ||'on the event type; it belongs to the emitter, which is the same missing piece as N1.');

  PERFORM qa_accept('N4','N4 a notification 5 years out is accepted',
    format('INSERT INTO oltp.notifications(recipient_account_id,title,notify_after) VALUES (%s,''far future'', now() + interval ''5 years'')', v_m1));
  PERFORM qa_accept('N4','N4 a notification dated in the past is accepted',
    format('INSERT INTO oltp.notifications(recipient_account_id,title,notify_after) VALUES (%s,''backdated'', now() - interval ''1 year'')', v_m1));

  SELECT string_agg(column_name,', ' ORDER BY ordinal_position) INTO v_cols
    FROM information_schema.columns
   WHERE table_schema='oltp' AND table_name='notifications';
  PERFORM qa_gap('N4','N4-GAP delivery is unobservable',
    'can anyone tell whether a due notification was actually sent?',
    'columns: '||v_cols,
    'There is no sent_at / delivered_at. is_read records that the RECIPIENT acted, not that the '
    ||'system delivered. So "due" and "delivered" are indistinguishable: a dispatch worker that '
    ||'silently stopped would look exactly like a quiet week. For a delivery layer whose failure '
    ||'mode is silence, that is the observability gap that matters most.');
END $$;


-- =====================================================================
-- Report
-- =====================================================================
\echo ''
\echo '============ N1: EMITTER MATRIX (4 x 3) ============'
SELECT link_table, source_table,
       trg_any         AS "triggers on source",
       trg_noninternal AS "non-internal",
       trg_notify      AS "notification emitters",
       event_fired     AS "event fired",
       rows_emitted    AS "notifications produced"
FROM qa.emitter_matrix ORDER BY link_table;

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
