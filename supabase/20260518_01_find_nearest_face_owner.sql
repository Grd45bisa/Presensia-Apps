-- Return the nearest registered face owner, including the current user.
-- Attendance can use this as a final guard: the logged-in user must be the
-- nearest registered owner for the query embedding.
CREATE OR REPLACE FUNCTION find_nearest_face_owner(
  query_embedding TEXT
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
  WHERE embedding_min_distance(fe.embedding, query_embedding) IS NOT NULL
  ORDER BY distance ASC
  LIMIT 1;
$$;
