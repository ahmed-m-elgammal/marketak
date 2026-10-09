/**
 * Network boundary for the app.
 *
 * Only this layer imports `@supabase/supabase-js`. Dependency-cruiser rule 6 enforces it, so a
 * feature cannot quietly open a second client with its own token refresh.
 */

export { supabase } from "@/services/supabase/client";