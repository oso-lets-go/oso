WITH all_repos AS (
  SELECT
    repos.project_id AS project_id,
    'GITHUB' AS artifact_namespace,
    'GIT_REPOSITORY' AS artifact_type,
    LOWER(repos.name_with_owner) AS artifact_name,
    LOWER(repos.url) AS artifact_url,
    CAST(repos.id AS STRING) AS artifact_source_id
  FROM {{ ref('stg_ossd__repositories_by_project') }} AS repos
  GROUP BY
    1,
    2,
    3,
    4,
    5,
    6
),

all_npm AS (
  SELECT
    projects.id AS project_id,
    'NPM' AS artifact_namespace,
    'PACKAGE' AS artifact_type,
    CASE
      WHEN
        LOWER(JSON_VALUE(npm.url)) LIKE 'https://npmjs.com/package/%'
        THEN SUBSTR(LOWER(JSON_VALUE(npm.url)), 28)
      WHEN
        LOWER(JSON_VALUE(npm.url)) LIKE 'https://www.npmjs.com/package/%'
        THEN SUBSTR(LOWER(JSON_VALUE(npm.url)), 31)
    END AS artifact_name,
    LOWER(JSON_VALUE(npm.url)) AS artifact_url,
    LOWER(JSON_VALUE(npm.url)) AS artifact_source_id
  FROM
    {{ ref('stg_ossd__current_projects') }} AS projects
  CROSS JOIN
    UNNEST(JSON_QUERY_ARRAY(projects.npm)) AS npm
),

all_blockchain AS (
  SELECT
    projects.id AS project_id,
    UPPER(network) AS artifact_namespace,
    UPPER(tag) AS artifact_type,
    JSON_VALUE(blockchains.address) AS artifact_name,
    JSON_VALUE(blockchains.address) AS artifact_url,
    JSON_VALUE(blockchains.address) AS artifact_source_id
  FROM
    {{ ref('stg_ossd__current_projects') }} AS projects
  CROSS JOIN
    UNNEST(JSON_QUERY_ARRAY(projects.blockchain)) AS blockchains
  CROSS JOIN
    UNNEST(JSON_VALUE_ARRAY(blockchains.networks)) AS network
  CROSS JOIN
    UNNEST(JSON_VALUE_ARRAY(blockchains.tags)) AS tag
),

all_artifacts AS (
  SELECT *
  FROM
    all_repos
  UNION ALL
  SELECT *
  FROM
    all_blockchain
  UNION ALL
  SELECT *
  FROM
    all_npm
),

all_unique_artifacts AS (
  SELECT * FROM all_artifacts GROUP BY 1, 2, 3, 4, 5, 6
)

SELECT
  a.*,
  {{ oso_artifact_id("artifact", "a") }} AS `artifact_id`
FROM all_unique_artifacts AS a
