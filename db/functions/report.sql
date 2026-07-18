-- report.sql — Report Generator write API (SECURITY DEFINER; workers hold no direct DML).
-- Upserts the one-current-report-per-lead row after the HTML is built + uploaded.

CREATE OR REPLACE FUNCTION @@SCHEMA@@.record_lead_report(
  p_campaign_lead_id uuid, p_url text, p_object_key text,
  p_best_angle text, p_summary text, p_html text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE v_biz uuid; v_camp uuid; v_id uuid;
BEGIN
  SELECT business_id, campaign_id INTO v_biz, v_camp
    FROM campaign_leads WHERE id = p_campaign_lead_id;
  IF v_biz IS NULL THEN
    RAISE EXCEPTION 'unknown_lead' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO lead_reports
    (campaign_lead_id, business_id, campaign_id, best_angle, report_url, object_key, summary, html)
  VALUES
    (p_campaign_lead_id, v_biz, v_camp, p_best_angle, p_url, p_object_key, p_summary, p_html)
  ON CONFLICT (campaign_lead_id) DO UPDATE SET
    best_angle = EXCLUDED.best_angle, report_url = EXCLUDED.report_url,
    object_key = EXCLUDED.object_key, summary = EXCLUDED.summary,
    html = EXCLUDED.html, generated_at = now()
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('report_id', v_id, 'url', p_url);
END $$;
