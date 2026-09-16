-- Retriever health and desexing: exploratory SQL analysis
-- Source: Hart et al. (2014), https://doi.org/10.1371/journal.pone.0102241
-- Dataset: https://doi.org/10.6084/m9.figshare.1038819
-- PostgreSQL 18. Run in the lab_desex database, using the public schema.
--
-- WORKFLOW
-- 1. Run section 1; import dataset/csv/dogs_combined.csv into dogs_raw once.
--    In pgAdmin: Import, CSV, UTF8, Header Yes; retain column order below.
--    Do not reimport into a populated table: imports append rows.
-- 2. Run sections 2-5 in order. Raw source values are never updated.
-- 3. Run each export query separately and save the specified CSV with headers.
-- 4. Run results.ipynb using the filtered exports.
--
-- SCOPE
-- Blank disease entries mean no recorded diagnosis, not confirmed absence.
-- 'invalid' means outside the study range or not diagnostically confirmed.
-- This restricted cohort excludes any dog with an invalid disease entry and
-- any desexed dog with a listed diagnosis before surgery. Same-day events stay.
-- This is a project-specific exclusion rule, not the paper's disease-specific
-- assignment of pre-surgery diagnoses to intact exposure. It changes selection.
-- Breeds are pooled; follow-up duration is not adjusted. No causal inference.

SET search_path TO public;

-- 1. Raw table and import checkpoint
CREATE TABLE IF NOT EXISTS dogs_raw (
    dog_id TEXT,
    breed TEXT,
    dob TEXT,
    sex TEXT,
    neuter_status TEXT,
    neuter_date TEXT,
    intact_start_date TEXT,
    intact_end_date TEXT,
    neuter_start_date TEXT,
    neuter_end_date TEXT,
    hd TEXT,
    ccl TEXT,
    ed TEXT,
    lsa TEXT,
    mct TEXT,
    hsa TEXT,
    mc TEXT,
    pyo TEXT,
    source_file TEXT,
    source_page INTEGER
);

-- PAUSE on first setup: import the combined CSV before continuing.
-- Fail clearly if source records are absent, duplicated or missing IDs.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dogs_raw) THEN
        RAISE EXCEPTION 'Import dogs_combined.csv into dogs_raw before continuing.';
    END IF;
    IF EXISTS (
        SELECT 1 FROM dogs_raw WHERE NULLIF(TRIM(dog_id), '') IS NULL
    ) OR EXISTS (
        SELECT 1 FROM dogs_raw
        GROUP BY breed, sex, dog_id HAVING COUNT(*) > 1
    ) THEN
        RAISE EXCEPTION 'Check missing IDs or duplicate breed/sex/ID records.';
    END IF;
END $$;

-- Expected source counts: Golden f=471, m=543; Labrador f=692, m=808.
SELECT breed, sex, COUNT(*) AS number_of_dogs
FROM dogs_raw
GROUP BY breed, sex
ORDER BY breed, sex;

-- 2. Standardise labels without changing original values
-- LR179xy was checked against its dates: desexed at exactly two years.
-- Its narrower '2 - 4 yr.' label is consolidated into '2 - 8 yr.'.
CREATE OR REPLACE VIEW dogs_clean AS
SELECT
    *,
    CASE
        WHEN neuter_status IN (
            '2 - 4 yr.',
            '2 - 8 years',
            '2 - 8 yr.'
        )
        THEN '2 - 8 yr.'
        ELSE neuter_status
    END AS neuter_status_clean
FROM dogs_raw;
-- Source cohort distribution (before eligibility exclusions)
SELECT
	sex,
	neuter_status_clean,
	COUNT(*) AS number_of_dogs,
	ROUND(
		100.0 * COUNT(*) 
		/ SUM(COUNT(*)) OVER (PARTITION BY sex), 
		2
	) AS percentage_of_sex
FROM dogs_clean
GROUP BY sex, neuter_status_clean
ORDER BY sex, neuter_status_clean;
-- Missing dates among desexed dogs (expected: no rows)
SELECT * 
FROM dogs_clean
WHERE neuter_status_clean != 'intact'
	AND (
		NULLIF(TRIM(neuter_date), '') IS NULL 
		OR NULLIF(TRIM(dob), '') IS NULL
		);
-- 3. Eligibility and restricted analysis views
-- Dates are MM/DD/YYYY, as specified by Dataset Key.pdf.
CREATE OR REPLACE VIEW dogs_eligibility AS
WITH parsed AS (
    SELECT
        d.*,
        TO_DATE(
            NULLIF(TRIM(d.neuter_date), ''),
            'MM/DD/YYYY'
        ) AS surgery_date,

        disease_check.first_diagnosis_date,
        disease_check.has_invalid_disease

    FROM dogs_clean AS d

    CROSS JOIN LATERAL (
        SELECT
            MIN(
                CASE
                    WHEN LOWER(TRIM(v.entry)) = 'invalid'
                        THEN NULL
                    ELSE TO_DATE(
                        NULLIF(TRIM(v.entry), ''),
                        'MM/DD/YYYY'
                    )
                END
            ) AS first_diagnosis_date,

            BOOL_OR(
                COALESCE(
                    LOWER(TRIM(v.entry)) = 'invalid',
                    FALSE
                )
            ) AS has_invalid_disease

        FROM (
            VALUES
                (d.hd), (d.ccl), (d.ed), (d.lsa),
                (d.mct), (d.hsa), (d.mc), (d.pyo)
        ) AS v(entry)
    ) AS disease_check
)
SELECT
    *,
    CASE
        WHEN NULLIF(TRIM(neuter_status_clean), '') IS NULL
            THEN 'Missing desexing category'

        WHEN neuter_status_clean NOT IN (
            '< 6 mo.', '6 - 11 mo.', '1 yr.', '2 - 8 yr.', 'intact'
        )
            THEN 'Unrecognised desexing category'

        WHEN neuter_status_clean <> 'intact'
             AND surgery_date IS NULL
            THEN 'Missing surgery date'

        WHEN neuter_status_clean <> 'intact'
             AND first_diagnosis_date < surgery_date
            THEN 'Recorded disease before surgery'

        WHEN has_invalid_disease
            THEN 'Invalid disease entry'

        ELSE 'Included'
    END AS eligibility
FROM parsed;
CREATE OR REPLACE VIEW dogs_analysis AS
SELECT *
FROM dogs_eligibility
WHERE eligibility = 'Included';

-- 4. Audit cohort membership
-- Expected for these source files: 2,514 original, 2,227 included, 287 excluded.
-- The eligibility CASE assigns the first matching reason, so these are
-- mutually exclusive counts (some records meet more than one rule).
SELECT eligibility, COUNT(*) AS number_of_dogs
FROM dogs_eligibility
GROUP BY eligibility
ORDER BY number_of_dogs DESC;

-- Overlapping flags: 252 invalid, 37 pre-surgery, 2 meeting both rules.
SELECT
    COUNT(*) AS total_dogs,
    COUNT(*) FILTER (WHERE has_invalid_disease) AS invalid_entry,
    COUNT(*) FILTER (
        WHERE neuter_status_clean <> 'intact'
          AND first_diagnosis_date < surgery_date
    ) AS disease_before_surgery,
    COUNT(*) FILTER (WHERE eligibility = 'Included') AS included,
    COUNT(*) FILTER (WHERE eligibility <> 'Included') AS excluded
FROM dogs_eligibility;

-- Record-level audit with links back to source filenames and page numbers.
SELECT dog_id, breed, sex, neuter_status_clean, surgery_date,
       first_diagnosis_date, has_invalid_disease, eligibility,
       source_file, source_page
FROM dogs_eligibility
WHERE eligibility <> 'Included'
ORDER BY eligibility, breed, sex, dog_id;

-- Filtered denominators for interpreting the disease-by-sex charts.
SELECT sex, neuter_status_clean, COUNT(*) AS number_of_dogs
FROM dogs_analysis
GROUP BY sex, neuter_status_clean
ORDER BY sex, neuter_status_clean;
-- 5. Final analyses: all use dogs_analysis
-- 5a. Proportion with any listed diagnosis (0.2 means 20%)
WITH disease_flags AS (
	SELECT
		neuter_status_clean,
		CASE
			WHEN COALESCE(
				NULLIF(TRIM(hd), ''),
				NULLIF(TRIM(ccl), ''),
				NULLIF(TRIM(ed), ''),
				NULLIF(TRIM(lsa), ''),
				NULLIF(TRIM(mct), ''),
				NULLIF(TRIM(hsa), ''),
				NULLIF(TRIM(mc), ''),
				NULLIF(TRIM(pyo), '')	
			)  IS NOT NULL
			THEN 1
			ELSE 0
		END AS has_recorded_disease
	FROM dogs_analysis
)
SELECT 
	ROUND(AVG(has_recorded_disease)
		FILTER (WHERE neuter_status_clean = '< 6 mo.'), 3)
		AS "Under 6 months",

	ROUND(AVG(has_recorded_disease)
		FILTER (WHERE neuter_status_clean = '6 - 11 mo.'), 3)
		AS "6-11 months",

	ROUND(AVG(has_recorded_disease)
		FILTER (WHERE neuter_status_clean = '1 yr.'), 3)
		AS "1 year",

	ROUND(AVG(has_recorded_disease)
		FILTER (WHERE neuter_status_clean = '2 - 8 yr.'), 3)
		AS "2-8 years",

	ROUND(AVG(has_recorded_disease)
		FILTER (WHERE neuter_status_clean IN (
			'< 6 mo.', '6 - 11 mo.', '1 yr.', '2 - 8 yr.'
			)), 3)
		AS "All desexed",

	ROUND(AVG(has_recorded_disease)
        FILTER (WHERE neuter_status_clean = 'intact'), 3)
        AS "Intact"
FROM disease_flags;
-- 5b. Individual diseases by sex: recorded percentages, not incidence rates
-- Export: dataset/csv/disease_percentages_by_sex_filtered.csv
WITH disease_records AS (
    SELECT
        d.sex,
        d.neuter_status_clean,
        v.disease,
        CASE
            WHEN NULLIF(TRIM(v.diagnosis_date), '') IS NOT NULL
            THEN 1
            ELSE 0
        END AS has_diagnosis
    FROM dogs_analysis AS d
    CROSS JOIN LATERAL (
        VALUES
            ('HD',  d.hd),
            ('CCL', d.ccl),
            ('ED',  d.ed),
            ('LSA', d.lsa),
            ('MCT', d.mct),
            ('HSA', d.hsa),
            ('MC',  d.mc),
            ('PYO', d.pyo)
    ) AS v(disease, diagnosis_date)

    -- MC and PYO were only included in the female source tables.
    WHERE d.sex = 'f'
       OR v.disease NOT IN ('MC', 'PYO')
)
SELECT
    sex,
    disease,

    ROUND(100.0 * AVG(has_diagnosis)
        FILTER (WHERE neuter_status_clean = '< 6 mo.'), 2)
        AS "Under 6 months (%)",

    ROUND(100.0 * AVG(has_diagnosis)
        FILTER (WHERE neuter_status_clean = '6 - 11 mo.'), 2)
        AS "6–11 months (%)",

    ROUND(100.0 * AVG(has_diagnosis)
        FILTER (WHERE neuter_status_clean = '1 yr.'), 2)
        AS "1 year (%)",

    ROUND(100.0 * AVG(has_diagnosis)
        FILTER (WHERE neuter_status_clean = '2 - 8 yr.'), 2)
        AS "2–8 years (%)",

    ROUND(100.0 * AVG(has_diagnosis)
        FILTER (WHERE neuter_status_clean = 'intact'), 2)
        AS "Intact (%)"

FROM disease_records
GROUP BY sex, disease
ORDER BY sex, disease;
-- 5c. Mutually exclusive category counts for the chi-square test
-- Export: dataset/csv/disease_counts_by_desexing_group_filtered.csv
-- Do not add an All desexed row: it would duplicate dogs across test rows.
WITH disease_flags AS (
    SELECT
        neuter_status_clean,
        CASE
            WHEN COALESCE(
                NULLIF(TRIM(hd), ''),
                NULLIF(TRIM(ccl), ''),
                NULLIF(TRIM(ed), ''),
                NULLIF(TRIM(lsa), ''),
                NULLIF(TRIM(mct), ''),
                NULLIF(TRIM(hsa), ''),
                NULLIF(TRIM(mc), ''),
                NULLIF(TRIM(pyo), '')
            ) IS NOT NULL
            THEN 1
            ELSE 0
        END AS has_recorded_disease
    FROM dogs_analysis
)
SELECT
    neuter_status_clean AS desexing_group,
    SUM(has_recorded_disease) AS recorded_disease,
    COUNT(*) - SUM(has_recorded_disease) AS no_recorded_disease,
    COUNT(*) AS total_dogs
FROM disease_flags
WHERE neuter_status_clean IN (
    '< 6 mo.',
    '6 - 11 mo.',
    '1 yr.',
    '2 - 8 yr.',
    'intact'
)
GROUP BY neuter_status_clean
ORDER BY CASE neuter_status_clean
    WHEN '< 6 mo.' THEN 1
    WHEN '6 - 11 mo.' THEN 2
    WHEN '1 yr.' THEN 3
    WHEN '2 - 8 yr.' THEN 4
    WHEN 'intact' THEN 5
END;
