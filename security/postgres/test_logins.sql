\set ON_ERROR_STOP on
-- Disposable CI database only. These passwords are deliberately public fixtures.
DO $guard$ BEGIN
  IF current_database() <> 'ventio_host_test' THEN RAISE EXCEPTION 'Disposable database required'; END IF;
END $guard$;
CREATE ROLE ventio_runtime_test LOGIN PASSWORD 'runtime_test_only' INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE ventio_admin_test LOGIN PASSWORD 'admin_test_only' INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE ventio_user_api_test LOGIN PASSWORD 'user_api_test_only' INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE ventio_migration_test LOGIN PASSWORD 'migration_test_only' INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
GRANT ventio_runtime TO ventio_runtime_test;
GRANT ventio_identity_admin TO ventio_admin_test;
GRANT ventio_identity_api TO ventio_user_api_test;
GRANT ventio_migrator TO ventio_migration_test;
