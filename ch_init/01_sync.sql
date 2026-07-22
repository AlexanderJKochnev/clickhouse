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
CREATE OR REPLACE FUNCTION unaccent_text AS (s) ->
    replaceRegexpAll(
        replaceRegexpAll(
            normalizeUTF8NFD(lowerUTF8(s)),
            '([\\x{0300}-\\x{036F}])',
            ''
        ),
        '[''\"`«»‚‘‛❛❜❝❞“”]',
        ''
    );
-- основаня функиця для нормализации
CREATE OR REPLACE FUNCTION unaccent AS (s) ->
    replaceRegexpAll(
    replaceRegexpAll(
    replaceRegexpAll(
        replaceRegexpAll(
            replaceRegexpAll(
                replaceRegexpAll(
                    replaceRegexpAll(
                        replaceRegexpAll(
                            replaceRegexpAll(
                                replaceRegexpAll(
                                    replaceRegexpAll(
                                        replaceRegexpAll(
                                            replaceRegexpAll(
                                                replaceRegexpAll(
                                                    normalizeUTF8NFD(lowerUTF8(s)),
                                                    '([\\x{0300}-\\x{036F}])', ''
                                                ),
                                                '[øØ]', 'o'
                                            ),
                                            '[æÆ]', 'ae'
                                        ),
                                        '[œŒ]', 'oe'
                                    ),
                                    '[ðÐ]', 'd'
                                ),
                                '[þÞ]', 'th'
                            ),
                            '[ß]', 'ss'
                        ),
                        '[łŁ]', 'l'
                    ),
                    '[ŋŊ]', 'n'
                ),
                '[çÇ]', 'c'
            ),
            '[şŞ]', 's'
        ),
        -- '[''\"`«»‚‘‛❛❜❝❞“”]', ''
        '["`«»‚‘‛❛❜❝❞“”]', ''
    ),
    '[–—]', '-'
    ),
    '[…⋯]', '...')
    ;