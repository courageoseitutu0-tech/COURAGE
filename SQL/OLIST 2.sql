SELECT COUNT(*) FROM (
  SELECT order_id FROM olist.order_reviews GROUP BY 1 HAVING COUNT(*) > 1

SELECT COUNT(*) FROM olist.orders o
LEFT JOIN olist.order_items oi USING (order_id)
WHERE oi.order_id IS NULL;

SELECT DISTINCT p.product_category_name
FROM olist.products p
LEFT JOIN olist.category_translation t USING (product_category_name)
WHERE t.product_category_name IS NULL AND p.product_category_name IS NOT NULL;

SET search_path TO olist;

CREATE OR REPLACE VIEW geo_zip AS
SELECT geolocation_zip_code_prefix AS zip_prefix,
       AVG(geolocation_lat) AS lat,
       AVG(geolocation_lng) AS lng
FROM geolocation
GROUP BY 1;

-- One review per order (the latest)
CREATE OR REPLACE VIEW reviews_clean AS
SELECT DISTINCT ON (order_id) order_id, review_score, review_creation_date
FROM order_reviews
ORDER BY order_id, review_answer_timestamp DESC NULLS LAST;

-- Item-level fact table with English category names
CREATE OR REPLACE VIEW fact_items AS
SELECT oi.order_id, oi.order_item_id, oi.product_id, oi.seller_id,
       oi.price, oi.freight_value, o.order_status,
       o.order_purchase_timestamp, c.customer_unique_id, c.customer_state,
       COALESCE(t.product_category_name_english, p.product_category_name, 'unknown') AS category
FROM order_items oi
JOIN orders o USING (order_id)
JOIN customers c USING (customer_id)
JOIN products p USING (product_id)
LEFT JOIN category_translation t USING (product_category_name);

SELECT COUNT(*) FROM olist.fact_items;

--- MONTHLY SALES 
WITH monthly AS (
  SELECT date_trunc('month', order_purchase_timestamp)::date AS month,
         COUNT(DISTINCT order_id) AS orders,
         SUM(price) AS revenue
  FROM olist.fact_items
  WHERE order_status NOT IN ('canceled','unavailable')
  GROUP BY 1
)
SELECT month, orders, ROUND(revenue,2) AS revenue,
       ROUND(revenue/orders,2) AS avg_order_value,
       ROUND(100.0*(revenue - LAG(revenue) OVER (ORDER BY month))
             / NULLIF(LAG(revenue) OVER (ORDER BY month),0),1) AS mom_growth_pct
FROM monthly
ORDER BY month;

--- Top 15 categories by revenue
SELECT category,
       COUNT(DISTINCT order_id) AS orders,
       ROUND(SUM(price),2) AS revenue,
       ROUND(AVG(price),2) AS avg_price,
       ROUND(100*SUM(price)/SUM(SUM(price)) OVER (),2) AS revenue_share_pct
FROM olist.fact_items
WHERE order_status NOT IN ('canceled','unavailable')
GROUP BY 1
ORDER BY revenue DESC
LIMIT 15;

---How much freight adds to the price, by category
SELECT category,
       ROUND(AVG(price),2) AS avg_price,
       ROUND(AVG(freight_value),2) AS avg_freight,
       ROUND(100*SUM(freight_value)/SUM(price),1) AS freight_pct_of_price
FROM olist.fact_items
WHERE order_status NOT IN ('canceled','unavailable')
GROUP BY 1
HAVING COUNT(*) > 500
ORDER BY freight_pct_of_price DESC
LIMIT 15;

---Overall delivery speed and lateness
SELECT COUNT(*) AS delivered_orders,
       ROUND(AVG(EXTRACT(EPOCH FROM (order_delivered_customer_date - order_purchase_timestamp))/86400)::numeric,1) AS avg_delivery_days,
       ROUND(AVG(EXTRACT(EPOCH FROM (order_estimated_delivery_date - order_purchase_timestamp))/86400)::numeric,1) AS avg_estimated_days,
       ROUND(100.0*AVG((order_delivered_customer_date > order_estimated_delivery_date)::int),1) AS late_pct
FROM olist.orders
WHERE order_status = 'delivered'
  AND order_delivered_customer_date IS NOT NULL;


--- Delivery by customer state
SELECT c.customer_state,
       COUNT(*) AS orders,
       ROUND(AVG(EXTRACT(EPOCH FROM (o.order_delivered_customer_date - o.order_purchase_timestamp))/86400)::numeric,1) AS avg_days,
       ROUND(100.0*AVG((o.order_delivered_customer_date > o.order_estimated_delivery_date)::int),1) AS late_pct
FROM olist.orders o
JOIN olist.customers c USING (customer_id)
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL
GROUP BY 1
ORDER BY avg_days DESC;

--- Score distribution
SELECT review_score,
       COUNT(*) AS reviews,
       ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (),1) AS pct
FROM olist.reviews_clean
GROUP BY 1
ORDER BY 1;

--- Late versus on-time delivery and the review score (the key insight)
SELECT CASE WHEN o.order_delivered_customer_date > o.order_estimated_delivery_date
            THEN 'late' ELSE 'on_time' END AS delivery,
       COUNT(*) AS orders,
       ROUND(AVG(r.review_score),2) AS avg_score,
       ROUND(100.0*AVG((r.review_score <= 2)::int),1) AS pct_negative
FROM olist.orders o
JOIN olist.reviews_clean r USING (order_id)
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL
GROUP BY 1;

SELECT CASE
         WHEN d <= 0 THEN '1. on time or early'
         WHEN d <= 3 THEN '2. 1-3 days late'
         WHEN d <= 7 THEN '3. 4-7 days late'
         ELSE '4. over 7 days late'
       END AS lateness,
       COUNT(*) AS orders,
       ROUND(AVG(review_score),2) AS avg_score
FROM (
  SELECT r.review_score,
         EXTRACT(EPOCH FROM (o.order_delivered_customer_date - o.order_estimated_delivery_date))/86400 AS d
  FROM olist.orders o
  JOIN olist.reviews_clean r USING (order_id)
  WHERE o.order_status = 'delivered'
    AND o.order_delivered_customer_date IS NOT NULL
) t
GROUP BY 1
ORDER BY 1;

--- Worst-rated categories
SELECT f.category,
       COUNT(DISTINCT f.order_id) AS orders,
       ROUND(AVG(r.review_score),2) AS avg_score
FROM olist.fact_items f
JOIN olist.reviews_clean r USING (order_id)
GROUP BY 1
HAVING COUNT(DISTINCT f.order_id) > 300
ORDER BY avg_score ASC
LIMIT 10;

--- Top 15 categories by revenue
SELECT category,
       COUNT(DISTINCT order_id) AS orders,
       ROUND(SUM(price),2) AS revenue,
       ROUND(AVG(price),2) AS avg_price,
       ROUND(100*SUM(price)/SUM(SUM(price)) OVER (),2) AS revenue_share_pct
FROM olist.fact_items
WHERE order_status NOT IN ('canceled','unavailable')
GROUP BY 1
ORDER BY revenue DESC
LIMIT 15;

--- Delivery by customer state
SELECT c.customer_state,
       COUNT(*) AS orders,
       ROUND(AVG(EXTRACT(EPOCH FROM (o.order_delivered_customer_date - o.order_purchase_timestamp))/86400)::numeric,1) AS avg_days,
       ROUND(100.0*AVG((o.order_delivered_customer_date > o.order_estimated_delivery_date)::int),1) AS late_pct
FROM olist.orders o
JOIN olist.customers c USING (customer_id)
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL
GROUP BY 1
ORDER BY avg_days DESC;

--- Score distribution
SELECT review_score,
       COUNT(*) AS reviews,
       ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (),1) AS pct
FROM olist.reviews_clean
GROUP BY 1
ORDER BY 1;

--- Repeat purchase rate
WITH per_cust AS (
  SELECT c.customer_unique_id, COUNT(DISTINCT o.order_id) AS n_orders
  FROM olist.orders o
  JOIN olist.customers c USING (customer_id)
  WHERE o.order_status = 'delivered'
  GROUP BY 1
)
SELECT COUNT(*) AS customers,
       COUNT(*) FILTER (WHERE n_orders > 1) AS repeat_customers,
       ROUND(100.0*COUNT(*) FILTER (WHERE n_orders > 1)/COUNT(*),2) AS repeat_rate_pct
FROM per_cust;

--- Customer segments
WITH base AS (
  SELECT customer_unique_id,
         MAX(order_purchase_timestamp)::date AS last_order,
         COUNT(DISTINCT order_id) AS freq,
         SUM(price) AS monetary
  FROM olist.fact_items
  WHERE order_status = 'delivered'
  GROUP BY 1
), ref AS (
  SELECT MAX(order_purchase_timestamp)::date + 1 AS ref_date FROM olist.fact_items
), seg AS (
  SELECT b.*, (r.ref_date - b.last_order) AS recency_days,
         CASE
           WHEN freq > 1 AND (r.ref_date - b.last_order) <= 180 THEN '1. Active repeat'
           WHEN freq > 1 THEN '2. Lapsed repeat'
           WHEN (r.ref_date - b.last_order) <= 90 THEN '3. Recent one-time'
           WHEN (r.ref_date - b.last_order) <= 270 THEN '4. Cooling one-time'
           ELSE '5. Lost one-time'
         END AS segment
  FROM base b CROSS JOIN ref r
)
SELECT segment, COUNT(*) AS customers,
       ROUND(SUM(monetary),2) AS revenue,
       ROUND(AVG(monetary),2) AS avg_spend
FROM seg
GROUP BY 1
ORDER BY 1;

--- Cohort retention
WITH first_order AS (
  SELECT customer_unique_id,
         date_trunc('month', MIN(order_purchase_timestamp)) AS cohort
  FROM olist.fact_items
  WHERE order_status = 'delivered'
  GROUP BY 1
), activity AS (
  SELECT DISTINCT f.customer_unique_id, f.cohort,
         date_trunc('month', i.order_purchase_timestamp) AS active_month
  FROM first_order f
  JOIN olist.fact_items i USING (customer_unique_id)
  WHERE i.order_status = 'delivered'
), months AS (
  SELECT cohort, customer_unique_id,
         (EXTRACT(YEAR FROM age(active_month, cohort)) * 12
          + EXTRACT(MONTH FROM age(active_month, cohort)))::int AS n
  FROM activity
)
SELECT cohort::date AS cohort_month,
       COUNT(*) FILTER (WHERE n = 0) AS m0_customers,
       ROUND(100.0 * COUNT(*) FILTER (WHERE n = 1) / COUNT(*) FILTER (WHERE n = 0), 2) AS m1_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE n = 2) / COUNT(*) FILTER (WHERE n = 0), 2) AS m2_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE n = 3) / COUNT(*) FILTER (WHERE n = 0), 2) AS m3_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE n = 6) / COUNT(*) FILTER (WHERE n = 0), 2) AS m6_pct
FROM months
WHERE cohort BETWEEN '2017-01-01' AND '2018-03-01'
GROUP BY 1
ORDER BY 1;

--- Top 20 sellers with their quality
SELECT oi.seller_id,
       COUNT(DISTINCT oi.order_id) AS orders,
       ROUND(SUM(oi.price),2) AS revenue,
       ROUND(AVG(r.review_score),2) AS avg_score
FROM olist.order_items oi
JOIN olist.orders o USING (order_id)
LEFT JOIN olist.reviews_clean r USING (order_id)
WHERE o.order_status NOT IN ('canceled','unavailable')
GROUP BY 1
HAVING COUNT(DISTINCT oi.order_id) >= 30
ORDER BY revenue DESC
LIMIT 20;

--- what share of revenue do the top 10% of sellers bring?
WITH s AS (
  SELECT seller_id, SUM(price) AS revenue
  FROM olist.fact_items
  WHERE order_status NOT IN ('canceled','unavailable')
  GROUP BY 1
), ranked AS (
  SELECT revenue,
         ROW_NUMBER() OVER (ORDER BY revenue DESC) AS rn,
         COUNT(*) OVER () AS n,
         SUM(revenue) OVER (ORDER BY revenue DESC, seller_id) AS cum,
         SUM(revenue) OVER () AS total
  FROM s
)
SELECT MAX(n) AS total_sellers,
       CEIL(0.1*MAX(n)) AS top_10pct_count,
       ROUND(100*MAX(cum)/MAX(total),1) AS top_10pct_revenue_share
FROM ranked
WHERE rn <= CEIL(0.1*n);

--- Where sellers are based
SELECT s.seller_state,
       COUNT(DISTINCT s.seller_id) AS sellers,
       ROUND(SUM(oi.price),2) AS revenue
FROM olist.order_items oi
JOIN olist.sellers s USING (seller_id)
JOIN olist.orders o USING (order_id)
WHERE o.order_status NOT IN ('canceled','unavailable')
GROUP BY 1
ORDER BY revenue DESC
LIMIT 10;

--- Payment methods
SELECT payment_type,
       COUNT(DISTINCT order_id) AS orders,
       ROUND(SUM(payment_value),2) AS total_value,
       ROUND(100*SUM(payment_value)/SUM(SUM(payment_value)) OVER (),1) AS share_pct,
       ROUND(AVG(payment_value),2) AS avg_payment
FROM olist.order_payments
GROUP BY 1
ORDER BY total_value DESC;

--- Credit card installments
SELECT CASE WHEN payment_installments <= 1 THEN '1 (single payment)'
            WHEN payment_installments <= 3 THEN '2-3'
            WHEN payment_installments <= 6 THEN '4-6'
            WHEN payment_installments <= 10 THEN '7-10'
            ELSE '11+' END AS installments,
       COUNT(*) AS payments,
       ROUND(AVG(payment_value),2) AS avg_value
FROM olist.order_payments
WHERE payment_type = 'credit_card'
GROUP BY 1
ORDER BY MIN(payment_installments);

--- Revenue by customer state
SELECT customer_state,
       COUNT(DISTINCT order_id) AS orders,
       ROUND(SUM(price),2) AS revenue,
       ROUND(100*SUM(price)/SUM(SUM(price)) OVER (),1) AS share_pct,
       ROUND(AVG(freight_value),2) AS avg_freight
FROM olist.fact_items
WHERE order_status NOT IN ('canceled','unavailable')
GROUP BY 1
ORDER BY revenue DESC;

--- Same-state versus cross-state
SELECT CASE WHEN s.seller_state = c.customer_state
            THEN 'same state' ELSE 'different state' END AS route,
       COUNT(*) AS items,
       ROUND(AVG(oi.freight_value),2) AS avg_freight,
       ROUND(AVG(EXTRACT(EPOCH FROM (o.order_delivered_customer_date - o.order_purchase_timestamp))/86400)::numeric,1) AS avg_delivery_days
FROM olist.order_items oi
JOIN olist.orders o USING (order_id)
JOIN olist.customers c USING (customer_id)
JOIN olist.sellers s USING (seller_id)
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL
GROUP BY 1;

--- Sales by weekday and hour
SELECT EXTRACT(DOW FROM order_purchase_timestamp)::int AS weekday_0_sun,
       EXTRACT(HOUR FROM order_purchase_timestamp)::int AS hour,
       COUNT(*) AS orders
FROM olist.orders
WHERE order_status NOT IN ('canceled','unavailable')
GROUP BY 1,2
ORDER BY 1,2;

--- Where does delivery time go
SELECT ROUND(AVG(EXTRACT(EPOCH FROM (order_approved_at - order_purchase_timestamp))/86400)::numeric,2) AS days_to_approve,
       ROUND(AVG(EXTRACT(EPOCH FROM (order_delivered_carrier_date - order_approved_at))/86400)::numeric,2) AS days_to_carrier,
       ROUND(AVG(EXTRACT(EPOCH FROM (order_delivered_customer_date - order_delivered_carrier_date))/86400)::numeric,2) AS days_last_mile
FROM olist.orders
WHERE order_status = 'delivered'
  AND order_delivered_customer_date IS NOT NULL
  AND order_delivered_carrier_date IS NOT NULL
  AND order_approved_at IS NOT NULL;

---- Black Friday effect
SELECT order_purchase_timestamp::date AS day,
       COUNT(DISTINCT order_id) AS orders,
       ROUND(SUM(price),2) AS revenue
FROM olist.fact_items
WHERE order_purchase_timestamp >= '2017-11-15' AND order_purchase_timestamp < '2017-12-01'
  AND order_status NOT IN ('canceled','unavailable')
GROUP BY 1
ORDER BY 1;

-----
CREATE INDEX idx_orders_customer ON olist.orders(customer_id);
CREATE INDEX idx_orders_purchase ON olist.orders(order_purchase_timestamp);
CREATE INDEX idx_items_product ON olist.order_items(product_id);
CREATE INDEX idx_items_seller ON olist.order_items(seller_id);
CREATE INDEX idx_reviews_order ON olist.order_reviews(order_id);
CREATE INDEX idx_payments_order ON olist.order_payments(order_id);