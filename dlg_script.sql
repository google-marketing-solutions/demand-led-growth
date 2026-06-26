DECLARE custom_range_start_offset INT64 DEFAULT 37;
DECLARE custom_range_end_offset INT64 DEFAULT 7;

CREATE TEMP FUNCTION DecodeRecommendationOcid(resourceName STRING, customerId STRING)
RETURNS STRING
LANGUAGE js AS r"""
  if (!resourceName) return customerId;
  try {
    var parts = resourceName.split('/');
    var base64url = parts[parts.length - 1];

    var base64 = base64url.replace(/-/g, '+').replace(/_/g, '/');
    while (base64.length % 4 !== 0) {
      base64 += '=';
    }

    var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
    var output = '';
    var i = 0;

    base64 = base64.replace(/[^A-Za-z0-9\\+\\/\\=]/g, '');

    while (i < base64.length) {
      var enc1 = chars.indexOf(base64.charAt(i++));
      var enc2 = chars.indexOf(base64.charAt(i++));
      var enc3 = chars.indexOf(base64.charAt(i++));
      var enc4 = chars.indexOf(base64.charAt(i++));

      var chr1 = (enc1 << 2) | (enc2 >> 4);
      var chr2 = ((enc2 & 15) << 4) | (enc3 >> 2);
      var chr3 = ((enc3 & 3) << 6) | enc4;

      output += String.fromCharCode(chr1);
      if (enc3 != 64) output += String.fromCharCode(chr2);
      if (enc4 != 64) output += String.fromCharCode(chr3);
    }

    var matches = output.match(/\\d{5,15}/g);
    
    if (matches && matches.length > 0) {
      var cleanCustomerId = String(customerId).replace(/-/g, '');
      for (var j = 0; j < matches.length; j++) {
        if (matches[j] !== cleanCustomerId) {
          return matches[j];
        }
      }
    }
    return customerId;
  } catch(e) {
    return customerId;
  }
""";

CREATE OR REPLACE TEMP TABLE PortfolioStrategies_Temp AS
SELECT bidding_strategy_id AS strategyId, bidding_strategy_name AS name, bidding_strategy_type AS type, 
       COALESCE(NULLIF(SAFE_CAST(bidding_strategy_target_cpa_target_cpa_micros AS FLOAT64), 0), NULLIF(SAFE_CAST(bidding_strategy_maximize_conversions_target_cpa_micros AS FLOAT64), 0)) / 1000000 AS targetCpa,
       COALESCE(NULLIF(SAFE_CAST(bidding_strategy_target_roas_target_roas AS FLOAT64), 0), NULLIF(SAFE_CAST(bidding_strategy_maximize_conversion_value_target_roas AS FLOAT64), 0)) AS targetRoas, 
       'LOCAL' AS ownership
FROM `${PROJECT_ID}.${DATASET}.p_ads_CustomBiddingStrategies_*`;

IF (SELECT count(1) > 0 FROM `${PROJECT_ID}.${DATASET}.INFORMATION_SCHEMA.TABLES` WHERE table_name LIKE 'p_ads_CustomAccessibleBiddingStrategies_%') THEN
  INSERT INTO PortfolioStrategies_Temp
  SELECT accessible_bidding_strategy_id AS strategyId, accessible_bidding_strategy_name AS name, accessible_bidding_strategy_type AS type, 
         COALESCE(NULLIF(SAFE_CAST(accessible_bidding_strategy_target_cpa_target_cpa_micros AS FLOAT64), 0), NULLIF(SAFE_CAST(accessible_bidding_strategy_maximize_conversions_target_cpa_micros AS FLOAT64), 0)) / 1000000 AS targetCpa,
         COALESCE(NULLIF(SAFE_CAST(accessible_bidding_strategy_target_roas_target_roas AS FLOAT64), 0), NULLIF(SAFE_CAST(accessible_bidding_strategy_maximize_conversion_value_target_roas AS FLOAT64), 0)) AS targetRoas, 
         'MANAGER' AS ownership
  FROM `${PROJECT_ID}.${DATASET}.p_ads_CustomAccessibleBiddingStrategies_*`;
END IF;

CREATE OR REPLACE TABLE `${PROJECT_ID}.${DATASET}.dlg_recommendations_dashboard` AS
WITH
  CustomerDetails AS (
    SELECT
      _TABLE_SUFFIX AS mccId,
      customer_id AS customerId,
      customer_descriptive_name AS accountName,
      customer_currency_code AS currencyCode
    FROM `${PROJECT_ID}.${DATASET}.p_ads_Customer_*`
    QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY _PARTITIONTIME DESC) = 1
  ),
  CurrencyExchange AS (
    SELECT 
      base_currency AS currencyCode, 
      target_currency AS currencyCodeGlobal,
      date,
      rate
    FROM `${PROJECT_ID}.${DATASET}.${FX_TABLE_NAME}`
    QUALIFY ROW_NUMBER() OVER (PARTITION BY base_currency, target_currency ORDER BY date DESC) = 1
  ),
  CampaignSettings AS (
    SELECT
      campaign_id,
      SAFE_CAST(campaign_ai_max_setting_enable_ai_max AS BOOL) AS campaignIsAiMax,
      
      COALESCE(
        (
          SELECT IF(REGEXP_CONTAINS(setting, r'OPTED_IN'), TRUE, FALSE)
          FROM UNNEST(JSON_EXTRACT_ARRAY(campaign_asset_automation_settings)) AS setting
          WHERE REGEXP_CONTAINS(setting, r'FINAL_URL_EXPANSION_TEXT_ASSET_AUTOMATION')
          LIMIT 1
        ),
        TRUE
      ) AS campaignAiMaxFinalUrlExpansionEnabled,

      COALESCE(
        (
          SELECT IF(REGEXP_CONTAINS(setting, r'OPTED_IN'), TRUE, FALSE)
          FROM UNNEST(JSON_EXTRACT_ARRAY(campaign_asset_automation_settings)) AS setting
          WHERE REGEXP_CONTAINS(setting, r'TEXT_ASSET_AUTOMATION')
          LIMIT 1
        ),
        FALSE
      ) AS campaignAiMaxTextCustomizationEnabled

    FROM `${PROJECT_ID}.${DATASET}.p_ads_CustomCampaignSettings_*`
    QUALIFY ROW_NUMBER() OVER (PARTITION BY campaign_id ORDER BY _PARTITIONTIME DESC) = 1
  ),
  LatestCampaignTargets AS (
    SELECT 
      campaign_id,
      COALESCE(NULLIF(SAFE_CAST(campaign_target_cpa_target_cpa_micros AS FLOAT64), 0), NULLIF(SAFE_CAST(campaign_maximize_conversions_target_cpa_micros AS FLOAT64), 0)) / 1000000 AS campaignTargetCpa,
      COALESCE(NULLIF(SAFE_CAST(campaign_target_roas_target_roas AS FLOAT64), 0), NULLIF(SAFE_CAST(campaign_maximize_conversion_value_target_roas AS FLOAT64), 0)) AS campaignTargetRoas
    FROM `${PROJECT_ID}.${DATASET}.p_ads_CustomCampaignMetrics_*`
    WHERE (
      NULLIF(SAFE_CAST(campaign_target_cpa_target_cpa_micros AS FLOAT64), 0) IS NOT NULL OR
      NULLIF(SAFE_CAST(campaign_maximize_conversions_target_cpa_micros AS FLOAT64), 0) IS NOT NULL OR
      NULLIF(SAFE_CAST(campaign_target_roas_target_roas AS FLOAT64), 0) IS NOT NULL OR
      NULLIF(SAFE_CAST(campaign_maximize_conversion_value_target_roas AS FLOAT64), 0) IS NOT NULL
    )
    QUALIFY ROW_NUMBER() OVER(PARTITION BY campaign_id ORDER BY segments_date DESC) = 1
  ),
  CustomCampaignMetricsAgg AS (
    SELECT
      m.campaign_id,
      MAX(t.campaignTargetCpa) AS campaignTargetCpa,
      MAX(t.campaignTargetRoas) AS campaignTargetRoas,
      
      AVG(CASE WHEN CAST(m.segments_date AS DATE) >= DATE_SUB(CURRENT_DATE('UTC'), INTERVAL 30 DAY) THEN SAFE_CAST(m.metrics_search_rank_lost_impression_share AS FLOAT64) ELSE NULL END) AS searchRankLostImpressionShare30Days,
      AVG(CASE WHEN CAST(m.segments_date AS DATE) >= DATE_SUB(CURRENT_DATE('UTC'), INTERVAL 30 DAY) THEN SAFE_CAST(m.metrics_search_budget_lost_impression_share AS FLOAT64) ELSE NULL END) AS searchBudgetLostImpressionShare30Days,
      AVG(CASE WHEN CAST(m.segments_date AS DATE) BETWEEN DATE_SUB(CURRENT_DATE('UTC'), INTERVAL custom_range_start_offset DAY) AND DATE_SUB(CURRENT_DATE('UTC'), INTERVAL custom_range_end_offset DAY) THEN SAFE_CAST(m.metrics_search_rank_lost_impression_share AS FLOAT64) ELSE NULL END) AS searchRankLostImpressionShareCustom,
      AVG(CASE WHEN CAST(m.segments_date AS DATE) BETWEEN DATE_SUB(CURRENT_DATE('UTC'), INTERVAL custom_range_start_offset DAY) AND DATE_SUB(CURRENT_DATE('UTC'), INTERVAL custom_range_end_offset DAY) THEN SAFE_CAST(m.metrics_search_budget_lost_impression_share AS FLOAT64) ELSE NULL END) AS searchBudgetLostImpressionShareCustom,
      SUM(CASE WHEN CAST(m.segments_date AS DATE) >= DATE_SUB(CURRENT_DATE('UTC'), INTERVAL 30 DAY) THEN SAFE_CAST(m.metrics_video_trueview_views AS INT64) ELSE 0 END) AS videoViews30Days,
      SUM(CASE WHEN CAST(m.segments_date AS DATE) BETWEEN DATE_SUB(CURRENT_DATE('UTC'), INTERVAL custom_range_start_offset DAY) AND DATE_SUB(CURRENT_DATE('UTC'), INTERVAL custom_range_end_offset DAY) THEN SAFE_CAST(m.metrics_video_trueview_views AS INT64) ELSE 0 END) AS videoViewsCustomRange,
      
      AVG(CASE WHEN CAST(m.segments_date AS DATE) >= DATE_SUB(CURRENT_DATE('UTC'), INTERVAL 30 DAY) THEN NULLIF(SAFE_CAST(m.metrics_average_target_cpa_micros AS FLOAT64), 0) / 1000000 ELSE NULL END) AS avgTargetCpa30Days,
      AVG(CASE WHEN CAST(m.segments_date AS DATE) >= DATE_SUB(CURRENT_DATE('UTC'), INTERVAL 30 DAY) THEN NULLIF(SAFE_CAST(m.metrics_average_target_roas AS FLOAT64), 0) ELSE NULL END) AS avgTargetRoas30Days,
      AVG(CASE WHEN CAST(m.segments_date AS DATE) BETWEEN DATE_SUB(CURRENT_DATE('UTC'), INTERVAL custom_range_start_offset DAY) AND DATE_SUB(CURRENT_DATE('UTC'), INTERVAL custom_range_end_offset DAY) THEN NULLIF(SAFE_CAST(m.metrics_average_target_cpa_micros AS FLOAT64), 0) / 1000000 ELSE NULL END) AS avgTargetCpaCustom,
      AVG(CASE WHEN CAST(m.segments_date AS DATE) BETWEEN DATE_SUB(CURRENT_DATE('UTC'), INTERVAL custom_range_start_offset DAY) AND DATE_SUB(CURRENT_DATE('UTC'), INTERVAL custom_range_end_offset DAY) THEN NULLIF(SAFE_CAST(m.metrics_average_target_roas AS FLOAT64), 0) ELSE NULL END) AS avgTargetRoasCustom

    FROM `${PROJECT_ID}.${DATASET}.p_ads_CustomCampaignMetrics_*` m
    LEFT JOIN LatestCampaignTargets t ON m.campaign_id = t.campaign_id
    WHERE CAST(m.segments_date AS DATE) >= DATE_SUB(CURRENT_DATE('UTC'), INTERVAL 100 DAY)
    GROUP BY m.campaign_id
  ),
  ActiveCampaigns AS (
    SELECT
      c.customer_id AS customerId,
      c.campaign_id AS campaignId,
      c.campaign_name AS campaignName,
      c.campaign_advertising_channel_type AS campaignType,
      c.campaign_advertising_channel_sub_type AS campaignSubType,
      c.campaign_bidding_strategy_type AS campaignBiddingStrategyType,
      COALESCE(cs.campaignIsAiMax, FALSE) AS campaignIsAiMax,
      COALESCE(cs.campaignAiMaxFinalUrlExpansionEnabled, FALSE) AS campaignAiMaxFinalUrlExpansionEnabled,
      COALESCE(cs.campaignAiMaxTextCustomizationEnabled, FALSE) AS campaignAiMaxTextCustomizationEnabled,
      SAFE_CAST(SPLIT(c.campaign_campaign_budget, '/')[SAFE_OFFSET(3)] AS INT64) AS budgetId,
      c.campaign_bidding_strategy AS portfolioResourceName,
      SAFE_CAST(SPLIT(c.campaign_bidding_strategy, '/')[SAFE_OFFSET(3)] AS INT64) AS strategyId
    FROM `${PROJECT_ID}.${DATASET}.p_ads_Campaign_*` c
    LEFT JOIN CampaignSettings cs ON c.campaign_id = cs.campaign_id
    QUALIFY ROW_NUMBER() OVER (PARTITION BY c.customer_id, c.campaign_id ORDER BY c._PARTITIONTIME DESC) = 1
  ),
  ActiveBudgets AS (
    SELECT
      customer_id AS customerId,
      campaign_budget_id AS budgetId,
      campaign_budget_name AS campaignBudgetName,
      SAFE_CAST(campaign_budget_amount_micros AS FLOAT64) / 1000000 AS campaignBudgetAmount,
      SAFE_CAST(campaign_budget_total_amount_micros AS FLOAT64) / 1000000 AS campaignBudgetTotalAmount,
      campaign_budget_delivery_method AS campaignBudgetDeliveryMethod,
      campaign_budget_explicitly_shared AS campaignBudgetIsShared
    FROM `${PROJECT_ID}.${DATASET}.p_ads_Budget_*`
    QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id, campaign_budget_id ORDER BY _PARTITIONTIME DESC) = 1
  ),
  BudgetSettings AS (
    SELECT
      campaign_budget_id AS budgetId,
      campaign_budget_period AS campaignBudgetType
    FROM `${PROJECT_ID}.${DATASET}.p_ads_CustomBudgetSettings_*`
    QUALIFY ROW_NUMBER() OVER (PARTITION BY campaign_budget_id ORDER BY _PARTITIONTIME DESC) = 1
  ),
  PortfolioStrategies AS (
    SELECT 
      * 
    FROM PortfolioStrategies_Temp
    QUALIFY ROW_NUMBER() OVER (PARTITION BY strategyId ORDER BY strategyId) = 1
  ),
  RollingMetrics_Base AS (
    SELECT 
      customer_id, 
      MAX(CAST(segments_date AS DATE)) AS yesterday_date 
    FROM `${PROJECT_ID}.${DATASET}.p_ads_CampaignBasicStats_*` 
    WHERE CAST(segments_date AS DATE) < CURRENT_DATE('UTC')
    GROUP BY customer_id
  ),
  RollingMetrics AS (
    SELECT
      m.customer_id AS customerId,
      m.campaign_id,
      SUM(CASE WHEN CAST(m.segments_date AS DATE) = md.yesterday_date THEN SAFE_CAST(m.metrics_cost_micros AS FLOAT64) / 1000000 ELSE 0 END) AS yesterdayCost,
      SUM(CASE WHEN CAST(m.segments_date AS DATE) >= DATE_SUB(CURRENT_DATE('UTC'), INTERVAL 7 DAY) THEN SAFE_CAST(m.metrics_cost_micros AS FLOAT64) / 1000000 ELSE 0 END) AS cost7Days,
      SUM(CASE WHEN CAST(m.segments_date AS DATE) >= DATE_SUB(CURRENT_DATE('UTC'), INTERVAL 30 DAY) THEN SAFE_CAST(m.metrics_cost_micros AS FLOAT64) / 1000000 ELSE 0 END) AS cost30Days,
      SUM(CASE WHEN CAST(m.segments_date AS DATE) >= DATE_SUB(CURRENT_DATE('UTC'), INTERVAL 30 DAY) THEN m.metrics_conversions ELSE 0 END) AS conversions30Days,
      SUM(CASE WHEN CAST(m.segments_date AS DATE) >= DATE_SUB(CURRENT_DATE('UTC'), INTERVAL 30 DAY) THEN m.metrics_conversions_value ELSE 0 END) AS conversionsValue30Days,
      SUM(CASE WHEN CAST(m.segments_date AS DATE) >= DATE_SUB(CURRENT_DATE('UTC'), INTERVAL 30 DAY) THEN m.metrics_impressions ELSE 0 END) AS impressions30Days,
      SUM(CASE WHEN CAST(m.segments_date AS DATE) BETWEEN DATE_SUB(CURRENT_DATE('UTC'), INTERVAL custom_range_start_offset DAY) AND DATE_SUB(CURRENT_DATE('UTC'), INTERVAL custom_range_end_offset DAY) THEN SAFE_CAST(m.metrics_cost_micros AS FLOAT64) / 1000000 ELSE 0 END) AS costCustomRange,
      SUM(CASE WHEN CAST(m.segments_date AS DATE) BETWEEN DATE_SUB(CURRENT_DATE('UTC'), INTERVAL custom_range_start_offset DAY) AND DATE_SUB(CURRENT_DATE('UTC'), INTERVAL custom_range_end_offset DAY) THEN m.metrics_conversions ELSE 0 END) AS conversionsCustomRange,
      SUM(CASE WHEN CAST(m.segments_date AS DATE) BETWEEN DATE_SUB(CURRENT_DATE('UTC'), INTERVAL custom_range_start_offset DAY) AND DATE_SUB(CURRENT_DATE('UTC'), INTERVAL custom_range_end_offset DAY) THEN m.metrics_conversions_value ELSE 0 END) AS conversionsValueCustomRange,
      SUM(CASE WHEN CAST(m.segments_date AS DATE) BETWEEN DATE_SUB(CURRENT_DATE('UTC'), INTERVAL custom_range_start_offset DAY) AND DATE_SUB(CURRENT_DATE('UTC'), INTERVAL custom_range_end_offset DAY) THEN m.metrics_impressions ELSE 0 END) AS impressionsCustomRange
    FROM `${PROJECT_ID}.${DATASET}.p_ads_CampaignBasicStats_*` m
    LEFT JOIN RollingMetrics_Base md ON m.customer_id = md.customer_id
    WHERE CAST(m.segments_date AS DATE) >= DATE_SUB(CURRENT_DATE('UTC'), INTERVAL 100 DAY)
    GROUP BY m.customer_id, m.campaign_id, md.yesterday_date
  ),
  ParsedRecommendations AS (
    SELECT
      recommendation_resource_name AS recommendationId,
      recommendation_type AS recommendationType,
      DATE(_PARTITIONTIME) AS recommendationDate,
      SPLIT(recommendation_campaign, '/')[SAFE_OFFSET(3)] AS targetCampaignId,
      
      DecodeRecommendationOcid(recommendation_resource_name, SPLIT(recommendation_resource_name, '/')[SAFE_OFFSET(1)]) AS parsedOcid,
      
      SAFE_CAST(JSON_VALUE(recommendation_impact, '$.baseMetrics.costMicros') AS FLOAT64) / 1000000 AS baseCost,
      SAFE_CAST(JSON_VALUE(recommendation_impact, '$.potentialMetrics.costMicros') AS FLOAT64) / 1000000 AS potentialCost,
      SAFE_CAST(JSON_VALUE(recommendation_impact, '$.baseMetrics.conversions') AS FLOAT64) AS baseConversions,
      SAFE_CAST(JSON_VALUE(recommendation_impact, '$.potentialMetrics.conversions') AS FLOAT64) AS potentialConversions,
      SAFE_CAST(JSON_VALUE(recommendation_impact, '$.baseMetrics.conversionsValue') AS FLOAT64) AS baseConversionsValue,
      SAFE_CAST(JSON_VALUE(recommendation_impact, '$.potentialMetrics.conversionsValue') AS FLOAT64) AS potentialConversionsValue,
      SAFE_CAST(JSON_VALUE(recommendation_impact, '$.baseMetrics.clicks') AS FLOAT64) AS baseClicks,
      SAFE_CAST(JSON_VALUE(recommendation_impact, '$.potentialMetrics.clicks') AS FLOAT64) AS potentialClicks,
      SAFE_CAST(JSON_VALUE(recommendation_impact, '$.baseMetrics.impressions') AS FLOAT64) AS baseImpressions,
      SAFE_CAST(JSON_VALUE(recommendation_impact, '$.potentialMetrics.impressions') AS FLOAT64) AS potentialImpressions,
      SAFE_CAST(JSON_VALUE(recommendation_impact, '$.baseMetrics.videoViews') AS FLOAT64) AS baseVideoViews,
      SAFE_CAST(JSON_VALUE(recommendation_impact, '$.potentialMetrics.videoViews') AS FLOAT64) AS potentialVideoViews,

      SAFE_CAST(JSON_VALUE(recommendation_campaign_budget_recommendation, '$.currentBudgetAmountMicros') AS FLOAT64) / 1000000 AS recommendationCurrentBudgetAmount,
      SAFE_CAST(JSON_VALUE(recommendation_campaign_budget_recommendation, '$.recommendedBudgetAmountMicros') AS FLOAT64) / 1000000 AS recommendationNewBudgetAmount,
      SAFE_CAST(JSON_VALUE(recommendation_raise_target_cpa_recommendation, '$.recommendedTargetMultiplier') AS FLOAT64) AS targetCpaMultiplier,
      SAFE_CAST(JSON_VALUE(recommendation_lower_target_roas_recommendation, '$.recommendedTargetMultiplier') AS FLOAT64) AS targetRoasMultiplier,
      
      SAFE_CAST(JSON_VALUE(recommendation_move_unused_budget_recommendation, '$.budgetRecommendation.recommendedBudgetAmountMicros') AS FLOAT64) / 1000000 AS moveBudgetAmount

    FROM `${PROJECT_ID}.${DATASET}.p_ads_CustomRecommendations_*`
    WHERE recommendation_type IN (
      'CAMPAIGN_BUDGET', 
      'FORECASTING_CAMPAIGN_BUDGET', 
      'MARGINAL_ROI_CAMPAIGN_BUDGET', 
      'MOVE_UNUSED_BUDGET',
      'RAISE_TARGET_CPA',
      'LOWER_TARGET_ROAS'
    )
    AND DATE(_PARTITIONTIME) >= DATE_SUB(CURRENT_DATE('UTC'), INTERVAL 2 DAY)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY SPLIT(recommendation_campaign, '/')[SAFE_OFFSET(3)], recommendation_type ORDER BY _PARTITIONTIME DESC) = 1
  )

SELECT
  cust.mccId,
  c.customerId AS accountId,
  cust.accountName,
  CURRENT_TIMESTAMP() AS timestamp,

  r.recommendationId,
  r.recommendationType,
  
  CONCAT('https://ads.google.com/aw/recommendations?ocid=', r.parsedOcid, '&opp=100') AS recommendationsDetailsUrl,
  CONCAT('https://ads.google.com/aw/overview?campaignId=', c.campaignId, '&ocid=', r.parsedOcid) AS campaignUrl,

  c.campaignId,
  c.campaignName,
  c.campaignType,
  c.campaignSubType,
  c.campaignIsAiMax,
  c.campaignAiMaxTextCustomizationEnabled, 
  c.campaignAiMaxFinalUrlExpansionEnabled,
  cust.currencyCode,
  fx.currencyCodeGlobal,

  b.campaignBudgetName,
  b.campaignBudgetAmount,
  b.campaignBudgetTotalAmount,
  b.campaignBudgetDeliveryMethod,
  bs.campaignBudgetType, 
  b.campaignBudgetIsShared,

  IF(c.portfolioResourceName IS NOT NULL, TRUE, FALSE) AS campaignIsPortfolioBiddingStrategy,
  p.name AS campaignPortfolioBiddingStrategyName,
  c.portfolioResourceName AS portfolioStrategyResourceName,
  p.ownership AS portfolioOwnerId,
  IF(p.ownership = 'LOCAL', TRUE, FALSE) AS isLocallyOwnedPortfolio,
  IF(p.ownership = 'MANAGER', TRUE, FALSE) AS campaignPortfolioIsManagerOwned,
  c.campaignBiddingStrategyType,
  COALESCE(p.targetRoas, cm.campaignTargetRoas) AS campaignBiddingTargetRoas,
  COALESCE(p.targetCpa, cm.campaignTargetCpa) AS campaignBiddingTargetCpa,

  m.yesterdayCost AS campaignStatsYesterdayCost,
  m.cost7Days AS campaignStats7DaysCost,

  m.cost30Days AS campaign30DaysCost,
  m.conversionsValue30Days AS campaign30DaysConversionsValue,
  m.conversions30Days AS campaign30DaysConversions,
  SAFE_DIVIDE(m.conversionsValue30Days, m.cost30Days) AS campaign30DaysRoas,
  SAFE_DIVIDE(m.cost30Days, m.conversions30Days) AS campaign30DaysCpa,
  SAFE_DIVIDE(m.cost30Days, NULLIF(m.impressions30Days, 0)) * 1000 AS campaign30DaysAvgCpm,
  SAFE_DIVIDE(m.cost30Days, NULLIF(cm.videoViews30Days, 0)) AS campaign30DaysAvgCpv,
  NULL AS campaign30DaysUniqueUsers, 
  COALESCE(cm.avgTargetRoas30Days, p.targetRoas, cm.campaignTargetRoas) AS campaign30DaysAvgTargetRoas,
  COALESCE(cm.avgTargetCpa30Days, p.targetCpa, cm.campaignTargetCpa) AS campaign30DaysAvgTargetCpa,
  cm.searchRankLostImpressionShare30Days AS campaign30DaysSearchRankLostImpressionShare,
  cm.searchBudgetLostImpressionShare30Days AS campaign30DaysSearchBudgetLostImpressionShare,
  NULL AS campaign30DaysTargetChangesCount,

  m.costCustomRange AS campaignCustomRangeCost,
  m.conversionsValueCustomRange AS campaignCustomRangeConversionsValue,
  m.conversionsCustomRange AS campaignCustomRangeConversions,
  SAFE_DIVIDE(m.conversionsValueCustomRange, m.costCustomRange) AS campaignCustomRangeRoas,
  SAFE_DIVIDE(m.costCustomRange, m.conversionsCustomRange) AS campaignCustomRangeCpa,
  SAFE_DIVIDE(m.costCustomRange, NULLIF(m.impressionsCustomRange, 0)) * 1000 AS campaignCustomRangeAvgCpm,
  SAFE_DIVIDE(m.costCustomRange, NULLIF(cm.videoViewsCustomRange, 0)) AS campaignCustomRangeAvgCpv,
  NULL AS campaignCustomRangeUniqueUsers,
  COALESCE(cm.avgTargetRoasCustom, p.targetRoas, cm.campaignTargetRoas) AS campaignCustomRangeAvgTargetRoas,
  COALESCE(cm.avgTargetCpaCustom, p.targetCpa, cm.campaignTargetCpa) AS campaignCustomRangeAvgTargetCpa,
  DATE_SUB(CURRENT_DATE(), INTERVAL custom_range_start_offset DAY) AS campaignCustomRangeStartDate,
  DATE_SUB(CURRENT_DATE(), INTERVAL custom_range_end_offset DAY) AS campaignCustomRangeEndDate,
  cm.searchRankLostImpressionShareCustom AS campaignCustomRangeSearchRankLostImpressionShare,
  cm.searchBudgetLostImpressionShareCustom AS campaignCustomRangeSearchBudgetLostImpressionShare,

  r.recommendationCurrentBudgetAmount,
  SAFE_DIVIDE(r.recommendationCurrentBudgetAmount, fx.rate) AS recommendationCurrentBudgetAmountGlobal,
  r.recommendationNewBudgetAmount,
  SAFE_DIVIDE(r.recommendationNewBudgetAmount, fx.rate) AS recommendationNewBudgetAmountGlobal,
  (COALESCE(p.targetCpa, cm.campaignTargetCpa) * r.targetCpaMultiplier) AS recommendationNewTargetCpa,
  (COALESCE(p.targetRoas, cm.campaignTargetRoas) * r.targetRoasMultiplier) AS recommendationNewTargetRoas,
  r.baseCost AS recommendationBaseCost,
  r.potentialCost AS recommendationPotentialCost,
  r.baseClicks AS recommendationBaseClicks,
  r.potentialClicks AS recommendationPotentialClicks,
  r.baseConversions AS recommendationBaseConversions,
  r.potentialConversions AS recommendationPotentialConversions,
  r.baseConversionsValue AS recommendationBaseConversionsValue,
  r.potentialConversionsValue AS recommendationPotentialConversionsValue,
  
  SAFE_DIVIDE(r.baseCost, r.baseConversions) AS recommendationBaseCpa,
  SAFE_DIVIDE(r.potentialCost, r.potentialConversions) AS recommendationPotentialCpa,
  SAFE_DIVIDE(r.baseConversionsValue, r.baseCost) AS recommendationBaseRoas,
  SAFE_DIVIDE(r.potentialConversionsValue, r.potentialCost) AS recommendationPotentialRoas,
  
  r.baseImpressions AS recommendationBaseImpressions,
  r.potentialImpressions AS recommendationPotentialImpressions,
  r.baseVideoViews AS recommendationBaseVideoViews,
  r.potentialVideoViews AS recommendationPotentialVideoViews,

  SAFE_DIVIDE(m.conversionsValue30Days, NULLIF(m.conversions30Days, 0)) * (r.potentialConversions * (30/7)) AS campaignCalculated30DaysPotentialConversionValue,
  SAFE_DIVIDE(m.conversionsValueCustomRange, NULLIF(m.conversionsCustomRange, 0)) * (r.potentialConversions * ((custom_range_start_offset - custom_range_end_offset) / 7)) AS campaignCalculatedCustomRangePotentialConversionValue,
  SAFE_DIVIDE(m.yesterdayCost, b.campaignBudgetAmount) AS campaignPercentageOfBudgetUsedYesterday,
  
  (r.potentialCost - r.baseCost) AS weeklyCostIncrease,
  SAFE_DIVIDE((r.potentialCost - r.baseCost), fx.rate) AS weeklyCostIncreaseGlobal,
  (r.potentialConversions - r.baseConversions) AS newWeeklyConversions,
  (b.campaignBudgetAmount * 30) AS dailyBudget30Days,
  
  (b.campaignBudgetAmount * 30) - m.cost30Days AS dailyBudgetDelta,
  SAFE_DIVIDE(m.conversionsValue30Days, NULLIF(m.cost30Days, 0)) - COALESCE(cm.avgTargetRoas30Days, p.targetRoas, cm.campaignTargetRoas) AS targetRoasDelta,
  SAFE_DIVIDE(m.cost30Days, NULLIF(m.conversions30Days, 0)) - COALESCE(cm.avgTargetCpa30Days, p.targetCpa, cm.campaignTargetCpa) AS targetCpaDelta,
  SAFE_DIVIDE(r.baseCost , NULLIF(r.baseConversions, 0)) - SAFE_DIVIDE(r.potentialCost, NULLIF(r.potentialConversions, 0)) AS recommendationCpaDelta,
  SAFE_DIVIDE(r.baseConversionsValue, NULLIF(r.baseCost , 0)) - SAFE_DIVIDE(r.potentialConversionsValue, NULLIF(r.potentialCost, 0)) AS recommendationRoasDelta,
  r.moveBudgetAmount,
  NULL AS moveBudgetSourceCampaigns,         
  NULL AS moveBudgetSourceBudgetName,        
  NULL AS moveBudgetSourceBudgetType,        
  NULL AS moveBudgetSourceBudgetDeliveryMethod,
  NULL AS moveBudgetSourceBudgetIsShared,
  NULL AS moveBudgetSourceBudgetAmount

FROM ParsedRecommendations r
INNER JOIN ActiveCampaigns c ON r.targetCampaignId = CAST(c.campaignId AS STRING)
LEFT JOIN CustomCampaignMetricsAgg cm ON c.campaignId = cm.campaign_id
LEFT JOIN CustomerDetails cust ON c.customerId = cust.customerId
LEFT JOIN CurrencyExchange fx ON cust.currencyCode = fx.currencyCode
LEFT JOIN ActiveBudgets b ON c.budgetId = b.budgetId AND c.customerId = b.customerId
LEFT JOIN BudgetSettings bs ON b.budgetId = bs.budgetId
LEFT JOIN PortfolioStrategies p ON c.strategyId = p.strategyId
LEFT JOIN RollingMetrics m ON c.campaignId = m.campaign_id AND c.customerId = m.customerId
QUALIFY ROW_NUMBER() OVER (PARTITION BY r.recommendationId ORDER BY c.customerId) = 1;
