# КРИТИЧЕСКИ ВАЖНО! СОЗДАНИЕ НОРМАЛИЗИРОВАННЫХ ПОЛНОТЕКСТОВЫХ ИНДЕКСОВ





ALTER TABLE <table> ADD INDEX idx_norm_text <field> TYPE TYPE
text(tokenizer = splitByNonAlpha, preprocessor = normalize_text(tags)) GRANULARITY 100000000;

