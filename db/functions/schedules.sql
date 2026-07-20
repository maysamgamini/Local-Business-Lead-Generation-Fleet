-- schedules.sql — campaign scheduler (Ops Console feature #4).
-- schedule_campaign(): clone a source campaign's config into a schedule (template + cadence).
-- cancel_campaign_schedule(): pause a schedule.
-- fire_due_schedules(): the engine — the Scheduler workflow calls this hourly; it launches every
--   due schedule via create_campaign (trigger_source='schedule') in ONE transaction and advances
--   next_run_at (weekly +7d / monthly +1mo / once -> disabled). SECURITY DEFINER; nested
--   create_campaign runs as owner. Console role gets EXECUTE + SELECT (granted in the deploy).

CREATE OR REPLACE FUNCTION @@SCHEMA@@.schedule_campaign(
  p_source_campaign_id uuid, p_cadence text,
  p_next_run_at timestamptz DEFAULT NULL, p_label text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE c campaigns; v_template jsonb; v_next timestamptz; v_id uuid;
BEGIN
  IF p_cadence NOT IN ('once','weekly','monthly') THEN
    RAISE EXCEPTION 'invalid_cadence' USING ERRCODE='P0001';
  END IF;
  SELECT * INTO c FROM campaigns WHERE id = p_source_campaign_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown_campaign' USING ERRCODE='P0001'; END IF;

  v_template := jsonb_build_object(
    'schema_version','1.0', 'business_type', c.business_type, 'depth', c.depth,
    'volume_cap', c.volume_cap,
    'budget', jsonb_build_object('amount', c.budget_cap_usd, 'currency','USD'));
  IF c.target IS NOT NULL THEN
    v_template := v_template || jsonb_build_object('target', c.target);
  ELSE
    v_template := v_template || jsonb_build_object('geo', c.geo_original);
  END IF;

  v_next := coalesce(p_next_run_at, now() + CASE p_cadence
              WHEN 'weekly' THEN interval '7 days'
              WHEN 'monthly' THEN interval '1 month'
              ELSE interval '1 hour' END);

  INSERT INTO campaign_schedules
    (caller_identity, label, template, cadence, next_run_at, source_campaign_id)
  VALUES
    (c.caller_identity, coalesce(nullif(p_label,''), c.business_type),
     v_template, p_cadence, v_next, c.id)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok', true, 'schedule_id', v_id,
    'next_run_at', v_next, 'cadence', p_cadence);
END $$;

CREATE OR REPLACE FUNCTION @@SCHEMA@@.cancel_campaign_schedule(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
BEGIN
  UPDATE campaign_schedules SET enabled = false WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown_schedule' USING ERRCODE='P0001'; END IF;
  RETURN jsonb_build_object('ok', true, 'schedule_id', p_id);
END $$;

CREATE OR REPLACE FUNCTION @@SCHEMA@@.fire_due_schedules()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE r record; v_fired int := 0; v_req jsonb; v_camp uuid; v_status text;
BEGIN
  FOR r IN SELECT * FROM campaign_schedules
             WHERE enabled AND next_run_at <= now()
             ORDER BY next_run_at
             FOR UPDATE SKIP LOCKED LOOP
    v_req := r.template || jsonb_build_object(
      'request_id', 'sched-' || r.id || '-' || extract(epoch from now())::bigint);
    SELECT campaign_id, creation_status INTO v_camp, v_status
      FROM create_campaign(v_req, r.caller_identity, 'schedule');
    UPDATE campaign_schedules SET
      last_run_at = now(), last_campaign_id = v_camp, run_count = run_count + 1,
      enabled = CASE WHEN r.cadence = 'once' THEN false ELSE enabled END,
      next_run_at = CASE r.cadence
                      WHEN 'weekly'  THEN next_run_at + interval '7 days'
                      WHEN 'monthly' THEN next_run_at + interval '1 month'
                      ELSE next_run_at END
     WHERE id = r.id;
    v_fired := v_fired + 1;
  END LOOP;
  RETURN jsonb_build_object('fired', v_fired);
END $$;
