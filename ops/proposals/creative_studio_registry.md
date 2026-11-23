# Proposal: register `creative_studio` in the M5 service registry from a migration

Status: owner decision. Not applied by M8.

The studio needs its `fz_services` row (owner = group) before it runs. M8 ships that row as an **owner release step**
(`ops/OWNER_CREATIVE_STUDIO.sql`, step 1), not in the migration. The reason is that `sqltests/shared_services_check.sql` is protected and pins
exactly six services. Adding the row in the migration would break that test, and agents must not edit it.

If the owner prefers the registry row to come from the migration, apply both changes in one owner-reviewed PR:

1. In `migrations/20261205_creative_studio_v1.sql`, add the `insert ... on conflict (service) do nothing` from `OWNER_CREATIVE_STUDIO.sql` step 1.
2. In `sqltests/shared_services_check.sql`, change the service-count assertion from 6 to 7 and add `creative_studio` to the expected list.

Until then, `fz_creative.studio_on()` returns false and every service-path call refuses with
"the creative studio is not registered or not active". This is the safe default.
