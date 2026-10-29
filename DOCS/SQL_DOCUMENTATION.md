# SQL Documentation

PostgreSQL implementation of the Olist e-commerce analysis: environment, schema, data loading, quality audit, views, and the full catalogue of analysis queries.

## Contents

1. [Environment](#1-environment)
2. [Conventions and Definitions](#2-conventions-and-definitions)
3. [Schema](#3-schema)
4. [Data Loading](#4-data-loading)
5. [Data Quality Audit](#5-data-quality-audit)
6. [Views](#6-views)
7. [Analysis Query Catalogue](#7-analysis-query-catalogue)
8. [Performance](#8-performance)
9. [Known Data Issues](#9-known-data-issues)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Environment

| Item | Value |
|---|---|
| Database engine | PostgreSQL 18 |
| Client | pgAdmin 4 (Query Tool, Import/Export Data) |
| Database | `OLIST_ANALYSIS` (created in upper case, so it must be quoted or typed exactly in some clients) |
| Schema | `olist` |
| Encoding | UTF8 |

Create the schema before the tables:

```sql
CREATE SCHEMA IF NOT EXISTS olist;
SET search_path TO olist;
```

## 2. Conventions and Definitions

| Topic | Rule |
|---|---|
| Naming | Lowercase snake_case, schema-qualified (`olist.orders`) |
| Revenue | `SUM(price)` from items, excluding orders with status `canceled` or `unavailable`. Freight is excluded and analysed separately |
| Orders | `COUNT(DISTINCT order_id)` |
| Customers | Identify people by `customer_unique_id`. `customer_id` is created per order |
| Delivery metrics | Only orders with `order_status = 'delivered'` and a non-null `order_delivered_customer_date` |
| Late delivery | `order_delivered_customer_date > order_estimated_delivery_date` |
| Reviews | One review per order, using the view `reviews_clean` |
| Joins | Never join `order_items` to `order_payments` directly (different grain). Aggregate first |
| Original column spellings | `product_name_lenght` and `product_description_lenght` keep the dataset's spelling |

## 3. Schema

### 3.1 Tables

| Table | Grain | Primary key | Rows (approx.) |
|---|---|---|---|
| `customers` | One row per order's customer record | `customer_id` | 99,441 |
| `sellers` | One row per seller | `seller_id` | 3,095 |
| `category_translation` | One row per category | `product_category_name` | 71 |
| `products` | One row per product | `product_id` | 32,951 |
| `orders` | One row per order | `order_id` | 99,441 |
| `order_items` | One row per item in an order | (`order_id`, `order_item_id`) | 112,650 |
| `order_payments` | One row per payment per order | (`order_id`, `payment_sequential`) | 103,886 |
| `order_reviews` | One row per review (not unique per order) | none | 99,224 |
| `geolocation` | Many rows per zip prefix | none | about 1,000,163 |

### 3.2 Relationships

| Child table | Column | Parent table | Column |
|---|---|---|---|
| `orders` | `customer_id` | `customers` | `customer_id` |
| `order_items` | `order_id` | `orders` | `order_id` |
| `order_items` | `product_id` | `products` | `product_id` |
| `order_items` | `seller_id` | `sellers` | `seller_id` |
| `order_payments` | `order_id` | `orders` | `order_id` |
| `order_reviews` | `order_id` | `orders` | `order_id` |

Because of these foreign keys, load order matters (see section 4).

### 3.3 Column data types

| Column pattern | Type |
|---|---|
| IDs (`order_id`, `customer_id`, `product_id`, `seller_id`, `review_id`) | `VARCHAR(32)` |
| State codes | `CHAR(2)` or `VARCHAR(2)` |
| Zip prefixes, counts, installments, scores, dimensions | `INTEGER` |
| Timestamps | `TIMESTAMP` (without time zone) |
| `price`, `freight_value`, `payment_value` | `NUMERIC(10,2)` |
| Latitude and longitude | `DOUBLE PRECISION` |
| Cities, categories, status, comments | `TEXT` |

## 4. Data Loading

### 4.1 Order

| Step | Table | Source file | Expected rows |
|---|---|---|---|
| 1 | `customers` | `olist_customers_dataset.csv` | 99,441 |
| 2 | `sellers` | `olist_sellers_dataset.csv` | 3,095 |
| 3 | `category_translation` | `product_category_name_translation.csv` | 71 |
| 4 | `products` | `olist_products_dataset.csv` | 32,951 |
| 5 | `orders` | `olist_orders_dataset.csv` | 99,441 |
| 6 | `order_items` | `olist_order_items_dataset.csv` | 112,650 |
| 7 | `order_payments` | `olist_order_payments_dataset.csv` | 103,886 |
| 8 | `order_reviews` | `olist_order_reviews_dataset.csv` | 99,224 |
| 9 | `geolocation` | `olist_geolocation_dataset.csv` | about 1,000,163 |

### 4.2 Import settings (pgAdmin Import/Export Data)

| Option | Value |
|---|---|
| Format | csv |
| Encoding | UTF8 |
| Header | ON |
| Delimiter | `,` |
| Quote | `"` |
| Escape | `"` |
| On error | Stop |

The escape character must be a double quote. Review comments contain quotes and line breaks, and the wrong escape setting breaks `order_reviews`.

Equivalent `psql` command:

```sql
\copy olist.customers FROM '/path/olist_customers_dataset.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', QUOTE '"', ESCAPE '"', ENCODING 'UTF8')
```

### 4.3 Verification

```sql
SELECT 'customers' AS tbl, COUNT(*) AS n FROM olist.customers
UNION ALL SELECT 'sellers', COUNT(*) FROM olist.sellers
UNION ALL SELECT 'category_translation', COUNT(*) FROM olist.category_translation
UNION ALL SELECT 'products', COUNT(*) FROM olist.products
UNION ALL SELECT 'orders', COUNT(*) FROM olist.orders
UNION ALL SELECT 'order_items', COUNT(*) FROM olist.order_items
UNION ALL SELECT 'order_payments', COUNT(*) FROM olist.order_payments
UNION ALL SELECT 'order_reviews', COUNT(*) FROM olist.order_reviews
UNION ALL SELECT 'geolocation', COUNT(*) FROM olist.geolocation;
```

## 5. Data Quality Audit

Run before any analysis. Record the results in the table at the end of this section.

| # | Check | Query |
|---|---|---|
| 1 | Order status mix | `SELECT order_status, COUNT(*) FROM olist.orders GROUP BY 1 ORDER BY 2 DESC;` |
| 2 | Date coverage | `SELECT MIN(order_purchase_timestamp), MAX(order_purchase_timestamp) FROM olist.orders;` |
| 3 | Delivered but no delivery date | `SELECT COUNT(*) FROM olist.orders WHERE order_status='delivered' AND order_delivered_customer_date IS NULL;` |
| 4 | Delivered before purchased | `SELECT COUNT(*) FROM olist.orders WHERE order_delivered_customer_date < order_purchase_timestamp;` |
| 5 | Orders with several reviews | `SELECT COUNT(*) FROM (SELECT order_id FROM olist.order_reviews GROUP BY 1 HAVING COUNT(*)>1) t;` |
| 6 | Products without category | `SELECT COUNT(*) FROM olist.products WHERE product_category_name IS NULL;` |
| 7 | Categories missing a translation | see below |
| 8 | Orders without items | see below |

```sql
-- Check 7
SELECT DISTINCT p.product_category_name
FROM olist.products p
LEFT JOIN olist.category_translation t USING (product_category_name)
WHERE t.product_category_name IS NULL AND p.product_category_name IS NOT NULL;

-- Check 8
SELECT COUNT(*) FROM olist.orders o
LEFT JOIN olist.order_items oi USING (order_id)
WHERE oi.order_id IS NULL;
```

### Audit results (fill in)

| # | Result | Handling |
|---|---|---|
| 1 | `<delivered X%, canceled Y, ...>` | Exclude `canceled` and `unavailable` from revenue |
| 2 | `<min date> to <max date>` | Restrict trend charts to complete months |
| 3 | `<n>` | Excluded from delivery metrics |
| 4 | `<n>` | Excluded from delivery metrics |
| 5 | `<n>` orders | Latest review kept (`reviews_clean`) |
| 6 | `<n>` products | Labelled `unknown` |
| 7 | `<n>` categories | Fall back to the Portuguese name |
| 8 | `<n>` orders | Present in `orders`, absent from item-based revenue |

## 6. Views

Raw tables are left untouched. Cleaning is done in views.

### `geo_zip`: one coordinate per zip prefix

```sql
CREATE OR REPLACE VIEW olist.geo_zip AS
SELECT geolocation_zip_code_prefix AS zip_prefix,
       AVG(geolocation_lat) AS lat,
       AVG(geolocation_lng) AS lng
FROM olist.geolocation
GROUP BY 1;
```

### `reviews_clean`: one review per order

```sql
CREATE OR REPLACE VIEW olist.reviews_clean AS
SELECT DISTINCT ON (order_id) order_id, review_score, review_creation_date
FROM olist.order_reviews
ORDER BY order_id, review_answer_timestamp DESC NULLS LAST;
```

### `fact_items`: item-level fact table

```sql
CREATE OR REPLACE VIEW olist.fact_items AS
SELECT oi.order_id, oi.order_item_id, oi.product_id, oi.seller_id,
       oi.price, oi.freight_value, o.order_status,
       o.order_purchase_timestamp, c.customer_unique_id, c.customer_state,
       COALESCE(t.product_category_name_english, p.product_category_name, 'unknown') AS category
FROM olist.order_items oi
JOIN olist.orders o USING (order_id)
JOIN olist.customers c USING (customer_id)
JOIN olist.products p USING (product_id)
LEFT JOIN olist.category_translation t USING (product_category_name);
```

Check: `SELECT COUNT(*) FROM olist.fact_items;` should return 112,650.

## 7. Analysis Query Catalogue

Each query is saved in `sql/05_analysis.sql` with its ID in a comment header.

| ID | Area | Business question | Main objects | Key technique |
|---|---|---|---|---|
| 1 | Sales | Monthly revenue, orders, AOV, and month-on-month growth | `fact_items` | CTE, `date_trunc`, `LAG` |
| 2a | Products | Top 15 categories by revenue and share | `fact_items` | `SUM() OVER ()` |
| 2b | Products | Freight as a percentage of price by category | `fact_items` | `HAVING` threshold |
| 3a | Delivery | Overall delivery days, estimated days, late % | `orders` | `EXTRACT(EPOCH ...)` |
| 3b | Delivery | Delivery speed and lateness by customer state | `orders`, `customers` | Boolean average |
| 4a | Reviews | Distribution of review scores | `reviews_clean` | Window percentage |
| 4b | Reviews | Average score for late vs on-time orders | `orders`, `reviews_clean` | `CASE` grouping |
| 4c | Reviews | Average score by lateness bucket | `orders`, `reviews_clean` | Bucketing subquery |
| 4d | Reviews | Worst-rated categories | `fact_items`, `reviews_clean` | `HAVING` threshold |
| 5a | Customers | Repeat purchase rate | `orders`, `customers` | `FILTER` aggregate |
| 5b | Customers | Rule-based customer segments | `fact_items` | CTEs, recency rules |
| 5c | Customers | Monthly cohort retention | `fact_items` | Cohort CTEs, `age()` |
| 6a | Sellers | Top 20 sellers with average review score | `order_items`, `reviews_clean` | `HAVING` threshold |
| 6b | Sellers | Revenue share of the top 10% of sellers | `fact_items` | Cumulative window sum |
| 6c | Sellers | Revenue and sellers by seller state | `order_items`, `sellers` | Aggregation |
| 7a | Payments | Payment type share and average payment | `order_payments` | Window share |
| 7b | Payments | Credit card installment groups | `order_payments` | `CASE` bucketing |
| 8a | Geography | Revenue and freight by customer state | `fact_items` | Window share |
| 8b | Geography | Same-state vs cross-state freight and delivery time | `order_items`, `orders`, `customers`, `sellers` | Conditional grouping |
| 9 | Extra | Orders by weekday and hour | `orders` | `EXTRACT(DOW/HOUR)` |
| 10 | Extra | Delivery time split by stage | `orders` | Timestamp differences |
| 11 | Extra | Black Friday 2017 daily sales | `fact_items` | Date filter |

### Notes on specific queries

- **5b segments.** Almost every customer has one order, so quintile-based RFM is not meaningful. Segments use rules: active repeat, lapsed repeat, recent one-time, cooling one-time, lost one-time. The reference date is the latest order date plus one day.
- **5c cohorts.** `months_since_first` is calculated in its own CTE and grouped there. Using the expression directly in `HAVING` raises error `42803` (column must appear in the GROUP BY clause).
- **6b.** The share is computed from a cumulative revenue window ordered by revenue descending, taking sellers up to the top 10% by rank.

## 8. Performance

Indexes on join and filter columns:

```sql
CREATE INDEX idx_orders_customer ON olist.orders(customer_id);
CREATE INDEX idx_orders_purchase ON olist.orders(order_purchase_timestamp);
CREATE INDEX idx_items_product   ON olist.order_items(product_id);
CREATE INDEX idx_items_seller    ON olist.order_items(seller_id);
CREATE INDEX idx_reviews_order   ON olist.order_reviews(order_id);
CREATE INDEX idx_payments_order  ON olist.order_payments(order_id);
```

Use `EXPLAIN ANALYZE` to inspect slow queries.

## 9. Known Data Issues

| Issue | Impact | Handling |
|---|---|---|
| `customer_id` is unique per order | Repeat buyers cannot be found with it | Use `customer_unique_id` |
| `review_id` repeats; some orders have several reviews | Double counting in joins | `reviews_clean` keeps the latest review |
| `geolocation` has about 1M rows with many per zip | Join fan-out | `geo_zip` averages per zip |
| Two product categories have no English translation | Missing labels | `COALESCE` to the Portuguese name |
| Products without a category | Unclassified revenue | Labelled `unknown` |
| Partial first and last months | Misleading trends | Restrict trend analysis to complete months |
| Items and payments have different grain | Inflated totals if joined | Aggregate each separately |

## 10. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `no schema has been selected to create in` | Schema `olist` does not exist | `CREATE SCHEMA IF NOT EXISTS olist;` |
| `violates foreign key constraint ... is not present in table "orders"` | Child table loaded before its parent | Follow the load order in section 4.1 |
| `duplicate key value violates unique constraint` | File imported twice or wrong key | `TRUNCATE` the table and reload; check composite keys |
| `invalid input syntax for type ...` | Column order or type mismatch with the CSV | Compare table columns with the CSV header order |
| Import succeeds but review text is garbled | Wrong quote or escape character | Set both to `"` |
| `column ... must appear in the GROUP BY clause` | Expression used in `HAVING` without grouping | Compute it in a CTE, then group |
| `database "..." does not exist` from another tool | Name was created in upper case | Use `OLIST_ANALYSIS` exactly |
