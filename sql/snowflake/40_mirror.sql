-- Stage: Postgres-to-Snowflake mirror of the desk schema. Run as ACCOUNTADMIN.
-- The target database must not exist yet; CREATE_MIRROR creates it.
GRANT APPLICATION ROLE SNOWFLAKE.POSTGRES_MIRROR_ADMIN TO ROLE ACCOUNTADMIN;
GRANT USAGE ON POSTGRES INSTANCE "{{PG_INSTANCE}}" TO APPLICATION SNOWFLAKE;

CALL SNOWFLAKE.POSTGRES.CREATE_MIRROR(
  mirror_name       => '{{MIRROR_NAME}}',
  postgres_instance => '{{PG_INSTANCE}}',
  postgres_database => 'postgres',
  target_database   => '{{MIRROR_DB}}',
  postgres_tables   => NULL,
  postgres_schemas  => ['desk'],
  refresh_interval  => '{{MIRROR_REFRESH}}'
);
