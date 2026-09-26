-- Phase 1 · workspace objects for the HR domain.
-- Catalog per domain (Phase 0 decision): cross-catalog grants make Phase 2 real.
CREATE CATALOG IF NOT EXISTS hr COMMENT 'HR domain — Phase 1 of databricks-lab';

CREATE SCHEMA IF NOT EXISTS hr.landing COMMENT 'Delivered files. Not a layer — the drop zone.';
CREATE SCHEMA IF NOT EXISTS hr.bronze  COMMENT '1:1 with the file, typed, provenance attached. Append-only.';
CREATE SCHEMA IF NOT EXISTS hr.silver  COMMENT 'Current-version projection. Materialized. May never join.';
CREATE SCHEMA IF NOT EXISTS hr.gold    COMMENT 'Answers to business questions. Named for the question.';

-- A Volume is object storage (S3 underneath) with Unity Catalog grants on top.
CREATE VOLUME IF NOT EXISTS hr.landing.drop
  COMMENT 'Append-only landing zone. Files arrive here from the delivery process.';

SHOW SCHEMAS IN hr;
