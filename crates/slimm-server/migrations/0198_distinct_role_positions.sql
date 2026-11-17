-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- The role ladder compares positions, but before it existed new roles, bots'
-- roles and the Bots role all took the column default 0, so most of them tie.
-- Number every role but @everyone 1..N in the order the roles list shows them
-- (position, then oldest first), so no two share a rank.
UPDATE roles
   SET position = (
       SELECT ranked.n FROM (
           SELECT id, ROW_NUMBER() OVER (ORDER BY position ASC, created_at DESC, id DESC) AS n
             FROM roles WHERE is_everyone = 0) ranked
        WHERE ranked.id = roles.id)
 WHERE is_everyone = 0;
