-- archiving.sql
-- RPC functions for soft-archiving evidence items, campaign leads, and entire campaigns.

CREATE OR REPLACE FUNCTION @@SCHEMA@@.archive_evidence(p_evidence_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE v_updated int;
BEGIN
  UPDATE evidence_items SET archived_at = now() WHERE id = p_evidence_id AND archived_at IS NULL;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'evidence_id', p_evidence_id, 'updated', v_updated, 'archived_at', now());
END $$;

CREATE OR REPLACE FUNCTION @@SCHEMA@@.unarchive_evidence(p_evidence_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE v_updated int;
BEGIN
  UPDATE evidence_items SET archived_at = NULL WHERE id = p_evidence_id AND archived_at IS NOT NULL;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'evidence_id', p_evidence_id, 'updated', v_updated);
END $$;

CREATE OR REPLACE FUNCTION @@SCHEMA@@.archive_lead(p_campaign_lead_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE v_business_id uuid; v_campaign_id uuid; v_ev_cnt int; v_wi_cnt int;
BEGIN
  SELECT business_id, campaign_id INTO v_business_id, v_campaign_id FROM campaign_leads WHERE id = p_campaign_lead_id;
  IF v_business_id IS NULL THEN
    RAISE EXCEPTION 'lead_not_found' USING ERRCODE = 'P0001';
  END IF;

  UPDATE campaign_leads SET archived_at = now() WHERE id = p_campaign_lead_id AND archived_at IS NULL;
  
  UPDATE evidence_items SET archived_at = now() 
   WHERE business_id = v_business_id AND campaign_id = v_campaign_id AND archived_at IS NULL;
  GET DIAGNOSTICS v_ev_cnt = ROW_COUNT;

  UPDATE work_items SET archived_at = now() 
   WHERE campaign_lead_id = p_campaign_lead_id AND archived_at IS NULL;
  GET DIAGNOSTICS v_wi_cnt = ROW_COUNT;

  UPDATE lead_reports SET archived_at = now() 
   WHERE campaign_lead_id = p_campaign_lead_id AND archived_at IS NULL;

  UPDATE lead_assessments SET archived_at = now() 
   WHERE campaign_lead_id = p_campaign_lead_id AND archived_at IS NULL;

  RETURN jsonb_build_object('ok', true, 'campaign_lead_id', p_campaign_lead_id, 'archived_evidence_count', v_ev_cnt, 'archived_work_items_count', v_wi_cnt, 'archived_at', now());
END $$;

CREATE OR REPLACE FUNCTION @@SCHEMA@@.archive_campaign(p_campaign_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE v_lead_cnt int; v_ev_cnt int; v_wi_cnt int;
BEGIN
  UPDATE campaigns SET archived_at = now() WHERE id = p_campaign_id AND archived_at IS NULL;

  UPDATE campaign_leads SET archived_at = now() WHERE campaign_id = p_campaign_id AND archived_at IS NULL;
  GET DIAGNOSTICS v_lead_cnt = ROW_COUNT;

  UPDATE evidence_items SET archived_at = now() WHERE campaign_id = p_campaign_id AND archived_at IS NULL;
  GET DIAGNOSTICS v_ev_cnt = ROW_COUNT;

  UPDATE work_items SET archived_at = now() WHERE campaign_id = p_campaign_id AND archived_at IS NULL;
  GET DIAGNOSTICS v_wi_cnt = ROW_COUNT;

  UPDATE lead_reports SET archived_at = now() WHERE campaign_id = p_campaign_id AND archived_at IS NULL;

  UPDATE lead_assessments SET archived_at = now() 
   WHERE campaign_lead_id IN (SELECT id FROM campaign_leads WHERE campaign_id = p_campaign_id) AND archived_at IS NULL;

  RETURN jsonb_build_object('ok', true, 'campaign_id', p_campaign_id, 'archived_leads_count', v_lead_cnt, 'archived_evidence_count', v_ev_cnt, 'archived_work_items_count', v_wi_cnt, 'archived_at', now());
END $$;
