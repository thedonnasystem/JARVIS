-- READ-ONLY. Prints version, name, length and md5 of the ledger text; compare with MANIFEST.tsv (md5_ledger column).
select version, name, length(array_to_string(statements, E';\n')) as chars, md5(array_to_string(statements, E';\n')) as md5
from supabase_migrations.schema_migrations order by version;
