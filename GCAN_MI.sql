create or replace view ISP.GCAN_INV.MI_REPORT as

WITH NETWORK_OH AS 
(
    SELECT MATERIAL_NO AS MATERIAL, 
    ZEROIFNULL(SUM(CASE WHEN UN_RESTRICTED_UNITS - OPEN_SALES_ORDER_QTY - OPEN_DELIVERY_QTY < 0 THEN 0 ELSE UN_RESTRICTED_UNITS - OPEN_SALES_ORDER_QTY - OPEN_DELIVERY_QTY END)) AS NETWORK_ATP
    
    FROM TERADATA.PRD_DWH_VIEW_LMT.ATP_AVAILABLETOPROMISE_V
    WHERE PLANT_NO LIKE 'A%'
    GROUP BY ALL
),

ECC_MATERIAL AS 
(
    SELECT MATERIAL, DIV0(STANDARD_PRICE, STD_PRICE_UNIT) AS STANDARD_PRICE, VALID_FROM, DCHAIN_SALES_STATUS AS SALES_STATUS,
    
    FROM TERADATA.PRD_DWH_VIEW_LMT.ECC_MATERIAL_ATTRIBUTES_VIEW 
    WHERE WEEK_OF IN (SELECT MAX(WEEK_OF) FROM TERADATA.PRD_DWH_VIEW_LMT.ECC_MATERIAL_ATTRIBUTES_VIEW)
    AND SALES_ORG = '2900'
),

CUSTOMER AS 
(
    SELECT CUSTOMER, CUSTOMER_DESC AS SOLD_TO_NAME, ZZNA_CD AS TRACK_CODE, ZZNA_CD_DESC AS TRACK_CODE_NAME
    FROM TERADATA.PRD_DWH_VIEW_LMT.CUSTOMER_V 
    WHERE SALESORG = 'CAN'
),

SELLER AS 
(
    SELECT DISTINCT ACCOUNT, SELLER_NAME, SELLER_USERNAME AS SELLER_RACFID, SELLER_EMAIL, 
    MANAGER_NAME AS SELLER_MANAGER_NAME, MANAGER_USERNAME AS SELLER_MANAGER_RACFID, MANAGER_EMAIL AS SELLER_MANAGER_EMAIL
    FROM PUBLISH.CSM.UA_UNIVERSAL_ALIGNMENT_EDV
    WHERE CSG_DESC LIKE 'AM%'
),

R12_SALES AS 
(
    SELECT MATERIAL,
    SUM(CML_OR_QTY) AS R12_DEMAND_QTY,
    COUNT(DISTINCT S_ORD_NUM) AS R12_INVOICE_COUNT
    
    FROM TERADATA.PRD_DWH_VIEW_LMT.SALES_ORDER_V
    WHERE DOC_TYPE IN ('ZOR', 'ZFOR', 'ZFIL', 'ZISU')
    AND DOC_DATE >= DATEADD(MONTH, -12, CURRENT_DATE) 
    AND REASON_REJ IS NULL
    AND SALESORG = '2900'
    AND SHIP_COND IN ('WC', 'CO', 'SH')
    GROUP BY ALL
),

SALES_V AS 
(
    SELECT MATERIAL, PLANT, ZZNA_CD AS TRACK_CODE, SOLD_TO, DOC_DATE, S_ORD_NUM, SUM(CML_OR_QTY) AS CML_OR_QTY, REASON_REJ
    
    FROM TERADATA.PRD_DWH_VIEW_LMT.SALES_ORDER_V
    WHERE DOC_TYPE IN ('ZOR', 'ZFOR', 'ZFIL', 'ZISU')
    AND FISCYEAR >= YEAR(CURRENT_DATE) - 2
    AND (REASON_REJ IS NULL OR REASON_REJ IN ('30', '32', '35', '65'))
    AND SALESORG = '2900'
    AND SHIP_COND IN ('WC', 'CO', 'SH')
    GROUP BY ALL
),

MI AS --used to filter down main table before joining to increase speed
(
    SELECT FIXREQ_COMMENTS_NOTE, ORDER_GUID, FIXED_DEMAND_INDICATOR, APO_PRODUCT AS MATERIAL, APO_LOCATION AS PLANT, 
    QUANTITY AS MI_QTY, REASON_CODE, REASON_CODE_DESCRIPT AS REASON_DESCRIPTION, 
    TRY_TO_DATE(DATE_FROM,'YYYYMMDD') AS START_DATE,
    TRY_TO_DATE(DATE_TO,'YYYYMMDD') AS END_DATE,
    YEAR(START_DATE) AS ACTIVE_YEAR,
    REQUESTOR_FOR_FIXED AS INVENTORY_ANALYST_RACFID,
    TRY_TO_NUMBER(SPLIT_PART(FIXREQ_COMMENTS_NOTE, '_', -2)) AS FORECAST_FREQUENCY,

    CASE -- standardize the forecast frequency to month
        WHEN FORECAST_FREQUENCY = 52 THEN 12
        WHEN FORECAST_FREQUENCY = 26 THEN 6
        WHEN FORECAST_FREQUENCY IN (6, 12) THEN FORECAST_FREQUENCY
        WHEN FORECAST_FREQUENCY = 255 THEN 9
        ELSE 0
        END AS FORECAST_FREQUENCY_MONTH,

    CASE 
        WHEN FIXED_DEMAND_INDICATOR = 'Active' THEN ROUND(MONTHS_BETWEEN(CURRENT_DATE, START_DATE), 0)
        ELSE ROUND(MONTHS_BETWEEN(END_DATE, START_DATE), 0)
        END AS MONTHS_ACTIVE,

    CASE 
        WHEN FIXED_DEMAND_INDICATOR = 'Active' THEN ROUND(MONTHS_BETWEEN(END_DATE, CURRENT_DATE), 0)
        ELSE 0
        END AS MONTHS_REMAIN,

    CASE 
        WHEN REASON_CODE IN (90014, 90019) THEN NULL 
        ELSE ACCOUNT_NUMBER
        END AS SOLD_TO,

    TRY_TO_NUMBER(SPLIT_PART(FIXREQ_COMMENTS_NOTE, '_', -3)) AS FORECAST_SALE,
    ROUND(DIV0(FORECAST_SALE, FORECAST_FREQUENCY_MONTH)) AS MONTHLY_FORECAST_SALE,
    ROUND(MONTHS_BETWEEN(END_DATE, START_DATE) * MONTHLY_FORECAST_SALE) AS TOTAL_EXPECTED_SALE_QTY,
    ROUND(MONTHS_ACTIVE * MONTHLY_FORECAST_SALE) AS CURRENT_EXPECTED_SALE_QTY,
    SPLIT_PART(FIXREQ_COMMENTS_NOTE, '_', -1) AS REQUESTOR_RACFID
    
    FROM TERADATA.PRD_DWH_VIEW_LMT.FIXED_REQUIREMENTS_COMBINED_VIEW
    WHERE REASON_CODE IN (90003, 90005, 90012, 90013, 90019) --90014 market strategy
    AND APO_LOCATION LIKE 'A%' -- GCAN plants only
    AND ACTIVE_YEAR >= YEAR(CURRENT_DATE) - 2
    AND REGEXP_COUNT(COLLATE(FIXREQ_COMMENTS_NOTE,'utf8'), '_') = 3 
),

MI_JOIN AS
(
    SELECT MI.*, SOLD_TO_NAME, PLANT_EDV.PLANT_TYPE, PLANT_EDV.GEO_REGION AS PLANT_PROVINCE,
    ANALYST_INFO.FULL_NAME AS INVENTORY_ANALYST_NAME, ANALYST_INFO.WORK_EMAIL AS INVENTORY_ANALYST_EMAIL, 
    CASE 
        WHEN REQ_INFO.FULL_NAME IS NULL THEN 'EX-EMPLOYEE'
        ELSE REQ_INFO.FULL_NAME END AS REQUESTOR_NAME,
    REQ_INFO.WORK_EMAIL AS REQUESTOR_EMAIL, 
    REQ_INFO.MANAGER_USERNAME AS REQUESTOR_MANAGER_RACFID, REQ_INFO.MANAGER_NAME AS REQUESTOR_MANAGER_NAME,
    REQ_INFO.SECOND_MANAGER_USERNAME AS REQUESTOR_SENIOR_MANAGER_RACFID, REQ_INFO.SECOND_MANAGER_NAME AS REQUESTOR_SENIOR_MANAGER_NAME,
    SELLER.SELLER_NAME, SELLER.SELLER_RACFID, SELLER.SELLER_EMAIL,
    SELLER.SELLER_MANAGER_NAME, SELLER.SELLER_MANAGER_RACFID, SELLER.SELLER_MANAGER_EMAIL,

    CASE
        WHEN MI.REASON_CODE IN (90014, 90019) OR TRACK_CODE IS NULL THEN NULL
        ELSE TRACK_CODE
        END AS TRACK_CODE,

    CASE
        WHEN MI.REASON_CODE IN (90014, 90019) OR TRACK_CODE_NAME IS NULL THEN NULL
        ELSE TRACK_CODE_NAME
        END AS TRACK_CODE_NAME,

    CASE
        WHEN MI.REASON_CODE IN (90014, 90019) THEN 'MAT_PLANT'
        WHEN MI.REASON_CODE IN (90003, 90005, 90012, 90013) AND TRACK_CODE IS NOT NULL THEN 'TRACK_CODE'
        WHEN MI.REASON_CODE IN (90003, 90005, 90012, 90013) AND SOLD_TO IS NOT NULL THEN 'SOLD_TO'
        WHEN MI.REASON_CODE IN (90003, 90005, 90012, 90013) AND SOLD_TO IS NULL THEN 'MISSING ACCOUNT NUMBER'
        WHEN MI.REASON_CODE IN (90003, 90005, 90012, 90013) AND SOLD_TO IS NOT NULL AND SOLD_TO_NAME IS NULL THEN 'INVALID ACCOUNT NUMBER'
        END AS SALE_LEVEL_FLAG,
    
    CASE 
        WHEN ATP.UN_RESTRICTED_UNITS - ATP.OPEN_SALES_ORDER_QTY - ATP.OPEN_DELIVERY_QTY < 0 
            THEN 0 
        ELSE 
            ZEROIFNULL(ATP.UN_RESTRICTED_UNITS - ATP.OPEN_SALES_ORDER_QTY - ATP.OPEN_DELIVERY_QTY)
        END AS PLANT_ATP,

    ZEROIFNULL(R12_SALES.R12_DEMAND_QTY) AS R12_DEMAND_QTY, 
    ZEROIFNULL(R12_SALES.R12_INVOICE_COUNT) AS R12_INVOICE_COUNT,
    ZEROIFNULL(NETWORK_OH.NETWORK_ATP) AS NETWORK_ATP,

    CASE
        WHEN NETWORK_ATP > 0 AND (R12_DEMAND_QTY = 0 OR R12_DEMAND_QTY IS NULL) THEN 999999 --use to show no demand / contribute to excess and obsolete
        ELSE ZEROIFNULL(ROUND(DIV0(NETWORK_ATP, R12_DEMAND_QTY / 12), 1))
        END AS NETWORK_MONTH_SUPPLY

    FROM MI 
    LEFT JOIN PUBLISH.GSCCE.EMPLOYEE_EDV AS REQ_INFO
        ON MI.REQUESTOR_RACFID = REQ_INFO.USERNAME
    LEFT JOIN PUBLISH.GSCCE.EMPLOYEE_EDV AS ANALYST_INFO
        ON MI.INVENTORY_ANALYST_RACFID = ANALYST_INFO.USERNAME
    LEFT JOIN PUBLISH.GSCCE.PLANT_EDV
        ON MI.PLANT = PLANT_EDV.PLANT
    LEFT JOIN CUSTOMER 
        ON MI.SOLD_TO = CUSTOMER.CUSTOMER
    LEFT JOIN NETWORK_OH
        ON MI.MATERIAL = NETWORK_OH.MATERIAL
    LEFT JOIN R12_SALES
        ON MI.MATERIAL = R12_SALES.MATERIAL
    LEFT JOIN TERADATA.PRD_DWH_VIEW_LMT.ATP_AVAILABLETOPROMISE_V AS ATP
        ON MI.MATERIAL = ATP.MATERIAL_NO AND MI.PLANT = ATP.PLANT_NO
    LEFT JOIN SELLER
      ON MI.SOLD_TO = SELLER.ACCOUNT
    WHERE SALE_LEVEL_FLAG NOT IN ('MISSING ACCOUNT NUMBER', 'INVALID ACCOUNT NUMBER')
),

MI_MAT_PLANT AS -- calculate sales at material and plant level
(
    SELECT MI_JOIN.*,
    ZEROIFNULL(SUM(CASE WHEN SALES_V.REASON_REJ IS NULL THEN SALES_V.CML_OR_QTY ELSE 0 END)) AS ACTUAL_SOLD_QTY,
    COUNT(DISTINCT SALES_V.S_ORD_NUM) AS INVOICE_COUNT,
    ZEROIFNULL(SUM(CASE WHEN SALES_V.REASON_REJ IS NOT NULL THEN SALES_V.CML_OR_QTY ELSE 0 END)) AS MISSED_SALE_QTY,

    FROM MI_JOIN
    LEFT JOIN SALES_V
        ON MI_JOIN.MATERIAL = SALES_V.MATERIAL 
        AND MI_JOIN.PLANT = SALES_V.PLANT
        AND SALES_V.DOC_DATE BETWEEN MI_JOIN.START_DATE AND MI_JOIN.END_DATE
    WHERE MI_JOIN.SALE_LEVEL_FLAG = 'MAT_PLANT'
    GROUP BY ALL
),

MI_TRACK_CODE AS -- calculate sales at material and track code level
(
    SELECT MI_JOIN.*,
    ZEROIFNULL(SUM(CASE WHEN SALES_V.REASON_REJ IS NULL THEN SALES_V.CML_OR_QTY ELSE 0 END)) AS ACTUAL_SOLD_QTY,
    COUNT(DISTINCT SALES_V.S_ORD_NUM) AS INVOICE_COUNT,
    ZEROIFNULL(SUM(CASE WHEN SALES_V.REASON_REJ IS NOT NULL THEN SALES_V.CML_OR_QTY ELSE 0 END)) AS MISSED_SALE_QTY,

    FROM MI_JOIN
    LEFT JOIN SALES_V
        ON MI_JOIN.MATERIAL = SALES_V.MATERIAL 
        AND MI_JOIN.TRACK_CODE = SALES_V.TRACK_CODE
        AND SALES_V.DOC_DATE BETWEEN MI_JOIN.START_DATE AND MI_JOIN.END_DATE
    WHERE MI_JOIN.SALE_LEVEL_FLAG = 'TRACK_CODE'
    GROUP BY ALL
),

MI_SOLD_TO AS -- calculate sales at material and sold to level
(
    SELECT MI_JOIN.*,
    ZEROIFNULL(SUM(CASE WHEN SALES_V.REASON_REJ IS NULL THEN SALES_V.CML_OR_QTY ELSE 0 END)) AS ACTUAL_SOLD_QTY,
    COUNT(DISTINCT SALES_V.S_ORD_NUM) AS INVOICE_COUNT,
    ZEROIFNULL(SUM(CASE WHEN SALES_V.REASON_REJ IS NOT NULL THEN SALES_V.CML_OR_QTY ELSE 0 END)) AS MISSED_SALE_QTY,

    FROM MI_JOIN
    LEFT JOIN SALES_V
        ON MI_JOIN.MATERIAL = SALES_V.MATERIAL
        AND MI_JOIN.SOLD_TO = SALES_V.SOLD_TO
        AND SALES_V.DOC_DATE BETWEEN MI_JOIN.START_DATE AND MI_JOIN.END_DATE
    WHERE MI_JOIN.SALE_LEVEL_FLAG = 'SOLD_TO'
    GROUP BY ALL
),

MI_UNION AS 
(
    SELECT * FROM MI_MAT_PLANT
    UNION ALL
    SELECT * FROM MI_TRACK_CODE
    UNION ALL
    SELECT * FROM MI_SOLD_TO
)

SELECT CURRENT_DATE AS REPORT_DATE, MI_UNION.*, ITEM_V.ITEM_DESCRIPTION, ITEM_V.FRENCH_DESCRIPTION AS ITEM_DESCRIPTION_FR,     
ROUND(MI_UNION.MI_QTY * ECC_MATERIAL.STANDARD_PRICE, 2) AS MI_COST,
ROUND(MI_UNION.ACTUAL_SOLD_QTY * ECC_MATERIAL.STANDARD_PRICE, 2) AS COGS,
ROUND((CASE WHEN MI_UNION.ACTUAL_SOLD_QTY > MI_UNION.MI_QTY THEN MI_UNION.MI_QTY ELSE MI_UNION.ACTUAL_SOLD_QTY END) * ECC_MATERIAL.STANDARD_PRICE, 2) AS MI_COGS,
ZEROIFNULL(ROUND(DIV0(ACTUAL_SOLD_QTY + MISSED_SALE_QTY, TOTAL_EXPECTED_SALE_QTY), 2)) AS COMMIT_SOLD_PERCENT, 
ITEM_V.AG_PURCHASING_GROUP AS PURCHASE_GROUP,

CASE WHEN 
    NETWORK_MONTH_SUPPLY = 999999 THEN 'EXCESS'
    ELSE 'HEALTHY'
    END AS EXCESS_INDICATOR,

CASE 
    WHEN ITEM_V.AG_DCHAIN_SPEC_STATUS LIKE 'D%' THEN 'DISCONTINUED'
    WHEN ITEM_V.AG_DCHAIN_SPEC_STATUS LIKE 'W%' THEN 'WHILE STOCK LAST'
    WHEN (ITEM_V.PRODUCT_CATEGORY_MANAGER_CODE = 'C11' OR ITEM_V.AG_DCHAIN_SPEC_STATUS = 'CS') AND ITEM_V.BOD_CODE = 'ED' THEN 'CSI ED'
    WHEN (ITEM_V.PRODUCT_CATEGORY_MANAGER_CODE = 'C11' OR ITEM_V.AG_DCHAIN_SPEC_STATUS = 'CS') AND ITEM_V.BOD_CODE = 'RH' THEN 'CSI RH'
    WHEN (ITEM_V.PRODUCT_CATEGORY_MANAGER_CODE = 'C11' OR ITEM_V.AG_DCHAIN_SPEC_STATUS = 'CS') AND ITEM_V.BOD_CODE = 'CR' THEN 'CSI REGIONAL STOCKED'
    WHEN (ITEM_V.PRODUCT_CATEGORY_MANAGER_CODE = 'C11' OR ITEM_V.AG_DCHAIN_SPEC_STATUS = 'CS') AND ITEM_V.BOD_CODE IN ('ED', 'SI') THEN 'CSI THIRD PARTY'
    WHEN (ITEM_V.PRODUCT_CATEGORY_MANAGER_CODE = 'C11' OR ITEM_V.AG_DCHAIN_SPEC_STATUS = 'CS') AND ITEM_V.BOD_CODE = 'C4' THEN 'CSI PROCURE TO ORDER'
    WHEN ITEM_V.BOD_CODE = 'ED' THEN 'CENTRAL ED'
    WHEN ITEM_V.BOD_CODE = 'RH' THEN 'CENTRAL RH'
    WHEN ITEM_V.BOD_CODE = 'CR' THEN 'REGIONAL STOCKED'
    WHEN ITEM_V.BOD_CODE IN ('ED', 'SI') THEN 'THIRD PARTY'
    WHEN ITEM_V.BOD_CODE = 'C4' THEN 'PROCURE TO ORDER'
    ELSE ITEM_V.AG_DCHAIN_SPEC_STATUS
    END AS STOCKING_STATUS, 

CASE
    WHEN PURCHASE_GROUP IN ('C81', 'C82', 'C83', 'C84', 'C99', 'C97', 'C44') THEN 'BLOCKED' -- mainly used for active MI to see if material is blocked for sale
    ELSE NULL
    END AS BLOCK_STATUS,

CASE 
    WHEN MONTHS_ACTIVE > 2 AND ACTUAL_SOLD_QTY + MISSED_SALE_QTY = 0 THEN 'ZERO SALES'
    WHEN MONTHS_ACTIVE > 2 AND COMMIT_SOLD_PERCENT > 1.4 THEN 'OVERPERFORMING'
    WHEN MONTHS_ACTIVE > 2 AND COMMIT_SOLD_PERCENT >= LEAST(DIV0(MONTHS_ACTIVE, MONTHS_BETWEEN(END_DATE, START_DATE)), 0.7) AND COMMIT_SOLD_PERCENT <= 1.4 THEN 'PERFORMING'
    WHEN MONTHS_ACTIVE > 2 AND COMMIT_SOLD_PERCENT >= 0 AND COMMIT_SOLD_PERCENT < LEAST(DIV0(MONTHS_ACTIVE, MONTHS_BETWEEN(END_DATE, START_DATE)), 0.7) THEN 'UNDERPERFORMING'
    WHEN MONTHS_ACTIVE <= 2 THEN 'GRACE PERIOD'
    END AS PERFORMANCE_RANK

FROM MI_UNION
LEFT JOIN ECC_MATERIAL
    ON MI_UNION.MATERIAL = ECC_MATERIAL.MATERIAL
LEFT JOIN TERADATA.PRD_DWH_VIEW_LMT.AGI_ITEM_V AS ITEM_V 
    ON MI_UNION.MATERIAL = ITEM_V.MATERIAL
WHERE NOT (ECC_MATERIAL.VALID_FROM - MI_UNION.START_DATE <= 28 AND ECC_MATERIAL.SALES_STATUS IN ('DV', 'DG'));