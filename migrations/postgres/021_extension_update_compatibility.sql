CREATE OR REPLACE FUNCTION public.ventio_validate_extension_schema_upgrade(
    p_tenant text, p_module text, p_version text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp AS $fn$
DECLARE candidate_package jsonb; previous_package jsonb;
  old_doc jsonb; new_doc jsonb; old_field jsonb; new_field jsonb;
  old_version integer; new_version integer; old_required boolean;
  old_min numeric; new_min numeric; old_max numeric; new_max numeric;
  old_min_length integer; new_min_length integer;
  old_max_length integer; new_max_length integer;
  enum_value text;
BEGIN
  IF NOT pg_has_role(session_user,'ventio_identity_admin','MEMBER') THEN
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

    FOR old_field IN
      SELECT value FROM jsonb_array_elements(old_doc->'fields') AS fields(value)
    LOOP
      SELECT value INTO new_field
      FROM jsonb_array_elements(new_doc->'fields') AS fields(value)
      WHERE value->>'name' IS NOT DISTINCT FROM old_field->>'name';
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
      IF NOT old_required AND COALESCE((new_field->>'required')::boolean,false) THEN
        RAISE EXCEPTION 'Schema update makes field %.% newly required', old_doc->>'name', old_field->>'name'
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
      IF NOT EXISTS (
        SELECT FROM jsonb_array_elements(old_doc->'fields') AS fields(value)
        WHERE value->>'name' IS NOT DISTINCT FROM new_field->>'name'
      ) AND COALESCE((new_field->>'required')::boolean,false) THEN
        RAISE EXCEPTION 'New field %.% must remain optional until a reviewed data migration exists', old_doc->>'name', new_field->>'name'
          USING ERRCODE='23514';
      END IF;
    END LOOP;
  END LOOP;
END $fn$
