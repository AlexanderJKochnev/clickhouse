SET allow_experimental_database_materialized_postgresql = 1;
SET allow_experimental_object_type = 1;
CREATE OR REPLACE FUNCTION normalize_text AS (s) ->
    replaceRegexpAll(
        lower(
            replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(
                replaceRegexpAll(s, '-', ' '),
            'ü', 'u'), 'ö', 'o'), 'ä', 'a'), 'ß', 'ss'), '[éèêë]', 'e'), '[àâãå]', 'a'), '[îï]', 'i'), '[ôõø]', 'o'), '[ûù]', 'u'), 'ç', 'c'), 'ñ', 'n'), '[á]', 'a'), '[í]', 'i'), '[ó]', 'o'), '[ú]', 'u'), 'æ', 'ae'), 'ł', 'l'), 'ń', 'n'), 'ś', 's'), 'ź', 'z'), 'ż', 'z'), '[^a-zA-Z0-9 ]', '')
        ),
    ' {2,}', ' ');