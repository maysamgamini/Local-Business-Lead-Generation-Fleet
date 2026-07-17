-- 00_helpers.sql — internal helpers used across the function API.
-- Rendered per namespace by deploy-db.ps1 (@@SCHEMA@@). All SECURITY DEFINER,
-- pinned search_path. Naming: leading underscore = internal, not granted to roles.

-- ---------------------------------------------------------------------------
-- Universal fence: lock + validate ownership of a running work item.
-- Raises 'fence_violation' when state/token/lease do not hold.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION @@SCHEMA@@._fenced_lock_work_item(
  p_work_item_id uuid, p_claim_token uuid)
RETURNS @@SCHEMA@@.work_items
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE w work_items;
BEGIN
  SELECT * INTO w FROM work_items
   WHERE id = p_work_item_id FOR UPDATE;
  IF NOT FOUND
     OR w.state <> 'running'
     OR w.claim_token IS DISTINCT FROM p_claim_token
     OR w.lease_expires_at <= now() THEN
    RAISE EXCEPTION 'fence_violation' USING ERRCODE = 'P0001',
      DETAIL = format('work_item=%s state=%s lease_ok=%s',
        p_work_item_id, coalesce(w.state,'<missing>'),
        (w.lease_expires_at > now())::text);
  END IF;
  RETURN w;
END $$;

-- ---------------------------------------------------------------------------
-- Destination routing for outbox fan-out (static v1 map; transport only).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION @@SCHEMA@@._destinations_for(p_event_type text)
RETURNS text[]
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_event_type
    WHEN 'campaign.created'      THEN ARRAY['discovery_poke','dashboard']
    WHEN 'discovery.committed'   THEN ARRAY['analyzer_poke','slack','dashboard']
    WHEN 'evidence.added'        THEN ARRAY['scorer_poke']
    WHEN 'assessment.published'  THEN ARRAY['chain_eval','enrichment_poke','dashboard']
    WHEN 'lead.hot'              THEN ARRAY['slack','dashboard']
    WHEN 'approval.granted'      THEN ARRAY['enrichment_poke','dashboard']
    WHEN 'approval.rejected'     THEN ARRAY['dashboard']
    WHEN 'chain.fired'           THEN ARRAY['chain_target_poke']
    WHEN 'budget.state_changed'  THEN ARRAY['slack','dashboard']
    WHEN 'campaign.finalizing'   THEN ARRAY['dashboard']
    WHEN 'campaign.completed'    THEN ARRAY['slack','dashboard']
    WHEN 'workitem.dead'         THEN ARRAY['slack','dashboard']
    ELSE ARRAY['dashboard'] END;
$$;

-- ---------------------------------------------------------------------------
-- Emit an outbox event + fan out deliveries. Idempotent on event idempotency_key.
-- Class/blocks rules enforced by table CHECK. Returns event id (existing on replay).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION @@SCHEMA@@._emit_event(
  p_event_type text, p_event_class text, p_blocks boolean,
  p_aggregate_id uuid, p_effective_revision bigint,
  p_payload jsonb, p_idempotency_key text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE v_id uuid; d text;
BEGIN
  INSERT INTO outbox_events
    (event_type, event_class, blocks_finalization, aggregate_id,
     effective_revision, payload, idempotency_key)
  VALUES (p_event_type, p_event_class, p_blocks, p_aggregate_id,
          p_effective_revision, coalesce(p_payload,'{}'), p_idempotency_key)
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN  -- replay: deliveries already fanned out
    SELECT id INTO v_id FROM outbox_events WHERE idempotency_key = p_idempotency_key;
    RETURN v_id;
  END IF;
  FOREACH d IN ARRAY _destinations_for(p_event_type) LOOP
    INSERT INTO outbox_deliveries (event_id, destination)
    VALUES (v_id, d) ON CONFLICT (event_id, destination) DO NOTHING;
  END LOOP;
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- Insert one evidence item + optional links + optional verification event.
-- Idempotent (scoped key). Cycle check on lineage. Returns evidence id and
-- whether it was newly inserted (drives revision advancement).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION @@SCHEMA@@._insert_evidence(
  p_business_id uuid, p_campaign_id uuid, p_service text,
  p_service_run_id uuid, p_item jsonb)
RETURNS TABLE (evidence_id uuid, inserted boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE v_id uuid; v_new boolean := true; l jsonb; v_parent uuid;
BEGIN
  INSERT INTO evidence_items
    (business_id, campaign_id, service, feature_key, product_tag,
     value_jsonb, value_type, unit, confidence, calculation_version,
     source_provider, source_record_id, source_url, source_fetched_at,
     observed_at, content_hash, excerpt, service_run_id, idempotency_key)
  VALUES
    (p_business_id, p_campaign_id, p_service,
     p_item->>'feature_key', p_item->>'product_tag',
     p_item->'value', p_item->>'value_type', p_item->>'unit',
     (p_item->>'confidence')::numeric, p_item->>'calculation_version',
     coalesce(p_item->>'source_provider', p_service),
     p_item->>'source_record_id', p_item->>'source_url',
     (p_item->>'source_fetched_at')::timestamptz,
     coalesce((p_item->>'observed_at')::timestamptz, now()),
     p_item->>'content_hash', p_item->>'excerpt',
     p_service_run_id, p_item->>'idempotency_key')
  ON CONFLICT (campaign_id, service, idempotency_key) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    v_new := false;
    SELECT id INTO v_id FROM evidence_items
     WHERE campaign_id = p_campaign_id AND service = p_service
       AND idempotency_key = p_item->>'idempotency_key';
  END IF;

  -- lineage links (cycle prevention: parent must not be reachable FROM child)
  FOR l IN SELECT * FROM jsonb_array_elements(coalesce(p_item->'links','[]')) LOOP
    v_parent := (l->>'parent_evidence_id')::uuid;
    IF v_parent = v_id THEN
      RAISE EXCEPTION 'lineage_cycle' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (
      WITH RECURSIVE up AS (
        SELECT parent_evidence_id FROM evidence_links WHERE child_evidence_id = v_parent
        UNION
        SELECT el.parent_evidence_id FROM evidence_links el
          JOIN up ON el.child_evidence_id = up.parent_evidence_id)
      SELECT 1 FROM up WHERE parent_evidence_id = v_id) THEN
      RAISE EXCEPTION 'lineage_cycle' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO evidence_links (parent_evidence_id, child_evidence_id, relationship_type)
    VALUES (v_parent, v_id, coalesce(l->>'relationship_type','derived_from'))
    ON CONFLICT DO NOTHING;
  END LOOP;

  -- optional verification event (idempotent; duplicates never re-insert)
  IF p_item ? 'verification' THEN
    INSERT INTO evidence_verification_events
      (evidence_id, status, reason, verifier, idempotency_key)
    VALUES (v_id,
      p_item->'verification'->>'status',
      p_item->'verification'->>'reason',
      p_item->'verification'->>'verifier',
      p_item->'verification'->>'idempotency_key')
    ON CONFLICT (idempotency_key) DO NOTHING;
  END IF;

  RETURN QUERY SELECT v_id, v_new;
END $$;
