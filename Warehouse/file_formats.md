# SNOWFLAKE FILE FORMATS: COMPLETE GUIDE
## Every format type, every option, with real file data examples

---

## 1. WHAT IS A FILE FORMAT?

A **FILE FORMAT** is a named Snowflake object that describes HOW your data files are structured — delimiters, compression, encoding, null handling, etc.

Without a file format, you'd have to repeat all these options every time you run COPY INTO. With a named file format, you define once and reuse.

### Snowflake supports 6 file format types:

| # | Type | Description |
|---|------|-------------|
| 1 | **CSV** | Structured: comma/tab/pipe-delimited flat files |
| 2 | **JSON** | Semi-structured: key-value documents |
| 3 | **PARQUET** | Columnar binary: analytics-optimized |
| 4 | **AVRO** | Row-based binary: schema-embedded |
| 5 | **ORC** | Columnar binary: Hive/Hadoop ecosystem |
| 6 | **XML** | Semi-structured: tag-based markup |

### Syntax:
```sql
CREATE OR REPLACE FILE FORMAT my_format
  TYPE = 'CSV'           -- or JSON, PARQUET, AVRO, ORC, XML
  -- ...format-specific options...
  COMMENT = 'Description of this file format';
```

---

## 2. CSV FILE FORMAT (Most Common)

**USE WHEN:** Loading flat/delimited text files (CSV, TSV, pipe-delimited, etc.)

### Sample File: `employees.csv`
```
emp_id|first_name|last_name|salary|hire_date|is_active
101|"Rahul"|"Sharma"|50000|2024-01-15|true
102|"Priya"|"Verma"|60000|2024-03-20|true
103||"Gupta"|NULL|2024-06-01|false
104|"Amit"|"Patel"|55000||true
,,,""|"",
```

This file has: pipe delimiter, header row, quoted fields, NULLs, empty fields, blank line at end.

### Full CSV File Format with ALL Options:

```sql
CREATE OR REPLACE FILE FORMAT csv_full_options
  TYPE = 'CSV'
  COMPRESSION = AUTO
  FIELD_DELIMITER = '|'
  RECORD_DELIMITER = '\n'
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  ESCAPE = NONE
  ESCAPE_UNENCLOSED_FIELD = NONE
  TRIM_SPACE = FALSE
  NULL_IF = ('NULL', 'null', '', '\\N')
  EMPTY_FIELD_AS_NULL = TRUE
  ERROR_ON_COLUMN_COUNT_MISMATCH = TRUE
  SKIP_BLANK_LINES = TRUE
  DATE_FORMAT = AUTO
  TIME_FORMAT = AUTO
  TIMESTAMP_FORMAT = AUTO
  BINARY_FORMAT = HEX
  ENCODING = 'UTF8'
  REPLACE_INVALID_CHARACTERS = FALSE
  SKIP_BYTE_ORDER_MARK = TRUE
  MULTI_LINE = TRUE
  COMMENT = 'Pipe-delimited CSV with header, quotes, NULLs, blank lines';
```

### Every CSV Option Explained:

| Option | Default | What it does | When to change |
|--------|---------|-------------|----------------|
| **COMPRESSION** | AUTO | How the file is compressed. AUTO detects GZIP, BZ2, ZSTD, etc. | Set `BROTLI` explicitly (AUTO can't detect it). Set `NONE` for parallel scanning optimization |
| **FIELD_DELIMITER** | `,` | Character that separates columns | `'\t'` for TSV, `'|'` for pipe-delimited |
| **RECORD_DELIMITER** | `\n` | Character that separates rows | Legacy systems with custom row separators |
| **SKIP_HEADER** | 0 | Number of header lines to skip | `1` if file has a header row. `2` if title + headers |
| **PARSE_HEADER** | FALSE | Use first row as column names for INFER_SCHEMA | `TRUE` when using INFER_SCHEMA. Mutually exclusive with SKIP_HEADER |
| **FIELD_OPTIONALLY_ENCLOSED_BY** | NONE | Character wrapping string values (`'` or `"`) | `'"'` when fields contain delimiters inside quotes, e.g., `"New York, NY"` |
| **ESCAPE** | NONE | Escape character for ENCLOSED fields | When enclosed fields contain the enclosure char: `"He said ""hello""" ` |
| **ESCAPE_UNENCLOSED_FIELD** | `\\` | Escape character for UNENCLOSED fields | Set `NONE` if trailing backslashes cause rows to merge |
| **TRIM_SPACE** | FALSE | Remove leading/trailing whitespace from fields | `TRUE` when spaces surround quoted fields: `\| "Rahul" \|` |
| **NULL_IF** | `\\N` | Strings to convert to SQL NULL | Add `'NULL'`, `'N/A'`, `''`, `'None'` as needed |
| **EMPTY_FIELD_AS_NULL** | TRUE | Treat `,,` (empty fields) as NULL | `FALSE` to insert empty string `''` for STRING columns |
| **ERROR_ON_COLUMN_COUNT_MISMATCH** | TRUE | Error if file columns != table columns | `FALSE` for schema evolution (extra columns ignored, missing filled with NULL) |
| **SKIP_BLANK_LINES** | FALSE | Skip empty lines in file | `TRUE` if file has blank lines at end or between records |
| **DATE_FORMAT** | AUTO | Format for date values | `'DD/MM/YYYY'` if file has `15/01/2024` format |
| **TIME_FORMAT** | AUTO | Format for time values | Set explicitly if non-standard time format |
| **TIMESTAMP_FORMAT** | AUTO | Format for timestamp values | `'DD-Mon-YYYY HH24:MI:SS'` if file has `15-Jan-2024 10:30:00` |
| **BINARY_FORMAT** | HEX | Encoding for binary data columns | `BASE64` or `UTF8` depending on source encoding |
| **ENCODING** | UTF8 | Character encoding of source file | `'WINDOWS1252'` for Windows files, `'SHIFTJIS'` for Japanese |
| **REPLACE_INVALID_CHARACTERS** | FALSE | Replace bad UTF-8 chars with replacement character | `TRUE` if file has corrupted characters and you want to load anyway |
| **SKIP_BYTE_ORDER_MARK** | TRUE | Skip BOM at start of file | `FALSE` only if BOM is intentional data (very rare) |
| **MULTI_LINE** | TRUE | Allow fields spanning multiple lines | `FALSE` for parallel scanning of large (>128MB) uncompressed CSVs |

### Using the file format:
```sql
COPY INTO employees
FROM @my_stage/employees.csv.gz
FILE_FORMAT = csv_full_options;
```

---

## 3. JSON FILE FORMAT

**USE WHEN:** Loading JSON documents (APIs, NoSQL exports, event logs)

### Sample File: `events.json`
```json
[
  {
    "event_id": 1,
    "user": {"name": "Rahul", "age": 28},
    "tags": ["login", "web"],
    "metadata": null,
    "timestamp": "2024-06-01T10:30:00Z"
  },
  {
    "event_id": 2,
    "user": {"name": "Priya", "age": null},
    "tags": ["purchase", "mobile"],
    "metadata": {"amount": 1500},
    "timestamp": "2024-06-01T11:00:00Z"
  }
]
```

This file has: outer array, nested objects, null values, arrays, timestamps.

### Full JSON File Format:
```sql
CREATE OR REPLACE FILE FORMAT json_full_options
  TYPE = 'JSON'
  COMPRESSION = AUTO
  STRIP_OUTER_ARRAY = TRUE
  STRIP_NULL_VALUES = FALSE
  ALLOW_DUPLICATE = FALSE
  ENABLE_OCTAL = FALSE
  MULTI_LINE = TRUE
  DATE_FORMAT = AUTO
  TIME_FORMAT = AUTO
  TIMESTAMP_FORMAT = AUTO
  NULL_IF = ('\\N', 'NULL')
  TRIM_SPACE = FALSE
  REPLACE_INVALID_CHARACTERS = FALSE
  IGNORE_UTF8_ERRORS = FALSE
  SKIP_BYTE_ORDER_MARK = TRUE
  COMMENT = 'JSON with outer array, nested objects, nulls';
```

### Every JSON Option Explained:

| Option | Default | What it does | When to change |
|--------|---------|-------------|----------------|
| **COMPRESSION** | AUTO | How the file is compressed | Same as CSV |
| **STRIP_OUTER_ARRAY** | FALSE | Remove outer `[ ]` brackets | **TRUE** when JSON is an array of objects. FALSE = entire array loads as 1 row. TRUE = each object is a separate row |
| **STRIP_NULL_VALUES** | FALSE | Remove fields with null values from VARIANT | TRUE saves storage but loses info that the field existed |
| **ALLOW_DUPLICATE** | FALSE | Allow duplicate keys in same object | TRUE if APIs produce `{"a":1, "a":2}` — keeps last value |
| **ENABLE_OCTAL** | FALSE | Parse octal numbers (e.g., 0777) | TRUE if source emits octal (parsed as decimal: 0777 → 511) |
| **MULTI_LINE** | TRUE | Allow pretty-printed JSON (spans multiple lines) | FALSE for NDJSON (one JSON per line) — faster for large files |
| **DATE/TIME/TIMESTAMP_FORMAT** | AUTO | Format for date/time values | Only applies with MATCH_BY_COLUMN_NAME into typed columns |
| **NULL_IF** | `\\N` | Strings to convert to SQL NULL | Only applies with MATCH_BY_COLUMN_NAME |
| **TRIM_SPACE** | FALSE | Remove whitespace from strings | Only applies with MATCH_BY_COLUMN_NAME |
| **REPLACE_INVALID_CHARACTERS** | FALSE | Replace bad UTF-8 chars | TRUE if JSON has corrupted characters |
| **IGNORE_UTF8_ERRORS** | FALSE | Alternative syntax for REPLACE_INVALID_CHARACTERS | Same effect as REPLACE_INVALID_CHARACTERS |
| **SKIP_BYTE_ORDER_MARK** | TRUE | Skip BOM at start of file | Same as CSV |

### Loading JSON:
```sql
CREATE TABLE events (raw VARIANT);

COPY INTO events
FROM @my_stage/events.json
FILE_FORMAT = json_full_options;

-- Query nested data:
SELECT
    raw:event_id::INT AS event_id,
    raw:user.name::STRING AS user_name,
    raw:user.age::INT AS age,
    raw:tags[0]::STRING AS first_tag,
    raw:timestamp::TIMESTAMP AS event_time
FROM events;
```

---

## 4. PARQUET FILE FORMAT

**USE WHEN:** Loading columnar analytics files (Spark output, data lakes, Iceberg)

Parquet is **BINARY** (not human-readable). Conceptually:
```
Parquet File: orders.parquet
Schema:
  order_id: INT64
  customer_name: BYTE_ARRAY (UTF8)
  amount: DOUBLE
  order_date: INT32 (DATE)
  is_shipped: BOOLEAN
Row Groups: 2 (each ~100MB)
Compression: SNAPPY (per column)
```

Parquet stores data in **COLUMNS**, not rows. Each column is compressed independently. This makes analytical queries (`SELECT SUM(amount)`) fast because only the `amount` column is read.

### Full Parquet File Format:
```sql
CREATE OR REPLACE FILE FORMAT parquet_full_options
  TYPE = 'PARQUET'
  COMPRESSION = AUTO
  BINARY_AS_TEXT = FALSE
  USE_LOGICAL_TYPE = TRUE
  USE_VECTORIZED_SCANNER = TRUE
  TRIM_SPACE = FALSE
  REPLACE_INVALID_CHARACTERS = FALSE
  NULL_IF = ('\\N')
  COMMENT = 'Parquet with vectorized scanner, logical types enabled';
```

### Every Parquet Option Explained:

| Option | Default | What it does | When to change |
|--------|---------|-------------|----------------|
| **COMPRESSION** | AUTO | Detects column-level codecs (Snappy, Gzip, LZ4, Zstd) | For UNLOADING: `SNAPPY` (default), `LZO`, or `NONE` |
| **BINARY_AS_TEXT** | TRUE | Interpret untyped binary columns as UTF-8 text | **FALSE** (Snowflake recommended) to avoid conversion issues |
| **USE_LOGICAL_TYPE** | FALSE | Use Parquet logical types for date/time | **TRUE** always — otherwise timestamps may load as raw integers |
| **USE_VECTORIZED_SCANNER** | FALSE | Optimized columnar reader (reads only needed columns) | **TRUE** for all new workloads — significantly faster. Forces BINARY_AS_TEXT=FALSE and USE_LOGICAL_TYPE=TRUE |
| **TRIM_SPACE** | FALSE | Remove whitespace from strings | Only applies with MATCH_BY_COLUMN_NAME |
| **REPLACE_INVALID_CHARACTERS** | FALSE | Replace bad UTF-8 chars | TRUE if file has corrupted characters |
| **NULL_IF** | `\\N` | Strings to convert to SQL NULL | Only applies with MATCH_BY_COLUMN_NAME |

### Loading Parquet:
```sql
-- Option 1: Load into VARIANT column (quick, no schema needed)
CREATE TABLE orders_raw (raw VARIANT);
COPY INTO orders_raw
FROM @my_stage/orders.parquet
FILE_FORMAT = parquet_full_options;

-- Option 2: Load into typed columns (better for queries)
COPY INTO orders
FROM @my_stage/orders.parquet
FILE_FORMAT = parquet_full_options
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
```

---

## 5. AVRO FILE FORMAT

**USE WHEN:** Loading Avro files (Kafka output, schema registry, Hadoop)

Avro is **BINARY** with schema **EMBEDDED** in the file header:
```
Avro File: users.avro
Schema (embedded):
  {"type":"record","name":"User","fields":[
    {"name":"id","type":"int"},
    {"name":"name","type":"string"},
    {"name":"email","type":["null","string"]},
    {"name":"scores","type":{"type":"array","items":"int"}}
  ]}
Data: Binary Avro encoding (not human-readable)
Codec: deflate (embedded in file)
```

> **Key difference from Parquet:** Avro is ROW-based (good for streaming/Kafka), Parquet is COLUMN-based (good for analytics).

### Full Avro File Format:
```sql
CREATE OR REPLACE FILE FORMAT avro_full_options
  TYPE = 'AVRO'
  COMPRESSION = AUTO
  TRIM_SPACE = FALSE
  REPLACE_INVALID_CHARACTERS = FALSE
  NULL_IF = ('\\N')
  COMMENT = 'Avro with auto compression detection';
```

### Every Avro Option Explained:

| Option | Default | What it does | When to change |
|--------|---------|-------------|----------------|
| **COMPRESSION** | AUTO | Detects file + codec compression. Avro has 2 levels: file-level (gzip the .avro) and block/codec-level (deflate, snappy inside container) | Always use AUTO — it handles both levels |
| **TRIM_SPACE** | FALSE | Remove whitespace from strings | Only applies with MATCH_BY_COLUMN_NAME |
| **REPLACE_INVALID_CHARACTERS** | FALSE | Replace bad UTF-8 chars | TRUE if file has corrupted characters |
| **NULL_IF** | `\\N` | Strings to convert to SQL NULL | Only applies with MATCH_BY_COLUMN_NAME |

### Loading Avro:
```sql
CREATE TABLE users_raw (raw VARIANT);
COPY INTO users_raw
FROM @my_stage/users.avro
FILE_FORMAT = avro_full_options;
```

---

## 6. ORC FILE FORMAT

**USE WHEN:** Loading ORC files (Hive, Presto, Spark in Hadoop ecosystem)

ORC is **BINARY**, columnar, similar to Parquet but from the Hive ecosystem:
```
ORC File: transactions.orc
Schema:
  txn_id: INT
  amount: DOUBLE
  category: STRING
  txn_time: TIMESTAMP
Compression: ZLIB (default for ORC)
Stripe size: 250MB
```

> ORC has the **FEWEST options** in Snowflake because the format is self-describing — schema, compression, and encoding are all embedded in the file. There is **NO COMPRESSION option** because ORC files have compression embedded (ZLIB, SNAPPY, LZO). Snowflake auto-detects the codec from the file header.

### Full ORC File Format:
```sql
CREATE OR REPLACE FILE FORMAT orc_full_options
  TYPE = 'ORC'
  TRIM_SPACE = FALSE
  REPLACE_INVALID_CHARACTERS = FALSE
  NULL_IF = ('\\N')
  COMMENT = 'ORC format - minimal options needed';
```

### Every ORC Option Explained:

| Option | Default | What it does | When to change |
|--------|---------|-------------|----------------|
| **TRIM_SPACE** | FALSE | Remove whitespace from strings | Only applies with MATCH_BY_COLUMN_NAME |
| **REPLACE_INVALID_CHARACTERS** | FALSE | Replace bad UTF-8 chars | TRUE if file has corrupted characters |
| **NULL_IF** | `\\N` | Strings to convert to SQL NULL | Only applies with MATCH_BY_COLUMN_NAME |

### Loading ORC:
```sql
CREATE TABLE txn_raw (raw VARIANT);
COPY INTO txn_raw
FROM @my_stage/transactions.orc
FILE_FORMAT = orc_full_options;
```

---

## 7. XML FILE FORMAT

**USE WHEN:** Loading XML files (SOAP APIs, legacy enterprise systems, configs)

### Sample File: `catalog.xml`
```xml
<?xml version="1.0" encoding="UTF-8"?>
<catalog>
  <product>
    <id>301</id>
    <name>  Laptop Pro  </name>
    <price>75000</price>
    <in_stock>true</in_stock>
  </product>
  <product>
    <id>302</id>
    <name>Wireless Mouse</name>
    <price>1500</price>
    <in_stock>false</in_stock>
  </product>
</catalog>
```

This file has: outer element `<catalog>`, child elements `<product>`, leading/trailing spaces in `<name>`, boolean-as-text values.

### Full XML File Format:
```sql
CREATE OR REPLACE FILE FORMAT xml_full_options
  TYPE = 'XML'
  COMPRESSION = AUTO
  STRIP_OUTER_ELEMENT = TRUE
  PRESERVE_SPACE = FALSE
  DISABLE_AUTO_CONVERT = FALSE
  REPLACE_INVALID_CHARACTERS = FALSE
  IGNORE_UTF8_ERRORS = FALSE
  SKIP_BYTE_ORDER_MARK = TRUE
  COMMENT = 'XML with outer element stripped, auto-convert enabled';
```

### Every XML Option Explained:

| Option | Default | What it does | When to change |
|--------|---------|-------------|----------------|
| **COMPRESSION** | AUTO | How the file is compressed | Same as CSV |
| **STRIP_OUTER_ELEMENT** | FALSE | Remove root element wrapper | **TRUE** to expose child elements as separate rows. FALSE = entire XML loads as 1 row |
| **PRESERVE_SPACE** | FALSE | Keep leading/trailing spaces in element content | TRUE if spaces are meaningful data (e.g., `"  Laptop Pro  "`) |
| **DISABLE_AUTO_CONVERT** | FALSE | Disable auto-conversion of numbers/booleans from text | TRUE if you want `"75000"` as string instead of number, `"true"` as string instead of boolean |
| **REPLACE_INVALID_CHARACTERS** | FALSE | Replace bad UTF-8 chars | TRUE if file has corrupted characters |
| **IGNORE_UTF8_ERRORS** | FALSE | Alternative syntax for REPLACE_INVALID_CHARACTERS | Same effect |
| **SKIP_BYTE_ORDER_MARK** | TRUE | Skip BOM at start of file | Same as CSV |

### Loading XML:
```sql
CREATE TABLE catalog_raw (raw VARIANT);
COPY INTO catalog_raw
FROM @my_stage/catalog.xml
FILE_FORMAT = xml_full_options;

-- Query XML data:
SELECT
    raw:"@"::STRING AS element_tag,
    XMLGET(raw, 'id'):"$"::INT AS product_id,
    XMLGET(raw, 'name'):"$"::STRING AS product_name,
    XMLGET(raw, 'price'):"$"::NUMBER AS price
FROM catalog_raw;
```

---

## 8. OPTIONS COMPARISON TABLE

| OPTION | CSV | JSON | PARQUET | AVRO | ORC | XML |
|--------|-----|------|---------|------|-----|-----|
| COMPRESSION | ✓ | ✓ | ✓ | ✓ | | ✓ |
| FIELD_DELIMITER | ✓ | | | | | |
| RECORD_DELIMITER | ✓ | | | | | |
| SKIP_HEADER | ✓ | | | | | |
| PARSE_HEADER | ✓ | | | | | |
| FIELD_OPTIONALLY_ENCLOSED_BY | ✓ | | | | | |
| ESCAPE | ✓ | | | | | |
| ESCAPE_UNENCLOSED_FIELD | ✓ | | | | | |
| SKIP_BLANK_LINES | ✓ | | | | | |
| ERROR_ON_COLUMN_COUNT_MISMATCH | ✓ | | | | | |
| EMPTY_FIELD_AS_NULL | ✓ | | | | | |
| ENCODING | ✓ | | | | | |
| MULTI_LINE | ✓ | ✓ | | | | |
| NULL_IF | ✓ | ✓ | ✓ | ✓ | ✓ | |
| TRIM_SPACE | ✓ | ✓ | ✓ | ✓ | ✓ | |
| DATE_FORMAT | ✓ | ✓ | | | | |
| TIME_FORMAT | ✓ | ✓ | | | | |
| TIMESTAMP_FORMAT | ✓ | ✓ | | | | |
| BINARY_FORMAT | ✓ | ✓ | | | | |
| REPLACE_INVALID_CHARACTERS | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| SKIP_BYTE_ORDER_MARK | ✓ | ✓ | | | | ✓ |
| STRIP_OUTER_ARRAY | | ✓ | | | | |
| STRIP_NULL_VALUES | | ✓ | | | | |
| ALLOW_DUPLICATE | | ✓ | | | | |
| ENABLE_OCTAL | | ✓ | | | | |
| IGNORE_UTF8_ERRORS | | ✓ | | | | ✓ |
| BINARY_AS_TEXT | | | ✓ | | | |
| USE_LOGICAL_TYPE | | | ✓ | | | |
| USE_VECTORIZED_SCANNER | | | ✓ | | | |
| STRIP_OUTER_ELEMENT | | | | | | ✓ |
| PRESERVE_SPACE | | | | | | ✓ |
| DISABLE_AUTO_CONVERT | | | | | | ✓ |

---

## 9. COPY OPTIONS (Apply to ALL file formats)

Copy options are **NOT** part of the file format. They are specified on the COPY INTO command and control loading **BEHAVIOR**.

| Option | Default | What it does | When to change |
|--------|---------|-------------|----------------|
| **ON_ERROR** | ABORT_STATEMENT (bulk) / SKIP_FILE (Snowpipe) | Error handling | `CONTINUE` to skip bad rows. `SKIP_FILE` to skip bad files. `SKIP_FILE_3` to skip if 3+ errors. `'SKIP_FILE_5%'` to skip if >5% errors |
| **PURGE** | FALSE | Delete source files after successful load | TRUE to auto-clean staged files |
| **FORCE** | FALSE | Reload already-loaded files | TRUE to re-load (WARNING: creates duplicates!) |
| **SIZE_LIMIT** | NULL | Max bytes to load per COPY statement | Set for batch processing across multiple COPY runs |
| **MATCH_BY_COLUMN_NAME** | NONE | Match file columns to table columns by name | `CASE_INSENSITIVE` for JSON/Parquet into typed tables |
| **ENFORCE_LENGTH** | TRUE | Error if string exceeds VARCHAR length | FALSE to silently truncate (same as TRUNCATECOLUMNS=TRUE) |
| **RETURN_FAILED_ONLY** | FALSE | Only show failed files in output | TRUE to focus on errors |
| **LOAD_UNCERTAIN_FILES** | FALSE | Load files with unknown load status (>64 days old) | TRUE if re-processing old files |
| **VALIDATION_MODE** | NULL | Validate without loading | `'RETURN_ERRORS'` to check for errors. `'RETURN_5_ROWS'` to preview |

### Example:
```sql
COPY INTO my_table
FROM @my_stage
FILE_FORMAT = csv_full_options
ON_ERROR = CONTINUE
PURGE = TRUE
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
```

---

## 10. REAL-WORLD PRODUCTION EXAMPLES

### 10.1 Standard CSV from data warehouse export
```sql
CREATE OR REPLACE FILE FORMAT fmt_standard_csv
  TYPE = 'CSV'
  FIELD_DELIMITER = ','
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  NULL_IF = ('', 'NULL', 'null', 'N/A', '#N/A')
  EMPTY_FIELD_AS_NULL = TRUE
  ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
  SKIP_BLANK_LINES = TRUE
  ESCAPE_UNENCLOSED_FIELD = NONE
  COMMENT = 'Standard CSV from ETL exports';
```

### 10.2 Tab-separated file from legacy system
```sql
CREATE OR REPLACE FILE FORMAT fmt_tsv_legacy
  TYPE = 'CSV'
  FIELD_DELIMITER = '\t'
  RECORD_DELIMITER = '\n'
  SKIP_HEADER = 0
  ENCODING = 'WINDOWS1252'
  NULL_IF = ('\\N', '')
  ESCAPE_UNENCLOSED_FIELD = NONE
  COMMENT = 'TSV from legacy Windows system with ANSI encoding';
```

### 10.3 NDJSON from Kafka / API streaming
```sql
CREATE OR REPLACE FILE FORMAT fmt_ndjson_kafka
  TYPE = 'JSON'
  COMPRESSION = AUTO
  STRIP_OUTER_ARRAY = FALSE
  MULTI_LINE = FALSE
  ALLOW_DUPLICATE = TRUE
  STRIP_NULL_VALUES = FALSE
  COMMENT = 'NDJSON (one JSON per line) from Kafka topics';
```

### 10.4 Parquet from Spark / Data Lake
```sql
CREATE OR REPLACE FILE FORMAT fmt_parquet_datalake
  TYPE = 'PARQUET'
  COMPRESSION = AUTO
  USE_VECTORIZED_SCANNER = TRUE
  BINARY_AS_TEXT = FALSE
  COMMENT = 'Parquet from Spark/Delta Lake with vectorized scanner';
```

### 10.5 Avro from Kafka with Schema Registry
```sql
CREATE OR REPLACE FILE FORMAT fmt_avro_kafka
  TYPE = 'AVRO'
  COMPRESSION = AUTO
  COMMENT = 'Avro files from Kafka with embedded schema';
```

### 10.6 XML from SOAP API
```sql
CREATE OR REPLACE FILE FORMAT fmt_xml_soap
  TYPE = 'XML'
  STRIP_OUTER_ELEMENT = TRUE
  PRESERVE_SPACE = FALSE
  DISABLE_AUTO_CONVERT = FALSE
  COMMENT = 'XML responses from SOAP APIs';
```

---

## 11. MANAGING FILE FORMATS

```sql
-- Create
CREATE OR REPLACE FILE FORMAT my_format TYPE = 'CSV' FIELD_DELIMITER = '|';

-- Describe (see all option values)
DESCRIBE FILE FORMAT my_format;

-- Show all file formats in current schema
SHOW FILE FORMATS;

-- Show file formats in a specific schema
SHOW FILE FORMATS IN SCHEMA my_db.my_schema;

-- Alter (change options)
ALTER FILE FORMAT my_format SET SKIP_HEADER = 1 NULL_IF = ('NULL', '');

-- Drop
DROP FILE FORMAT my_format;

-- Use inline (without named format)
COPY INTO my_table
FROM @my_stage
FILE_FORMAT = (TYPE = 'CSV' FIELD_DELIMITER = '|' SKIP_HEADER = 1);
```

---

## 12. FORMAT TYPE SELECTION GUIDE

### Decision Tree:

```
┌── Is the data structured (rows + columns)?
│    └── YES → CSV (or TSV, pipe-delimited)
│
├── Is it from an API or document store?
│    └── YES → JSON
│
├── Is it from Spark, Delta Lake, or data lake?
│    └── YES → PARQUET
│
├── Is it from Kafka with Schema Registry?
│    └── YES → AVRO
│
├── Is it from Hive / Hadoop ecosystem?
│    └── YES → ORC
│
└── Is it from a SOAP API or legacy enterprise system?
     └── YES → XML
```

### Performance Ranking (fastest to slowest for loading):

1. **PARQUET** — columnar, compressed, vectorized scanner
2. **ORC** — columnar, compressed, self-describing
3. **AVRO** — row-based, compressed, schema embedded
4. **CSV** — text, parallel scan possible with MULTI_LINE=FALSE
5. **JSON** — text, must parse structure
6. **XML** — text, most complex parsing

### Loading vs Unloading Support:

| FORMAT | LOADING | UNLOADING |
|--------|---------|-----------|
| CSV | ✓ | ✓ |
| JSON | ✓ | ✓ |
| PARQUET | ✓ | ✓ |
| AVRO | ✓ | ✗ |
| ORC | ✓ | ✗ |
| XML | ✓ | ✗ |

---

## 13. INTERVIEW QUESTIONS

### BEGINNER:

**Q1: What file formats does Snowflake support?**
> CSV, JSON, PARQUET, AVRO, ORC, XML.

**Q2: What is the default file format type?**
> CSV.

**Q3: What does SKIP_HEADER do?**
> Skips the specified number of lines at the start of the file (usually 1 for header row).

**Q4: What does STRIP_OUTER_ARRAY do for JSON?**
> Removes the outer `[ ]` brackets so each JSON object loads as a separate row instead of the entire array as one row.

**Q5: What is the difference between inline and named file formats?**
> Inline: options specified directly in COPY INTO (one-time use). Named: CREATE FILE FORMAT object, reusable across multiple loads.

---

### INTERMEDIATE:

**Q6: What is NULL_IF and when do you use it?**
> A list of strings that Snowflake converts to SQL NULL during loading. Use when source files represent NULL as `'NULL'`, `'N/A'`, `''`, `'None'`, etc.

**Q7: What is FIELD_OPTIONALLY_ENCLOSED_BY?**
> Specifies the character that wraps string fields (usually double quote). This prevents delimiters inside quotes from splitting the field. For example, `"New York, NY"` — without it, the comma splits into two columns.

**Q8: Why would you set MULTI_LINE = FALSE for CSV?**
> Enables parallel scanning for large (>128MB) uncompressed CSV files. Snowflake can split the file and process chunks simultaneously. Only works with COMPRESSION=NONE and ABORT_STATEMENT/CONTINUE.

**Q9: What is the difference between AVRO and PARQUET?**
> AVRO: Row-based, schema embedded, good for streaming (Kafka). PARQUET: Column-based, good for analytics (read specific columns). AVRO = write-optimized. PARQUET = read-optimized.

**Q10: What does USE_VECTORIZED_SCANNER do for Parquet?**
> Uses an optimized columnar reader that only downloads the columns you need. Significantly faster for Parquet loading. Forces BINARY_AS_TEXT=FALSE and USE_LOGICAL_TYPE=TRUE.

---

### ADVANCED:

**Q11: A CSV file has trailing backslashes causing rows to merge. How do you fix it?**
> Set `ESCAPE_UNENCLOSED_FIELD = NONE`. The default is backslash (`\\`), which escapes the newline at the end of a row, merging it with the next row.

**Q12: How do you handle a JSON file where some records have duplicate keys?**
> Set `ALLOW_DUPLICATE = TRUE`. Snowflake keeps the last value for each duplicate key. FALSE (default) would throw an error.

**Q13: Your Parquet load has wrong timestamp types. How do you fix it?**
> Set `USE_LOGICAL_TYPE = TRUE` (and preferably `USE_VECTORIZED_SCANNER = TRUE`). Without logical types, Snowflake may interpret timestamps as raw integers.

**Q14: A CSV from a Japanese system has garbled characters. What do you check?**
> Set ENCODING to match the source encoding (e.g., `'SHIFTJIS'` or `'EUCJP'`). Snowflake converts to UTF-8 during load. Also consider `REPLACE_INVALID_CHARACTERS = TRUE` as a safety net.

**Q15: What is the precedence order when file format options are set in multiple places?**
> 1. COPY INTO statement (highest) → 2. Stage definition → 3. Table definition. Options set in COPY INTO override stage/table settings.

**Q16: You're loading 500GB of CSV data. How do you optimize?**
> - Split into multiple files (100-250MB each) for parallel loading
> - Set MULTI_LINE = FALSE, COMPRESSION = NONE for parallel scanning
> - Use ON_ERROR = CONTINUE to avoid full restarts on errors
> - Use a larger warehouse (more nodes = more parallel threads)
> - Or compress with GZIP for smaller transfer and auto-decompression

**Q17: What happens if you recreate a file format used by an external table?**
> The external table BREAKS. External tables link to file formats by internal ID, not by name. CREATE OR REPLACE generates a new ID. You must also recreate the external table.

**Q18: How do you validate files before actually loading them?**
> Use VALIDATION_MODE in the COPY command: `COPY INTO my_table ... VALIDATION_MODE = 'RETURN_ERRORS';` This checks for errors without loading any data.
