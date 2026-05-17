-- Ensure duplicate-face RPC dependencies exist for incremental deployments.
CREATE OR REPLACE FUNCTION embedding_min_distance(
  stored_embedding TEXT,
  query_embedding TEXT
)
RETURNS DOUBLE PRECISION
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  stored_json JSONB := stored_embedding::JSONB;
  query_json JSONB := query_embedding::JSONB;
  stored_vectors JSONB;
  vector_json JSONB;
  best_distance DOUBLE PRECISION := NULL;
  current_distance DOUBLE PRECISION;
BEGIN
  IF jsonb_array_length(stored_json) = 0 OR jsonb_array_length(query_json) = 0 THEN
    RETURN NULL;
  END IF;

  IF jsonb_typeof(stored_json->0) = 'array' THEN
    stored_vectors := stored_json;
  ELSE
    stored_vectors := jsonb_build_array(stored_json);
  END IF;

  FOR vector_json IN SELECT value FROM jsonb_array_elements(stored_vectors)
  LOOP
    IF jsonb_array_length(vector_json) <> jsonb_array_length(query_json) THEN
      CONTINUE;
    END IF;

    SELECT sqrt(sum(power((s.value::TEXT)::DOUBLE PRECISION - (q.value::TEXT)::DOUBLE PRECISION, 2)))
    INTO current_distance
    FROM jsonb_array_elements(vector_json) WITH ORDINALITY AS s(value, ord)
    JOIN jsonb_array_elements(query_json) WITH ORDINALITY AS q(value, ord)
      ON s.ord = q.ord;

    IF current_distance IS NOT NULL
      AND (best_distance IS NULL OR current_distance < best_distance) THEN
      best_distance := current_distance;
    END IF;
  END LOOP;

  RETURN best_distance;
END;
$$;

CREATE OR REPLACE FUNCTION find_duplicate_face_owner(
  query_embedding TEXT,
  match_threshold DOUBLE PRECISION DEFAULT 0.37
)
RETURNS TABLE (
  employee_id UUID,
  distance DOUBLE PRECISION
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT fe.employee_id,
         embedding_min_distance(fe.embedding, query_embedding) AS distance
  FROM face_embeddings fe
  WHERE fe.employee_id <> auth.uid()
    AND embedding_min_distance(fe.embedding, query_embedding) <= match_threshold
  ORDER BY distance ASC
  LIMIT 1;
$$;
