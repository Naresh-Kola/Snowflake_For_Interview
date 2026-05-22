# LATERAL FLATTEN COMPLETE GUIDE — JSON & XML in Snowflake

**What:** Turn nested/semi-structured data into regular table rows
**When:** Arrays, objects, or repeating elements inside VARIANT columns
**Why:** You can't JOIN, GROUP BY, or aggregate nested data directly

---

## TABLE OF CONTENTS

1. What is FLATTEN? (Syntax + Output Columns)
2. TABLE(FLATTEN(...)) vs LATERAL FLATTEN — When to Use Which
3. JSON: Simple Array Flatten
4. JSON: Flatten an Array of Objects
5. JSON: Nested Flatten (Array inside Array)
6. JSON: Multi-Nested Flatten (3 Levels Deep)
7. JSON: RECURSIVE + MODE Parameters
8. JSON: OUTER => TRUE (Keep Rows with Empty Arrays)
9. JSON: Discover All Keys in Unknown JSON
10. XML: Basics — PARSE_XML, XMLGET, $, @
11. XML: Flatten Repeating Elements
12. XML: Nested XML Flatten
13. XML: Attributes + Mixed Child Elements
14. REAL WORLD: Load Flattened JSON into a Relational Table
15. REAL WORLD: Load Flattened XML into a Relational Table
16. REAL WORLD: E-Commerce Order with Line Items (Multi-Nested)
17. Quick Reference Cheat Sheet

---

## 1. WHAT IS FLATTEN?

FLATTEN is a TABLE FUNCTION that takes a VARIANT, OBJECT, or ARRAY and explodes it into multiple rows — one row per element.

### Syntax

```sql
FLATTEN( INPUT => <expr>
         [, PATH => '<path>']
         [, OUTER => TRUE|FALSE]
         [, RECURSIVE => TRUE|FALSE]
         [, MODE => 'OBJECT'|'ARRAY'|'BOTH'] )
```

### Output Columns

| Column | Description |
|--------|-------------|
| SEQ | Unique sequence number per input row |
| KEY | Key name (for objects) or NULL (for arrays) |
| PATH | Full path to the element |
| INDEX | Array index (0-based) or NULL for objects |
| VALUE | The actual value at this position |
| THIS | The parent element being flattened |

---

## 2. TABLE(FLATTEN(...)) vs LATERAL FLATTEN

For a **SINGLE** level of flattening, both work identically:

```sql
SELECT * FROM TABLE(FLATTEN(INPUT => col))      -- standalone
SELECT * FROM t, LATERAL FLATTEN(INPUT => col)  -- correlated
```

For **NESTED** flattening (chain multiple FLATTENs), you **MUST** use LATERAL because the second FLATTEN needs to reference the first one's output.

> **Rule of thumb:** Always use LATERAL FLATTEN. It works everywhere.

---

## 3. JSON: SIMPLE ARRAY FLATTEN

```sql
CREATE OR REPLACE TABLE orders_json (
    order_id   INT,
    customer   VARCHAR(50),
    items      VARIANT
);

INSERT INTO orders_json
SELECT 1, 'Alice',  PARSE_JSON('["Laptop", "Mouse", "Keyboard"]')
UNION ALL
SELECT 2, 'Bob',    PARSE_JSON('["Monitor", "Webcam"]')
UNION ALL
SELECT 3, 'Charlie', PARSE_JSON('[]');
```

Flatten the items array: one row per item

```sql
SELECT
    o.order_id,
    o.customer,
    f.index  AS item_index,
    f.value::STRING AS item_name
FROM orders_json o,
     LATERAL FLATTEN(INPUT => o.items) f;
```

### Result

| ORDER_ID | CUSTOMER | ITEM_INDEX | ITEM_NAME |
|----------|----------|------------|-----------|
| 1 | Alice | 0 | Laptop |
| 1 | Alice | 1 | Mouse |
| 1 | Alice | 2 | Keyboard |
| 2 | Bob | 0 | Monitor |
| 2 | Bob | 1 | Webcam |

> Charlie's empty array produces NO rows — see OUTER below.

---

## 4. JSON: FLATTEN AN ARRAY OF OBJECTS

```sql
CREATE OR REPLACE TABLE invoices (
    invoice_id  INT,
    line_items  VARIANT
);

INSERT INTO invoices
SELECT 100, PARSE_JSON('[
    {"sku": "A1", "qty": 2, "price": 29.99},
    {"sku": "B3", "qty": 1, "price": 49.99},
    {"sku": "C7", "qty": 5, "price": 9.99}
]');
```

Each element in the array is an OBJECT — extract fields with `:` notation:

```sql
SELECT
    i.invoice_id,
    f.index                       AS line_number,
    f.value:sku::STRING           AS sku,
    f.value:qty::INT              AS quantity,
    f.value:price::NUMBER(10,2)   AS unit_price,
    f.value:qty::INT * f.value:price::NUMBER(10,2) AS line_total
FROM invoices i,
     LATERAL FLATTEN(INPUT => i.line_items) f;
```

---

## 5. JSON: NESTED FLATTEN (Array inside Array)

When an array contains objects that themselves contain arrays, you chain LATERAL FLATTENs. The second FLATTEN references the first.

```sql
CREATE OR REPLACE TABLE stores (
    store_id   INT,
    data       VARIANT
);

INSERT INTO stores
SELECT 1, PARSE_JSON('{
    "name": "Downtown Store",
    "departments": [
        {
            "dept": "Electronics",
            "products": ["TV", "Laptop", "Phone"]
        },
        {
            "dept": "Clothing",
            "products": ["Shirt", "Pants"]
        }
    ]
}');
```

Level 1: Flatten departments | Level 2: Flatten products within each department

```sql
SELECT
    s.store_id,
    s.data:name::STRING             AS store_name,
    d.value:dept::STRING            AS department,
    p.value::STRING                 AS product
FROM stores s,
     LATERAL FLATTEN(INPUT => s.data:departments) d,
     LATERAL FLATTEN(INPUT => d.value:products) p;
```

### Result

| STORE_ID | STORE_NAME | DEPARTMENT | PRODUCT |
|----------|------------|------------|---------|
| 1 | Downtown Store | Electronics | TV |
| 1 | Downtown Store | Electronics | Laptop |
| 1 | Downtown Store | Electronics | Phone |
| 1 | Downtown Store | Clothing | Shirt |
| 1 | Downtown Store | Clothing | Pants |

---

## 6. JSON: MULTI-NESTED FLATTEN (3 Levels Deep)

Company → Departments → Teams → Members

```sql
CREATE OR REPLACE TABLE companies (
    company_id  INT,
    data        VARIANT
);

INSERT INTO companies
SELECT 1, PARSE_JSON('{
    "company": "Acme Corp",
    "departments": [
        {
            "name": "Engineering",
            "teams": [
                {
                    "team": "Backend",
                    "members": ["Alice", "Bob"]
                },
                {
                    "team": "Frontend",
                    "members": ["Charlie"]
                }
            ]
        },
        {
            "name": "Sales",
            "teams": [
                {
                    "team": "Enterprise",
                    "members": ["Diana", "Eve", "Frank"]
                }
            ]
        }
    ]
}');
```

3 chained LATERAL FLATTENs:

```sql
SELECT
    c.data:company::STRING       AS company,
    dept.value:name::STRING      AS department,
    team.value:team::STRING      AS team,
    member.value::STRING         AS member_name
FROM companies c,
     LATERAL FLATTEN(INPUT => c.data:departments) dept,
     LATERAL FLATTEN(INPUT => dept.value:teams) team,
     LATERAL FLATTEN(INPUT => team.value:members) member;
```

### Result

| COMPANY | DEPARTMENT | TEAM | MEMBER_NAME |
|---------|------------|------|-------------|
| Acme Corp | Engineering | Backend | Alice |
| Acme Corp | Engineering | Backend | Bob |
| Acme Corp | Engineering | Frontend | Charlie |
| Acme Corp | Sales | Enterprise | Diana |
| Acme Corp | Sales | Enterprise | Eve |
| Acme Corp | Sales | Enterprise | Frank |

---

## 7. JSON: RECURSIVE + MODE PARAMETERS

RECURSIVE => TRUE flattens ALL levels at once (no chaining needed).
MODE controls what gets flattened: `'ARRAY'`, `'OBJECT'`, or `'BOTH'`.

See every leaf value in a deeply nested structure:

```sql
SELECT
    f.path,
    f.key,
    f.value,
    TYPEOF(f.value) AS value_type
FROM TABLE(FLATTEN(
    INPUT => PARSE_JSON('{
        "a": 1,
        "b": [10, 20],
        "c": {"d": "X", "e": {"f": 99}}
    }'),
    RECURSIVE => TRUE
)) f
WHERE TYPEOF(f.value) NOT IN ('OBJECT', 'ARRAY');
```

### Result (Only leaf scalar values)

| PATH | KEY | VALUE | VALUE_TYPE |
|------|-----|-------|------------|
| a | a | 1 | INTEGER |
| b[0] | NULL | 10 | INTEGER |
| b[1] | NULL | 20 | INTEGER |
| c.d | d | "X" | VARCHAR |
| c.e.f | f | 99 | INTEGER |

---

## 8. JSON: OUTER => TRUE (Keep Rows with Empty/NULL Arrays)

Without OUTER, rows with empty arrays are silently dropped.
With OUTER => TRUE, you get one row with NULLs instead.

```sql
SELECT
    o.order_id,
    o.customer,
    f.value::STRING AS item_name
FROM orders_json o,
     LATERAL FLATTEN(INPUT => o.items, OUTER => TRUE) f;
```

### Result

| ORDER_ID | CUSTOMER | ITEM_NAME |
|----------|----------|-----------|
| 1 | Alice | Laptop |
| ... | ... | ... |
| 3 | Charlie | NULL ← preserved by OUTER => TRUE |

---

## 9. JSON: DISCOVER ALL KEYS IN UNKNOWN JSON

When you receive JSON and don't know the schema, use RECURSIVE FLATTEN to list every unique path and its data type.

```sql
SELECT
    REGEXP_REPLACE(f.path, '\\[[0-9]+\\]', '[]') AS path_pattern,
    TYPEOF(f.value) AS data_type,
    COUNT(*) AS occurrences
FROM companies c,
     LATERAL FLATTEN(INPUT => c.data, RECURSIVE => TRUE) f
GROUP BY 1, 2
ORDER BY 1, 2;
```

---

## 10. XML: BASICS — PARSE_XML, XMLGET, $, @

Snowflake stores XML as VARIANT (OBJECT) using PARSE_XML.

### Key Operators

| Operator | Purpose |
|----------|---------|
| `:"$"` | Content of an element (text or child array) |
| `:"@"` | Tag name of the element |
| `:"@attr"` | Value of attribute named 'attr' |
| `XMLGET(xml, 'tag', index)` | Extract child element by name |

```sql
CREATE OR REPLACE TABLE xml_simple (id INT, xml_data VARIANT);

INSERT INTO xml_simple
SELECT 1, PARSE_XML(
    '<bookstore>
        <book category="fiction">
            <title>The Great Gatsby</title>
            <author>F. Scott Fitzgerald</author>
            <price>10.99</price>
        </book>
    </bookstore>'
);
```

Extract values using XMLGET and $ operator:

```sql
SELECT
    XMLGET(xml_data, 'book'):"@category"::STRING   AS category,
    XMLGET(XMLGET(xml_data, 'book'), 'title'):"$"::STRING    AS title,
    XMLGET(XMLGET(xml_data, 'book'), 'author'):"$"::STRING   AS author,
    XMLGET(XMLGET(xml_data, 'book'), 'price'):"$"::FLOAT     AS price
FROM xml_simple;
```

### Result

| CATEGORY | TITLE | AUTHOR | PRICE |
|----------|-------|--------|-------|
| fiction | The Great Gatsby | F. Scott Fitzgerald | 10.99 |

---

## 11. XML: FLATTEN REPEATING ELEMENTS

When XML has multiple child elements under a parent, use LATERAL FLATTEN on the parent's content (`:"$"`) to iterate through them.

```sql
CREATE OR REPLACE TABLE xml_catalog (id INT, xml_data VARIANT);

INSERT INTO xml_catalog
SELECT 1, PARSE_XML(
    '<catalog issue="spring">
        <book id="bk101">
            <title>SQL Mastery</title>
            <price>29.99</price>
        </book>
        <book id="bk102">
            <title>Data Pipelines</title>
            <price>39.99</price>
        </book>
        <book id="bk103">
            <title>Cloud Architecture</title>
            <price>49.99</price>
        </book>
    </catalog>'
);
```

Flatten all `<book>` elements:

```sql
SELECT
    x.xml_data:"@issue"::STRING          AS issue,
    f.value:"@id"::STRING                AS book_id,
    XMLGET(f.value, 'title'):"$"::STRING AS title,
    XMLGET(f.value, 'price'):"$"::FLOAT  AS price
FROM xml_catalog x,
     LATERAL FLATTEN(INPUT => x.xml_data:"$") f
WHERE f.value:"@"::STRING = 'book';
```

### Result

| ISSUE | BOOK_ID | TITLE | PRICE |
|-------|---------|-------|-------|
| spring | bk101 | SQL Mastery | 29.99 |
| spring | bk102 | Data Pipelines | 39.99 |
| spring | bk103 | Cloud Architecture | 49.99 |

---

## 12. XML: NESTED XML FLATTEN

`<company>` → `<department>` → `<employee>`

```sql
CREATE OR REPLACE TABLE xml_nested (id INT, xml_data VARIANT);

INSERT INTO xml_nested
SELECT 1, PARSE_XML(
    '<company name="TechCo">
        <department name="Engineering">
            <employee>
                <name>Alice</name>
                <role>Backend</role>
            </employee>
            <employee>
                <name>Bob</name>
                <role>Frontend</role>
            </employee>
        </department>
        <department name="Marketing">
            <employee>
                <name>Charlie</name>
                <role>Content</role>
            </employee>
        </department>
    </company>'
);
```

Level 1: Flatten departments | Level 2: Flatten employees within each department

```sql
SELECT
    x.xml_data:"@name"::STRING                    AS company,
    dept.value:"@name"::STRING                     AS department,
    XMLGET(emp.value, 'name'):"$"::STRING          AS employee_name,
    XMLGET(emp.value, 'role'):"$"::STRING          AS role
FROM xml_nested x,
     LATERAL FLATTEN(INPUT => x.xml_data:"$") dept,
     LATERAL FLATTEN(INPUT => dept.value:"$") emp
WHERE dept.value:"@"::STRING = 'department'
  AND emp.value:"@"::STRING = 'employee';
```

### Result

| COMPANY | DEPARTMENT | EMPLOYEE_NAME | ROLE |
|---------|------------|---------------|------|
| TechCo | Engineering | Alice | Backend |
| TechCo | Engineering | Bob | Frontend |
| TechCo | Marketing | Charlie | Content |

---

## 13. XML: ATTRIBUTES + MIXED CHILD ELEMENTS

```sql
CREATE OR REPLACE TABLE xml_mixed (id INT, xml_data VARIANT);

INSERT INTO xml_mixed
SELECT 1, PARSE_XML(
    '<order id="ORD-001" currency="USD">
        <customer>John Doe</customer>
        <item sku="A1" qty="2">Laptop</item>
        <item sku="B3" qty="1">Mouse</item>
        <item sku="C7" qty="3">Cable</item>
    </order>'
);
```

```sql
SELECT
    x.xml_data:"@id"::STRING             AS order_id,
    x.xml_data:"@currency"::STRING       AS currency,
    XMLGET(x.xml_data, 'customer'):"$"::STRING AS customer,
    f.value:"@sku"::STRING               AS sku,
    f.value:"@qty"::INT                  AS quantity,
    f.value:"$"::STRING                  AS item_name
FROM xml_mixed x,
     LATERAL FLATTEN(INPUT => x.xml_data:"$") f
WHERE f.value:"@"::STRING = 'item';
```

### Result

| ORDER_ID | CURRENCY | CUSTOMER | SKU | QUANTITY | ITEM_NAME |
|----------|----------|----------|-----|----------|-----------|
| ORD-001 | USD | John Doe | A1 | 2 | Laptop |
| ORD-001 | USD | John Doe | B3 | 1 | Mouse |
| ORD-001 | USD | John Doe | C7 | 3 | Cable |

---

## 14. REAL WORLD: LOAD FLATTENED JSON INTO A RELATIONAL TABLE

Pattern: Raw JSON → VARIANT staging table → FLATTEN → relational table

```sql
CREATE OR REPLACE TABLE raw_events (event_data VARIANT);

INSERT INTO raw_events
SELECT PARSE_JSON('{
    "event_id": "E001",
    "timestamp": "2026-05-14T10:30:00Z",
    "user": {"id": 42, "name": "Alice"},
    "actions": [
        {"type": "click", "target": "buy_button", "ts": "2026-05-14T10:30:01Z"},
        {"type": "scroll", "target": "product_list", "ts": "2026-05-14T10:30:05Z"},
        {"type": "click", "target": "add_cart", "ts": "2026-05-14T10:30:08Z"}
    ]
}');

CREATE OR REPLACE TABLE user_actions (
    event_id     VARCHAR,
    event_ts     TIMESTAMP_NTZ,
    user_id      INT,
    user_name    VARCHAR,
    action_type  VARCHAR,
    target       VARCHAR,
    action_ts    TIMESTAMP_NTZ
);

INSERT INTO user_actions
SELECT
    e.event_data:event_id::STRING,
    e.event_data:timestamp::TIMESTAMP_NTZ,
    e.event_data:user.id::INT,
    e.event_data:user.name::STRING,
    a.value:type::STRING,
    a.value:target::STRING,
    a.value:ts::TIMESTAMP_NTZ
FROM raw_events e,
     LATERAL FLATTEN(INPUT => e.event_data:actions) a;

SELECT * FROM user_actions;
```

---

## 15. REAL WORLD: LOAD FLATTENED XML INTO A RELATIONAL TABLE

```sql
CREATE OR REPLACE TABLE raw_xml_orders (xml_data VARIANT);

INSERT INTO raw_xml_orders
SELECT PARSE_XML(
    '<orders>
        <order id="1001" date="2026-05-10">
            <customer>Alice</customer>
            <item>Laptop</item>
            <item>Mouse</item>
        </order>
        <order id="1002" date="2026-05-11">
            <customer>Bob</customer>
            <item>Monitor</item>
        </order>
    </orders>'
);

CREATE OR REPLACE TABLE order_items_flat (
    order_id    VARCHAR,
    order_date  DATE,
    customer    VARCHAR,
    item_name   VARCHAR
);

INSERT INTO order_items_flat
SELECT
    ord.value:"@id"::STRING,
    ord.value:"@date"::DATE,
    XMLGET(ord.value, 'customer'):"$"::STRING,
    itm.value:"$"::STRING
FROM raw_xml_orders x,
     LATERAL FLATTEN(INPUT => x.xml_data:"$") ord,
     LATERAL FLATTEN(INPUT => ord.value:"$") itm
WHERE ord.value:"@"::STRING = 'order'
  AND itm.value:"@"::STRING = 'item';

SELECT * FROM order_items_flat;
```

### Result

| ORDER_ID | ORDER_DATE | CUSTOMER | ITEM_NAME |
|----------|------------|----------|-----------|
| 1001 | 2026-05-10 | Alice | Laptop |
| 1001 | 2026-05-10 | Alice | Mouse |
| 1002 | 2026-05-11 | Bob | Monitor |

---

## 16. REAL WORLD: E-COMMERCE ORDER (Multi-Nested JSON → Relational)

Order → Line Items → each item has tags (3 levels)

```sql
CREATE OR REPLACE TABLE raw_ecommerce (payload VARIANT);

INSERT INTO raw_ecommerce
SELECT PARSE_JSON('{
    "order_id": "ORD-9001",
    "customer": {"id": 500, "email": "jane@example.com"},
    "shipping": {"method": "express", "cost": 12.99},
    "items": [
        {
            "sku": "LAPTOP-01",
            "name": "Pro Laptop",
            "qty": 1,
            "price": 1299.99,
            "tags": ["electronics", "computers", "sale"]
        },
        {
            "sku": "CASE-05",
            "name": "Laptop Case",
            "qty": 2,
            "price": 29.99,
            "tags": ["accessories"]
        }
    ]
}');

CREATE OR REPLACE TABLE ecommerce_item_tags (
    order_id       VARCHAR,
    customer_email VARCHAR,
    shipping       VARCHAR,
    sku            VARCHAR,
    item_name      VARCHAR,
    qty            INT,
    price          NUMBER(10,2),
    tag            VARCHAR
);

INSERT INTO ecommerce_item_tags
SELECT
    r.payload:order_id::STRING,
    r.payload:customer.email::STRING,
    r.payload:shipping.method::STRING,
    item.value:sku::STRING,
    item.value:name::STRING,
    item.value:qty::INT,
    item.value:price::NUMBER(10,2),
    tag.value::STRING
FROM raw_ecommerce r,
     LATERAL FLATTEN(INPUT => r.payload:items) item,
     LATERAL FLATTEN(INPUT => item.value:tags) tag;

SELECT * FROM ecommerce_item_tags;
```

### Result

| ORDER_ID | CUSTOMER_EMAIL | SHIPPING | SKU | ITEM_NAME | QTY | PRICE | TAG |
|----------|----------------|----------|-----|-----------|-----|-------|-----|
| ORD-9001 | jane@example.com | express | LAPTOP-01 | Pro Laptop | 1 | 1299.99 | electronics |
| ORD-9001 | jane@example.com | express | LAPTOP-01 | Pro Laptop | 1 | 1299.99 | computers |
| ORD-9001 | jane@example.com | express | LAPTOP-01 | Pro Laptop | 1 | 1299.99 | sale |
| ORD-9001 | jane@example.com | express | CASE-05 | Laptop Case | 2 | 29.99 | accessories |

---

## 17. QUICK REFERENCE CHEAT SHEET

### JSON

| Pattern | Syntax |
|---------|--------|
| Simple array | `LATERAL FLATTEN(INPUT => col)` |
| Array of objects | `f.value:key::TYPE` |
| Nested path | `LATERAL FLATTEN(INPUT => col, PATH => 'a.b')` |
| Nested arrays | Chain multiple LATERAL FLATTENs |
| Keep empty rows | `OUTER => TRUE` |
| All levels | `RECURSIVE => TRUE` |
| Only arrays | `MODE => 'ARRAY'` |
| Only objects | `MODE => 'OBJECT'` |

### XML

| Pattern | Syntax |
|---------|--------|
| Parse | `PARSE_XML('<xml>...</xml>')` |
| Tag content | `XMLGET(xml, 'tag'):"$"` |
| Tag name | `element:"@"` |
| Attribute | `element:"@attr_name"` |
| Flatten children | `LATERAL FLATTEN(INPUT => xml:"$")` |
| Filter by tag | `WHERE f.value:"@"::STRING = 'tag_name'` |
| Nested XML | Chain FLATTENs + filter with "@" on each level |

### Output Columns

| Column | Description |
|--------|-------------|
| SEQ | Unique sequence per input row |
| KEY | Object key (NULL for arrays) |
| PATH | Dot-notation path to element |
| INDEX | Array position (0-based, NULL for objects) |
| VALUE | The actual element value |
| THIS | The parent being flattened |

### Golden Rules

1. Always use LATERAL FLATTEN (not TABLE(FLATTEN)) for safety
2. Always CAST values: `f.value:key::STRING` (not just `f.value:key`)
3. Use OUTER => TRUE if rows with empty arrays matter
4. For XML, filter with `WHERE f.value:"@"::STRING = 'tag'`
5. For nested: chain FLATTENs, each referencing the previous
6. Use RECURSIVE => TRUE only for exploration, not production

---

## CLEANUP

```sql
-- Uncomment to drop all demo tables
-- DROP TABLE IF EXISTS orders_json;
-- DROP TABLE IF EXISTS invoices;
-- DROP TABLE IF EXISTS stores;
-- DROP TABLE IF EXISTS companies;
-- DROP TABLE IF EXISTS xml_simple;
-- DROP TABLE IF EXISTS xml_catalog;
-- DROP TABLE IF EXISTS xml_nested;
-- DROP TABLE IF EXISTS xml_mixed;
-- DROP TABLE IF EXISTS raw_events;
-- DROP TABLE IF EXISTS user_actions;
-- DROP TABLE IF EXISTS raw_xml_orders;
-- DROP TABLE IF EXISTS order_items_flat;
-- DROP TABLE IF EXISTS raw_ecommerce;
-- DROP TABLE IF EXISTS ecommerce_item_tags;
```
