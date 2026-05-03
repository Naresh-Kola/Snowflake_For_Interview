-- ============================================================
-- SCD TYPE 1 WITH SOFT DELETE — Using Stream + MERGE + Task
-- ============================================================
-- Pattern: Source Table → Stream (CDC) → Task (scheduled) → MERGE → Target
-- This is SCD Type 1 (overwrite) because old values are replaced, not preserved as history rows.
-- Soft Delete: deleted records are marked DELETED_IND='Y' instead of physically removed.
--
-- STREAM METADATA CHEAT SHEET:
-- ┌──────────────────┬───────────────────┬──────────────────────────────────┐
-- │ METADATA$ACTION  │ METADATA$ISUPDATE │ What Happened                    │
-- ├──────────────────┼───────────────────┼──────────────────────────────────┤
-- │ INSERT           │ FALSE             │ Brand new row inserted           │
-- │ INSERT           │ TRUE              │ Updated row (NEW values)         │
-- │ DELETE           │ TRUE              │ Updated row (OLD values) — skip  │
-- │ DELETE           │ FALSE             │ Row was deleted from source      │
-- └──────────────────┴───────────────────┴──────────────────────────────────┘
-- ============================================================


-- STEP 1: CREATE TASK
-- This task runs automatically AFTER PARENT_TASK_2 completes (task DAG/dependency chain).
-- It uses FACETS_INTEGRATION1_WH2 warehouse for compute.
create or replace task DEV_FACETS.FACETS_CORE_WORK.TASK_FID_IHT_DOWNCODE_GP_REPLICATE_ARCH
               warehouse=FACETS_INTEGRATION1_WH2
               after DEV_FACETS.FACETS_CORE_WORK.PARENT_TASK_2
               as


-- STEP 2: MERGE — Target is the dimension/fact table we're updating
MERGE INTO FACETS_CORE_TARGET.FID_IHT_DOWNCODE_GP_REPLICATE_ARCH AS target
    USING
    (
    -- STEP 3: SOURCE = Stream (captures all CDC changes automatically)
    -- QUALIFY deduplicates: if same record changed multiple times between task runs,
    -- keep only the LATEST version (most recent SOURCE_UPDATE_TMSTP).
    -- Without this, MERGE would fail with "Duplicate row detected" error.
    SELECT * FROM STREAM_FID_IHT_DOWNCODE_GP_REPLICATE_ARCH
    QUALIFY ROW_NUMBER() OVER(PARTITION BY LINE_SEQ, ICM_PRODUCT, CLAIM_ID, CREATE_DTM ORDER BY SOURCE_UPDATE_TMSTP DESC)=1
    ) AS source

    -- STEP 4: JOIN CONDITION (Composite Primary Key)
    -- EQUAL_NULL() is used instead of = because regular = returns NULL when comparing NULLs
    -- (NULL = NULL → NULL, not TRUE). EQUAL_NULL(NULL, NULL) → TRUE.
    -- DELETED_IND = 'N' ensures we only match against ACTIVE records in target.
    ON EQUAL_NULL(target.LINE_SEQ, source.LINE_SEQ) AND EQUAL_NULL(target.ICM_PRODUCT, source.ICM_PRODUCT) AND EQUAL_NULL(target.CLAIM_ID, source.CLAIM_ID) AND EQUAL_NULL(target.CREATE_DTM, source.CREATE_DTM) AND target.DELETED_IND = 'N'

    -- STEP 5: HANDLE DELETES → Soft Delete (mark as deleted, don't physically remove)
    -- When: Row was DELETED from source (ACTION=DELETE, ISUPDATE=FALSE)
    -- Action: Set DELETED_IND='Y' and update timestamp. Row stays in target for audit/history.
    WHEN MATCHED AND METADATA$ACTION = 'DELETE' AND METADATA$ISUPDATE = 'FALSE' THEN
        UPDATE SET target.DELETED_IND = 'Y', target.UPDATE_TMSTP = CURRENT_TIMESTAMP

    -- STEP 6: HANDLE UPDATES → Overwrite all columns (SCD Type 1)
    -- When: Row was UPDATED in source (ACTION=INSERT, ISUPDATE=TRUE = new values of the update)
    -- Action: Overwrite target columns with new values. Old values are LOST (Type 1 behavior).
    WHEN MATCHED AND METADATA$ACTION = 'INSERT' AND METADATA$ISUPDATE = 'TRUE' THEN
        UPDATE SET target.REC_LINE_STATUS = source.REC_LINE_STATUS, target.REC_HCPCS = source.REC_HCPCS, target.CREATE_DTM = source.CREATE_DTM, target.LOAD_DATE = source.LOAD_DATE, target.SUB_HCPCS = source.SUB_HCPCS, target.REASON1_ID = source.REASON1_ID, target.SOURCE_UPDATE_TMSTP = source.SOURCE_UPDATE_TMSTP, target.UPDATE_TMSTP = CURRENT_TIMESTAMP , target.DELETED_IND = 'N', target.PROCEDURE_REC_FLAG = source.PROCEDURE_REC_FLAG , target.MODIFIER_REC_FLAG = source.MODIFIER_REC_FLAG

    -- STEP 7: HANDLE RE-INSERTS → A new INSERT that matches an existing target row
    -- When: Brand new INSERT (ISUPDATE=FALSE) but key already exists in target
    -- This can happen if a previously soft-deleted record is re-inserted in source.
    -- Action: Overwrite and re-activate (DELETED_IND='N').
    WHEN MATCHED AND METADATA$ACTION = 'INSERT' AND METADATA$ISUPDATE = 'FALSE' THEN
        UPDATE SET target.REC_LINE_STATUS = source.REC_LINE_STATUS, target.REC_HCPCS = source.REC_HCPCS, target.CREATE_DTM = source.CREATE_DTM, target.LOAD_DATE = source.LOAD_DATE, target.SUB_HCPCS = source.SUB_HCPCS, target.REASON1_ID = source.REASON1_ID, target.SOURCE_UPDATE_TMSTP = source.SOURCE_UPDATE_TMSTP, target.UPDATE_TMSTP = CURRENT_TIMESTAMP , target.DELETED_IND = 'N', target.PROCEDURE_REC_FLAG = source.PROCEDURE_REC_FLAG , target.MODIFIER_REC_FLAG = source.MODIFIER_REC_FLAG

    -- STEP 8: HANDLE NEW RECORDS → Brand new row, no match in target
    -- When: Record doesn't exist in target at all (NOT MATCHED)
    -- Action: INSERT with SOURCE_SYSTEM_CODE='FID' and current timestamps.
    WHEN NOT MATCHED THEN
        INSERT (REC_LINE_STATUS, CLAIM_ID, LINE_SEQ, REC_HCPCS, ICM_PRODUCT, CREATE_DTM, LOAD_DATE, SUB_HCPCS, REASON1_ID, SOURCE_UPDATE_TMSTP, SOURCE_INSERT_TMSTP ,SOURCE_SYSTEM_CODE, INSERT_TMSTP, UPDATE_TMSTP, PROCEDURE_REC_FLAG, MODIFIER_REC_FLAG)
        VALUES (source.REC_LINE_STATUS, source.CLAIM_ID, source.LINE_SEQ, source.REC_HCPCS, source.ICM_PRODUCT, source.CREATE_DTM, source.LOAD_DATE, source.SUB_HCPCS, source.REASON1_ID, source.SOURCE_UPDATE_TMSTP, source.SOURCE_UPDATE_TMSTP, 'FID', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, source.PROCEDURE_REC_FLAG, source.MODIFIER_REC_FLAG)


-- ============================================================
-- SUMMARY: What each stream event does to the target
-- ============================================================
-- ┌───────────────────────────────────┬──────────────────────────────────┐
-- │ Stream Event                      │ Action on Target                 │
-- ├───────────────────────────────────┼──────────────────────────────────┤
-- │ INSERT + ISUPDATE=FALSE + no match│ INSERT new row                   │
-- │ INSERT + ISUPDATE=FALSE + match   │ UPDATE (re-activate deleted row) │
-- │ INSERT + ISUPDATE=TRUE            │ UPDATE (overwrite — SCD Type 1)  │
-- │ DELETE + ISUPDATE=FALSE           │ SOFT DELETE (DELETED_IND = 'Y')  │
-- │ DELETE + ISUPDATE=TRUE            │ Ignored (old values of update)   │
-- └───────────────────────────────────┴──────────────────────────────────┘
