/* Supabase connection for the shop page and /admin.
   Fill both values from Supabase → Project Settings → API (Project URL and the "anon public" key).
   The anon key is meant to be public; the database rules in supabase/schema.sql decide what it may do.
   While these are empty the shop keeps working on the stock written in index.html and orders are not saved. */
window.PB_CONFIG = {
  supabaseUrl: "",
  supabaseAnonKey: ""
};
