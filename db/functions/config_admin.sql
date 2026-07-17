-- config_admin.sql (T026)
-- activate_config_set (immutable rollout: activate new, retire predecessor),
-- evaluate_chain_rules (idempotent per lead+rule+revision; allowlisted targets).

CREATE OR REPLACE FUNCTION @@SCHEMA@@.activate_config_set(
  p_config_type text, p_version integer)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE v_id uuid;
BEGIN
  SELECT id INTO v_id FROM config_sets
   WHERE config_type = p_config_type AND version = p_version FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'config_missing' USING ERRCODE='P0001'; END IF;
  -- retire the currently active set of this type (never modified, only retired)
  UPDATE config_sets SET retired_at = now()
   WHERE config_type = p_config_type AND activated_at IS NOT NULL
     AND retired_at IS NULL AND id <> v_id;
  UPDATE config_sets SET activated_at = coalesce(activated_at, now()), retired_at = NULL
   WHERE id = v_id;
  RETURN jsonb_build_object('status','activated','config_set_id', v_id);
END $$;

-- Allowlist: chain targets are service identifiers, never URLs.
CREATE OR REPLACE FUNCTION @@SCHEMA@@._chain_target_allowed(p_target text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_target IN ('website','reviews','phone','enrichment','assessment','assets');
$$;

CREATE OR REPLACE FUNCTION @@SCHEMA@@.evaluate_chain_rules(
  p_campaign_lead_id uuid, p_event text, p_input_revision bigint)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE
  lead campaign_leads; c campaigns; r record; a lead_assessments;
  v_val numeric; v_fired int := 0; v_suppr int := 0; v_outcome text; v_event uuid;
BEGIN
  SELECT * INTO lead FROM campaign_leads WHERE id = p_campaign_lead_id;
  SELECT * INTO c FROM campaigns WHERE id = lead.campaign_id;
  SELECT * INTO a FROM lead_assessments
   WHERE campaign_lead_id = lead.id AND is_current = true;

  FOR r IN SELECT * FROM chain_rules
            WHERE config_set_id = c.chain_rule_set_id AND event = p_event LOOP
    IF NOT r.enabled THEN
      v_outcome := 'suppressed';
    ELSIF NOT _chain_target_allowed(r.target_service) THEN
      v_outcome := 'error';
    ELSE
      v_val := CASE r.field
        WHEN 'fit_web_seo'      THEN a.fit_web_seo
        WHEN 'fit_voice_ai'     THEN a.fit_voice_ai
        WHEN 'fit_ads_video'    THEN a.fit_ads_video
        WHEN 'fit_consulting'   THEN a.fit_consulting
        WHEN 'opportunity'      THEN a.opportunity_score
        WHEN 'contactability'   THEN a.contactability_score
        WHEN 'confidence'       THEN a.evidence_confidence
        ELSE NULL END;
      IF v_val IS NULL THEN
        v_outcome := 'not_applicable';
      ELSIF (r.operator = '>=' AND v_val >= r.value::numeric)
         OR (r.operator = '<=' AND v_val <= r.value::numeric)
         OR (r.operator = '>'  AND v_val >  r.value::numeric)
         OR (r.operator = '<'  AND v_val <  r.value::numeric)
         OR (r.operator = '='  AND v_val =  r.value::numeric)
         OR (r.operator = '!=' AND v_val <> r.value::numeric) THEN
        v_outcome := 'fired';
      ELSE
        v_outcome := 'suppressed';
      END IF;
    END IF;

    -- idempotent per (lead, rule, revision): duplicate delivery cannot re-fire
    BEGIN
      IF v_outcome = 'fired' THEN
        v_event := _emit_event('chain.fired','dependency', true, lead.id, p_input_revision,
          jsonb_build_object('rule_id', r.id, 'target', r.target_service),
          'chain.fired:' || r.id || ':' || lead.id || ':' || p_input_revision);
      ELSE
        v_event := NULL;
      END IF;
      INSERT INTO chain_rule_evaluations
        (campaign_lead_id, rule_id, input_revision, outcome, target_service, event_id)
      VALUES (p_campaign_lead_id, r.id, p_input_revision, v_outcome, r.target_service, v_event);
      IF v_outcome = 'fired' THEN v_fired := v_fired + 1;
      ELSE v_suppr := v_suppr + 1; END IF;
    EXCEPTION WHEN unique_violation THEN
      NULL;  -- already evaluated at this revision
    END;
  END LOOP;
  RETURN jsonb_build_object('fired', v_fired, 'not_fired', v_suppr);
END $$;
