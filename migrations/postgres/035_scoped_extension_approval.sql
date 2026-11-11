CREATE OR REPLACE FUNCTION public.ventio_validate_extension_schema_upgrade(
    p_tenant text, p_module text, p_version text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp AS $fn$
DECLARE candidate_package jsonb; previous_package jsonb;
  old_doc jsonb; new_doc jsonb; old_field jsonb; new_field jsonb;
  migration jsonb; migration_step jsonb; migration_path jsonb;
  migration_cursor integer; old_version integer; new_version integer;
  old_required boolean; source_name text; target_name text; target_type text;
  old_min numeric; new_min numeric; old_max numeric; new_max numeric;
  old_min_length integer; new_min_length integer;
  old_max_length integer; new_max_length integer;
  enum_value text; default_value jsonb; defaulted_fields jsonb;
  field_names jsonb; rename_map jsonb; rebuilt_map jsonb;
  mapping_entry record; has_current_migration boolean;
  migration_step_count integer;
BEGIN
  -- Identity API can reach this validator only through the scoped review SECURITY DEFINER entry point.
-- It has no direct EXECUTE grant here or on admin_change; review rechecks the current branch grant.
IF NOT pg_has_role(session_user,'ventio_identity_admin','MEMBER') AND
    NOT (pg_has_role(session_user,'ventio_identity_api','MEMBER') AND
      current_user='ventio_owner') THEN
    RAISE EXCEPTION 'Extension review requires the restricted administration login'
      USING ERRCODE='42501';
  END IF;
  IF p_tenant IS NULL OR p_module IS NULL OR p_version IS NULL OR
      p_module !~ '^[a-z][a-z0-9]*([._-][a-z0-9]+)*$' OR
      p_version !~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' THEN
    RAISE EXCEPTION 'Invalid extension release identity';
  END IF;

  SELECT package_json INTO candidate_package
  FROM public.ventio_extension_packages
  WHERE tenant_id=p_tenant AND module_id=p_module AND version=p_version
    AND status='SUBMITTED';
  IF NOT FOUND THEN RAISE EXCEPTION 'No submitted extension release exists'; END IF;

  SELECT package_json INTO previous_package
  FROM public.ventio_extension_packages
  WHERE tenant_id=p_tenant AND module_id=p_module
    AND status IN ('APPROVED','REVOKED')
    AND (split_part(version,'.',1)::numeric,
         split_part(version,'.',2)::numeric,
         split_part(version,'.',3)::numeric) <
        (split_part(p_version,'.',1)::numeric,
         split_part(p_version,'.',2)::numeric,
         split_part(p_version,'.',3)::numeric)
  ORDER BY split_part(version,'.',1)::numeric DESC,
           split_part(version,'.',2)::numeric DESC,
           split_part(version,'.',3)::numeric DESC
  LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN RETURN; END IF;

  IF jsonb_typeof(previous_package->'docTypes') IS DISTINCT FROM 'array' OR
      jsonb_typeof(candidate_package->'docTypes') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Extension schema metadata is invalid'
      USING ERRCODE='23514';
  END IF;
  IF EXISTS (
    SELECT FROM jsonb_array_elements(candidate_package->'docTypes') AS d(value)
    WHERE jsonb_typeof(COALESCE(value->'migrations','[]'::jsonb)) IS DISTINCT FROM 'array'
  ) THEN
    RAISE EXCEPTION 'Extension schema migrations must be arrays'
      USING ERRCODE='23514';
  END IF;
  SELECT count(*) INTO migration_step_count
  FROM jsonb_array_elements(candidate_package->'docTypes') AS d(value)
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(value->'migrations','[]'::jsonb)) AS m(value)
  CROSS JOIN LATERAL jsonb_array_elements(m.value->'steps') AS s(value);
  IF migration_step_count > 128 THEN
    RAISE EXCEPTION 'Extension release exceeds the bounded migration operation count'
      USING ERRCODE='23514';
  END IF;

  FOR old_doc IN
    SELECT value FROM jsonb_array_elements(previous_package->'docTypes') AS types(value)
  LOOP
    SELECT value INTO new_doc
    FROM jsonb_array_elements(candidate_package->'docTypes') AS types(value)
    WHERE value->>'name' IS NOT DISTINCT FROM old_doc->>'name';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Extension update removes DocType %', old_doc->>'name'
        USING ERRCODE='23514';
    END IF;
    old_version := (old_doc->>'schemaVersion')::integer;
    new_version := (new_doc->>'schemaVersion')::integer;
    IF new_version < old_version THEN
      RAISE EXCEPTION 'Extension update downgrades DocType %', old_doc->>'name'
        USING ERRCODE='23514';
    END IF;
    IF new_version = old_version THEN
      IF new_doc IS DISTINCT FROM old_doc THEN
        RAISE EXCEPTION 'Changed DocType % requires a higher schema version', old_doc->>'name'
          USING ERRCODE='23514';
      END IF;
      CONTINUE;
    END IF;

    IF jsonb_typeof(COALESCE(new_doc->'migrations','[]'::jsonb)) IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'Schema migrations for DocType % must be an array', old_doc->>'name'
        USING ERRCODE='23514';
    END IF;
    migration_path := '[]'::jsonb;
    migration_cursor := old_version;
    SELECT EXISTS (
      SELECT FROM jsonb_array_elements(COALESCE(new_doc->'migrations','[]'::jsonb)) AS m(value)
      WHERE value->>'fromVersion' = old_version::text
    ) INTO has_current_migration;
    IF has_current_migration THEN
      WHILE migration_cursor < new_version LOOP
        SELECT value INTO migration
        FROM jsonb_array_elements(COALESCE(new_doc->'migrations','[]'::jsonb)) AS m(value)
        WHERE value->>'fromVersion' = migration_cursor::text;
        IF NOT FOUND OR jsonb_typeof(migration) IS DISTINCT FROM 'object' OR
            (SELECT count(*) FROM jsonb_object_keys(migration)) <> 3 OR
            (migration->>'toVersion') !~ '^[0-9]+$' OR
            (migration->>'toVersion')::integer <> migration_cursor + 1 OR
            jsonb_typeof(migration->'steps') IS DISTINCT FROM 'array' OR
            jsonb_array_length(migration->'steps') > 32 THEN
          RAISE EXCEPTION 'Schema migration chain for DocType % is invalid', old_doc->>'name'
            USING ERRCODE='23514';
        END IF;
        migration_path := migration_path || jsonb_build_array(migration);
        migration_cursor := migration_cursor + 1;
      END LOOP;
    END IF;

    SELECT COALESCE(jsonb_agg(value->>'name'), '[]'::jsonb)
      INTO field_names
      FROM jsonb_array_elements(old_doc->'fields') AS f(value);
    SELECT COALESCE(jsonb_object_agg(value->>'name', value->>'name'), '{}'::jsonb)
      INTO rename_map
      FROM jsonb_array_elements(old_doc->'fields') AS f(value);
    defaulted_fields := '[]'::jsonb;

    FOR migration IN SELECT value FROM jsonb_array_elements(migration_path) AS m(value)
    LOOP
      FOR migration_step IN SELECT value FROM jsonb_array_elements(migration->'steps') AS s(value)
      LOOP
        IF jsonb_typeof(migration_step) IS DISTINCT FROM 'object' OR
            jsonb_typeof(migration_step->'op') IS DISTINCT FROM 'string' THEN
          RAISE EXCEPTION 'Schema migration operation is invalid'
            USING ERRCODE='23514';
        END IF;
        IF migration_step->>'op' = 'renameField' THEN
          IF (SELECT count(*) FROM jsonb_object_keys(migration_step)) <> 3 OR
              (migration_step->>'from') !~ '^[a-z][a-z0-9_]{0,79}$' OR
              (migration_step->>'to') !~ '^[a-z][a-z0-9_]{0,79}$' OR
              migration_step->>'from' = migration_step->>'to' THEN
            RAISE EXCEPTION 'Field rename migration is invalid'
              USING ERRCODE='23514';
          END IF;
          source_name := migration_step->>'from';
          target_name := migration_step->>'to';
          IF field_names ? target_name THEN
            RAISE EXCEPTION 'Field rename target % already exists in the schema', target_name
              USING ERRCODE='23514';
          END IF;
          field_names := (field_names - source_name) || jsonb_build_array(target_name);
          rebuilt_map := '{}'::jsonb;
          FOR mapping_entry IN SELECT key, value FROM jsonb_each_text(rename_map)
          LOOP
            rebuilt_map := rebuilt_map || jsonb_build_object(
              mapping_entry.key,
              CASE WHEN mapping_entry.value = source_name
                THEN target_name ELSE mapping_entry.value END);
          END LOOP;
          rename_map := rebuilt_map;
        ELSIF migration_step->>'op' = 'setDefault' THEN
          IF (SELECT count(*) FROM jsonb_object_keys(migration_step)) <> 3 OR
              (migration_step->>'field') !~ '^[a-z][a-z0-9_]{0,79}$' OR
              jsonb_typeof(migration_step->'value') NOT IN ('string','number','boolean') THEN
            RAISE EXCEPTION 'Default-value migration is invalid'
              USING ERRCODE='23514';
          END IF;
          target_name := migration_step->>'field';
          default_value := migration_step->'value';
          SELECT value INTO new_field
          FROM jsonb_array_elements(new_doc->'fields') AS f(value)
          WHERE value->>'name' = target_name;
          IF NOT FOUND THEN
            RAISE EXCEPTION 'Default migration target % is absent from the new schema', target_name
              USING ERRCODE='23514';
          END IF;
          target_type := new_field->>'type';
          IF (target_type IN ('text','reference','enum','date','datetime') AND
                jsonb_typeof(default_value) <> 'string') OR
              (target_type IN ('integer','decimal') AND
                jsonb_typeof(default_value) <> 'number') OR
              (target_type = 'boolean' AND jsonb_typeof(default_value) <> 'boolean') OR
              target_type NOT IN ('text','reference','enum','date','datetime','integer','decimal','boolean') THEN
            RAISE EXCEPTION 'Default value type does not match field %', target_name
              USING ERRCODE='23514';
          END IF;
          IF target_type = 'integer' AND
              (default_value #>> '{}')::numeric <> trunc((default_value #>> '{}')::numeric) THEN
            RAISE EXCEPTION 'Default value for integer field % is fractional', target_name
              USING ERRCODE='23514';
          END IF;
          IF target_type = 'enum' AND NOT COALESCE(new_field->'enumValues' ? (default_value #>> '{}'),false) THEN
            RAISE EXCEPTION 'Default value is not an option of enum field %', target_name
              USING ERRCODE='23514';
          END IF;
          IF target_type IN ('text','reference','enum') AND
              new_field ? 'maxLength' AND
              char_length(default_value #>> '{}') > (new_field->>'maxLength')::integer THEN
            RAISE EXCEPTION 'Default value exceeds the maximum length of field %', target_name
              USING ERRCODE='23514';
          END IF;
          IF target_type IN ('integer','decimal') AND
              ((new_field ? 'minValue' AND (default_value #>> '{}')::numeric < (new_field->>'minValue')::numeric) OR
               (new_field ? 'maxValue' AND (default_value #>> '{}')::numeric > (new_field->>'maxValue')::numeric)) THEN
            RAISE EXCEPTION 'Default value is outside the bounds of field %', target_name
              USING ERRCODE='23514';
          END IF;
          IF target_type = 'date' AND (default_value #>> '{}') !~ '^\d{4}-\d{2}-\d{2}$' THEN
            RAISE EXCEPTION 'Default value is not a valid date string for field %', target_name
              USING ERRCODE='23514';
          END IF;
          IF target_type = 'datetime' AND (default_value #>> '{}') !~ '(Z|[+-]\d\d:\d\d)$' THEN
            RAISE EXCEPTION 'Default value is not a valid datetime string for field %', target_name
              USING ERRCODE='23514';
          END IF;
          defaulted_fields := defaulted_fields || jsonb_build_array(target_name);
        ELSE
          RAISE EXCEPTION 'Unsupported schema migration operation: %', migration_step->>'op'
            USING ERRCODE='23514';
        END IF;
      END LOOP;
    END LOOP;

    FOR old_field IN
      SELECT value FROM jsonb_array_elements(old_doc->'fields') AS fields(value)
    LOOP
      target_name := COALESCE(rename_map->>(old_field->>'name'), old_field->>'name');
      SELECT value INTO new_field
      FROM jsonb_array_elements(new_doc->'fields') AS fields(value)
      WHERE value->>'name' = target_name;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Schema update removes field %.%', old_doc->>'name', old_field->>'name'
          USING ERRCODE='23514';
      END IF;
      IF new_field->>'type' IS DISTINCT FROM old_field->>'type' OR
          new_field->>'referenceTo' IS DISTINCT FROM old_field->>'referenceTo' THEN
        RAISE EXCEPTION 'Schema update changes the type or relation of field %.%', old_doc->>'name', old_field->>'name'
          USING ERRCODE='23514';
      END IF;
      old_required := COALESCE((old_field->>'required')::boolean,false);
      IF NOT old_required AND COALESCE((new_field->>'required')::boolean,false) AND
          NOT defaulted_fields ? target_name THEN
        RAISE EXCEPTION 'Schema update makes field %.% newly required without a default migration', old_doc->>'name', target_name
          USING ERRCODE='23514';
      END IF;

      IF jsonb_typeof(old_field->'enumValues')='array' THEN
        FOR enum_value IN
          SELECT value FROM jsonb_array_elements_text(old_field->'enumValues') AS options(value)
        LOOP
          IF NOT COALESCE(new_field->'enumValues' ? enum_value,false) THEN
            RAISE EXCEPTION 'Schema update removes an enum value from field %.%', old_doc->>'name', old_field->>'name'
              USING ERRCODE='23514';
          END IF;
        END LOOP;
      END IF;

      old_min := NULLIF(old_field->>'minValue','')::numeric;
      new_min := NULLIF(new_field->>'minValue','')::numeric;
      old_max := NULLIF(old_field->>'maxValue','')::numeric;
      new_max := NULLIF(new_field->>'maxValue','')::numeric;
      IF (old_min IS NULL AND new_min IS NOT NULL) OR
          (old_min IS NOT NULL AND new_min IS NOT NULL AND new_min>old_min) OR
          (old_max IS NULL AND new_max IS NOT NULL) OR
          (old_max IS NOT NULL AND new_max IS NOT NULL AND new_max<old_max) THEN
        RAISE EXCEPTION 'Schema update tightens numeric bounds for field %.%', old_doc->>'name', old_field->>'name'
          USING ERRCODE='23514';
      END IF;

      old_min_length := NULLIF(old_field->>'minLength','')::integer;
      new_min_length := NULLIF(new_field->>'minLength','')::integer;
      old_max_length := NULLIF(old_field->>'maxLength','')::integer;
      new_max_length := NULLIF(new_field->>'maxLength','')::integer;
      IF (old_min_length IS NULL AND new_min_length IS NOT NULL) OR
          (old_min_length IS NOT NULL AND new_min_length IS NOT NULL AND new_min_length>old_min_length) OR
          (old_max_length IS NULL AND new_max_length IS NOT NULL) OR
          (old_max_length IS NOT NULL AND new_max_length IS NOT NULL AND new_max_length<old_max_length) THEN
        RAISE EXCEPTION 'Schema update tightens text bounds for field %.%', old_doc->>'name', old_field->>'name'
          USING ERRCODE='23514';
      END IF;
    END LOOP;

    FOR new_field IN
      SELECT value FROM jsonb_array_elements(new_doc->'fields') AS fields(value)
    LOOP
      IF COALESCE((new_field->>'required')::boolean,false) AND
          NOT field_names ? (new_field->>'name') AND
          NOT defaulted_fields ? (new_field->>'name') THEN
        RAISE EXCEPTION 'New field %.% must have a validated default migration', old_doc->>'name', new_field->>'name'
          USING ERRCODE='23514';
      END IF;
    END LOOP;

    -- The migration DSL is deliberately restricted and runs in this approval
    -- transaction, under the non-login owner and its admin-only RLS policy.
    FOR migration IN SELECT value FROM jsonb_array_elements(migration_path) AS m(value)
    LOOP
      FOR migration_step IN SELECT value FROM jsonb_array_elements(migration->'steps') AS s(value)
      LOOP
        IF migration_step->>'op' = 'renameField' THEN
          source_name := migration_step->>'from';
          target_name := migration_step->>'to';
          IF EXISTS (
            SELECT FROM public.ventio_records
            WHERE tenant_id=p_tenant AND module_id=p_module
              AND doc_type=old_doc->>'name'
              AND record_data ? source_name AND record_data ? target_name
          ) THEN
            RAISE EXCEPTION 'Record data contains both migration fields %.%', source_name, target_name
              USING ERRCODE='23514';
          END IF;
          UPDATE public.ventio_records
          SET record_data=jsonb_set(record_data-source_name,ARRAY[target_name],record_data->source_name,true),
              revision=revision+1, updated_at=clock_timestamp()
          WHERE tenant_id=p_tenant AND module_id=p_module
            AND doc_type=old_doc->>'name' AND record_data ? source_name;
        ELSIF migration_step->>'op' = 'setDefault' THEN
          target_name := migration_step->>'field';
          default_value := migration_step->'value';
          UPDATE public.ventio_records
          SET record_data=jsonb_set(record_data,ARRAY[target_name],default_value,true),
              revision=revision+1, updated_at=clock_timestamp()
          WHERE tenant_id=p_tenant AND module_id=p_module
            AND doc_type=old_doc->>'name'
            AND (NOT record_data ? target_name OR record_data->target_name='null'::jsonb);
        END IF;
      END LOOP;
    END LOOP;
  END LOOP;
END $fn$;
