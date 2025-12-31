# Analytics Engineering Practice Environment

This document outlines a comprehensive analytics engineering practice environment built on the Barleta Harvester platform. The goal is to create a realistic "modern data stack" that mirrors what analytics engineers use at tech companies.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          Barleta Analytics Stack                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐  │
│  │   Superset  │    │   Metabase  │    │   Grafana   │    │  DataHub    │  │
│  │  (BI/Viz)   │    │  (BI/Viz)   │    │ (Metrics)   │    │  (Catalog)  │  │
│  └──────┬──────┘    └──────┬──────┘    └──────┬──────┘    └──────┬──────┘  │
│         │                  │                  │                  │          │
│         └──────────────────┼──────────────────┼──────────────────┘          │
│                            │                  │                             │
│                     ┌──────┴──────┐    ┌──────┴──────┐                      │
│                     │  PostgreSQL │    │   Airflow   │                      │
│                     │  (Existing) │◄───│(Orchestrator)│                      │
│                     └──────┬──────┘    └──────┬──────┘                      │
│                            │                  │                             │
│                     ┌──────┴──────────────────┴──────┐                      │
│                     │         dbt Core               │                      │
│                     │    (Transformations)           │                      │
│                     └──────┬─────────────────────────┘                      │
│                            │                                                │
│  ┌─────────────────────────┴─────────────────────────────────────────────┐  │
│  │                        Raw Data Schemas                               │  │
│  ├───────────┬───────────┬───────────┬───────────┬───────────┬──────────┤  │
│  │  raw_uci  │raw_olist  │raw_insta  │raw_retail │raw_amazon │ raw_ga   │  │
│  │  (541k)   │  (100k)   │   (3M+)   │  (2.7M)   │  (233M)   │ (BQ)     │  │
│  └───────────┴───────────┴───────────┴───────────┴───────────┴──────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Components

### 1. Data Warehouse: Existing PostgreSQL (Reused)

We reuse the existing PostgreSQL deployed in the `identity` namespace. Data is segmented into separate schemas per dataset.

**Existing PostgreSQL:**
- **Host:** `postgresql.identity.svc.cluster.local`
- **Port:** `5432`
- **Credentials:** `postgres` / `Barleta2024!`

**Schema Organization:**
```sql
-- Create analytics schemas in existing PostgreSQL
CREATE SCHEMA IF NOT EXISTS raw_uci;          -- UCI Online Retail (primary)
CREATE SCHEMA IF NOT EXISTS raw_olist;        -- Olist Brazilian E-Commerce
CREATE SCHEMA IF NOT EXISTS raw_instacart;    -- Instacart Market Basket
CREATE SCHEMA IF NOT EXISTS raw_retailrocket; -- RetailRocket Events
CREATE SCHEMA IF NOT EXISTS raw_amazon;       -- Amazon Reviews
CREATE SCHEMA IF NOT EXISTS raw_ga;           -- Google Analytics Sample

CREATE SCHEMA IF NOT EXISTS staging;          -- dbt staging models
CREATE SCHEMA IF NOT EXISTS marts;            -- dbt mart models
CREATE SCHEMA IF NOT EXISTS metrics;          -- dbt metrics models

-- Create analytics user with access to all schemas
CREATE USER analytics WITH PASSWORD 'Analytics2024!';
GRANT ALL PRIVILEGES ON SCHEMA raw_uci, raw_olist, raw_instacart, 
  raw_retailrocket, raw_amazon, raw_ga, staging, marts, metrics TO analytics;
```

**Connection String:**
```
postgresql://analytics:Analytics2024!@postgresql.identity.svc.cluster.local:5432/midpoint
```

### 2. Orchestration: Apache Airflow

Airflow schedules dbt runs, data ingestion, and manages dependencies.

**Helm Installation:**
```bash
helm repo add apache-airflow https://airflow.apache.org
helm repo update

helm upgrade --install airflow apache-airflow/airflow \
  --namespace analytics \
  --create-namespace \
  --set executor=KubernetesExecutor \
  --set webserver.replicas=1 \
  --set webserver.resources.limits.cpu=500m \
  --set webserver.resources.limits.memory=1Gi \
  --set scheduler.resources.limits.cpu=500m \
  --set scheduler.resources.limits.memory=1Gi \
  --set postgresql.enabled=true \
  --set redis.enabled=false \
  --set dags.persistence.enabled=true \
  --set dags.persistence.size=1Gi
```

**Default Access:**
- URL: `http://airflow.barleta.local:31664`
- Username: `admin`
- Password: Get via `kubectl get secret --namespace analytics airflow-webserver-secret -o jsonpath="{.data.webserver-secret-key}" | base64 -d`

### 3. Transformation: dbt Core

dbt runs as jobs within Airflow DAGs or as standalone containers.

**Docker Image:** `ghcr.io/dbt-labs/dbt-postgres:1.7.0`

**dbt Project Structure:**
```
barleta/analytics/dbt_project/
├── dbt_project.yml
├── profiles.yml
├── models/
│   ├── staging/
│   │   ├── stg_orders.sql
│   │   ├── stg_customers.sql
│   │   └── stg_payments.sql
│   ├── marts/
│   │   ├── fct_orders.sql
│   │   ├── dim_customers.sql
│   │   └── dim_products.sql
│   └── metrics/
│       ├── customer_cohorts.sql
│       ├── rfm_segments.sql
│       └── daily_revenue.sql
├── tests/
├── macros/
└── seeds/
```

### 4. BI / Visualization: Apache Superset

**Helm Installation:**
```bash
helm repo add superset https://apache.github.io/superset
helm repo update

helm upgrade --install superset superset/superset \
  --namespace analytics \
  --set replicaCount=1 \
  --set resources.limits.cpu=1000m \
  --set resources.limits.memory=2Gi \
  --set postgresql.enabled=true \
  --set redis.enabled=true \
  --set supersetNode.connections.db_host=postgres-warehouse-postgresql.analytics.svc
```

**Default Access:**
- URL: `http://superset.barleta.local:31664`
- Username: `admin`
- Password: `admin`

### 5. Data Catalog: DataHub (or OpenMetadata)

**Option A: DataHub**
```bash
helm repo add datahub https://helm.datahubproject.io/
helm repo update

helm upgrade --install datahub datahub/datahub \
  --namespace analytics \
  --set datahub-gms.resources.limits.cpu=1000m \
  --set datahub-gms.resources.limits.memory=2Gi \
  --set datahub-frontend.resources.limits.cpu=500m \
  --set datahub-frontend.resources.limits.memory=1Gi
```

**Option B: OpenMetadata (lighter)**
```bash
helm repo add open-metadata https://helm.open-metadata.org/
helm repo update

helm upgrade --install openmetadata open-metadata/openmetadata \
  --namespace analytics \
  --set openmetadata.resources.limits.cpu=1000m \
  --set openmetadata.resources.limits.memory=2Gi
```

---

## Test Datasets

Multiple datasets are organized into separate PostgreSQL schemas for different analytics practice scenarios.

### Dataset Overview

| Schema | Dataset | Size | Best For | Source |
|--------|---------|------|----------|--------|
| `raw_uci` | **UCI Online Retail** | 541k rows | RFM, cohorts, basket analysis | [UCI ML Repository](https://archive.ics.uci.edu/dataset/352/online+retail) |
| `raw_olist` | Olist Brazilian E-Commerce | 100k orders | End-to-end KPI dashboards | [Kaggle](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce) |
| `raw_instacart` | Instacart Market Basket | 3M+ orders | Product affinity, reorder rates | [Kaggle](https://www.kaggle.com/datasets/psparks/instacart-market-basket-analysis) |
| `raw_retailrocket` | RetailRocket Events | 2.7M events | Funnel analysis, clickstream | [Kaggle](https://www.kaggle.com/datasets/retailrocket/ecommerce-dataset) |
| `raw_amazon` | Stanford SNAP Amazon Reviews | 233M reviews | NLP, sentiment, ratings | [SNAP](https://snap.stanford.edu/data/web-Amazon.html) |
| `raw_ga` | Google Analytics Sample | BigQuery | Attribution, sessions, funnels | [Google Developers](https://developers.google.com/analytics/bigquery/web-ecommerce-demo-dataset) |

---

### 1. UCI Online Retail (Primary Dataset)

**Schema:** `raw_uci`  
**Size:** ~541,000 transactions  
**Source:** [UCI Machine Learning Repository](https://archive.ics.uci.edu/dataset/352/online+retail)

Real online retail transactions from a UK-based retailer (2010-2011). Contains invoice, product, quantity, price, customer, and date. Ideal for:
- **RFM Analysis** (Recency, Frequency, Monetary)
- **Customer Cohorts** and retention
- **Market Basket Analysis** (association rules)
- **Revenue forecasting**

**Data Model:**
```
┌─────────────────────────────────────────────────────────────┐
│                     raw_uci.transactions                     │
├─────────────────────────────────────────────────────────────┤
│ invoice_no      VARCHAR   -- Invoice number (C prefix=cancel)│
│ stock_code      VARCHAR   -- Product code                    │
│ description     VARCHAR   -- Product description             │
│ quantity        INTEGER   -- Quantity per transaction        │
│ invoice_date    TIMESTAMP -- Invoice date and time           │
│ unit_price      DECIMAL   -- Price per unit (GBP)            │
│ customer_id     VARCHAR   -- Customer identifier             │
│ country         VARCHAR   -- Customer country                │
└─────────────────────────────────────────────────────────────┘
```

**Loading:**
```bash
# Download from UCI
wget https://archive.ics.uci.edu/ml/machine-learning-databases/00352/Online%20Retail.xlsx

# Or use Python
pip install openpyxl pandas psycopg2-binary
python -c "
import pandas as pd
from sqlalchemy import create_engine

df = pd.read_excel('Online Retail.xlsx')
df.columns = ['invoice_no', 'stock_code', 'description', 'quantity', 
              'invoice_date', 'unit_price', 'customer_id', 'country']

engine = create_engine('postgresql://analytics:Analytics2024!@postgresql.identity.svc:5432/midpoint')
df.to_sql('transactions', engine, schema='raw_uci', if_exists='replace', index=False)
"
```

---

### 2. Olist Brazilian E-Commerce

**Schema:** `raw_olist`  
**Size:** ~100,000 orders (2016-2018)  
**Source:** [Kaggle](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce)

Comprehensive Brazilian e-commerce data with customers, orders, payments, shipping, reviews, products, sellers, and geolocation. Excellent for:
- **End-to-end KPI dashboards**
- **Delivery performance analysis**
- **Review sentiment analysis**
- **Seller performance metrics**

**Data Model:**
```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│    customers    │     │     orders      │     │    payments     │
├─────────────────┤     ├─────────────────┤     ├─────────────────┤
│ customer_id     │◄────│ customer_id     │────►│ order_id        │
│ customer_city   │     │ order_id        │     │ payment_type    │
│ customer_state  │     │ order_status    │     │ payment_value   │
└─────────────────┘     │ purchase_ts     │     └─────────────────┘
                        └────────┬────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              ▼                  ▼                  ▼
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   order_items   │     │    reviews      │     │    sellers      │
└─────────────────┘     └─────────────────┘     └─────────────────┘
```

**Loading:**
```bash
kaggle datasets download -d olistbr/brazilian-ecommerce
unzip brazilian-ecommerce.zip
# Load each CSV into raw_olist schema
```

---

### 3. Instacart Market Basket

**Schema:** `raw_instacart`  
**Size:** 3M+ orders, 32M+ order-product rows  
**Source:** [Kaggle](https://www.kaggle.com/datasets/psparks/instacart-market-basket-analysis)

Anonymized grocery order history from Instacart. Classic dataset for:
- **"Frequently bought together"** analysis
- **Reorder rates** and customer loyalty
- **Product affinity** and recommendations
- **Customer segmentation** by shopping behavior

**Data Model:**
```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│     orders      │     │  order_products │     │    products     │
├─────────────────┤     ├─────────────────┤     ├─────────────────┤
│ order_id        │────►│ order_id        │────►│ product_id      │
│ user_id         │     │ product_id      │     │ product_name    │
│ order_number    │     │ add_to_cart_ord │     │ aisle_id        │
│ order_dow       │     │ reordered       │     │ department_id   │
│ order_hour      │     └─────────────────┘     └─────────────────┘
│ days_since_prior│
└─────────────────┘
```

**Loading:**
```bash
kaggle datasets download -d psparks/instacart-market-basket-analysis
unzip instacart-market-basket-analysis.zip
# Load CSVs: orders, order_products_train, order_products_prior, products, aisles, departments
```

---

### 4. RetailRocket E-Commerce Events

**Schema:** `raw_retailrocket`  
**Size:** 2.7M events  
**Source:** [Kaggle](https://www.kaggle.com/datasets/retailrocket/ecommerce-dataset)

Event logs (view, add-to-cart, purchase) with item properties. Perfect for:
- **Funnel analysis** (view → cart → purchase)
- **Clickstream behavior** patterns
- **Conversion rate optimization**
- **Recommendation system** development

**Data Model:**
```
┌─────────────────────────────────────────┐
│         raw_retailrocket.events         │
├─────────────────────────────────────────┤
│ timestamp       BIGINT   -- Unix epoch  │
│ visitor_id      VARCHAR  -- Session ID  │
│ event           VARCHAR  -- view/cart/tx│
│ item_id         INTEGER  -- Product ID  │
│ transaction_id  INTEGER  -- Purchase ID │
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│     raw_retailrocket.item_properties    │
├─────────────────────────────────────────┤
│ timestamp       BIGINT                  │
│ item_id         INTEGER                 │
│ property        VARCHAR                 │
│ value           VARCHAR                 │
└─────────────────────────────────────────┘
```

**Loading:**
```bash
kaggle datasets download -d retailrocket/ecommerce-dataset
unzip ecommerce-dataset.zip
# Load: events.csv, item_properties_part1.csv, item_properties_part2.csv
```

---

### 5. Stanford SNAP Amazon Reviews

**Schema:** `raw_amazon`  
**Size:** 233M reviews (subset recommended)  
**Source:** [SNAP](https://snap.stanford.edu/data/web-Amazon.html)

Massive review corpus with ratings, text, and product/user info. Excellent for:
- **Sentiment analysis** and NLP
- **Topic modeling** on review text
- **Rating prediction** models
- **"Drivers of rating"** analysis

**Data Model:**
```
┌─────────────────────────────────────────┐
│          raw_amazon.reviews             │
├─────────────────────────────────────────┤
│ product_id      VARCHAR  -- ASIN        │
│ user_id         VARCHAR  -- Reviewer    │
│ profile_name    VARCHAR  -- Display name│
│ helpfulness     VARCHAR  -- x/y helpful │
│ score           FLOAT    -- 1-5 stars   │
│ time            BIGINT   -- Unix epoch  │
│ summary         TEXT     -- Review title│
│ text            TEXT     -- Full review │
└─────────────────────────────────────────┘
```

**Loading:**
```bash
# Download subset (e.g., Electronics category ~1.7M reviews)
wget https://snap.stanford.edu/data/amazon/productGraph/categoryFiles/reviews_Electronics_5.json.gz
gzip -d reviews_Electronics_5.json.gz
# Parse JSON and load to PostgreSQL
```

---

### 6. Google Analytics Sample (BigQuery)

**Schema:** `raw_ga` (or connect directly to BigQuery)  
**Size:** Google Merchandise Store data  
**Source:** [Google Developers](https://developers.google.com/analytics/bigquery/web-ecommerce-demo-dataset)

Real web analytics from Google's merchandise store. Great for:
- **Session → purchase funnels**
- **Attribution modeling**
- **Channel performance** analysis
- **User journey** mapping

**Access:**
```sql
-- Query directly in BigQuery (free tier)
SELECT * FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*`
WHERE _TABLE_SUFFIX BETWEEN '20170101' AND '20170131'
```

**Alternative:** Export subset to PostgreSQL for local practice.

---

### 7. Multilingual Amazon Reviews (AWS Open Data)

**Schema:** `raw_amazon_ml`  
**Size:** Reviews in 6 languages  
**Source:** [AWS Registry of Open Data](https://registry.opendata.aws/amazon-reviews-ml/)

Multilingual review corpus for NLP practice across languages:
- English, Japanese, German, French, Spanish, Chinese
- Useful for **cross-lingual sentiment** analysis
- **Language detection** and **translation quality**

**Access:**
```bash
aws s3 cp s3://amazon-reviews-ml/json/ ./amazon-reviews-ml/ --recursive --no-sign-request
```

---

## Practice Exercises

### Level 1: SQL Fundamentals

| Exercise | Description | Tables Used |
|----------|-------------|-------------|
| **Top Cities** | Find top 10 cities by customer count | customers |
| **Order Status** | Count orders by status | orders |
| **Payment Methods** | Analyze payment type distribution | payments |
| **Avg Order Value** | Calculate average order value by state | orders, payments |
| **Delivery Time** | Calculate avg delivery time by state | orders |

### Level 2: dbt Modeling

| Exercise | Description | dbt Concept |
|----------|-------------|-------------|
| **Staging Models** | Create `stg_orders`, `stg_customers` | Sources, refs |
| **Dimension Tables** | Build `dim_customers`, `dim_products` | Incremental |
| **Fact Tables** | Build `fct_orders` with all metrics | Joins, CTEs |
| **Tests** | Add unique, not_null, accepted_values | Testing |
| **Documentation** | Add descriptions, generate docs | docs blocks |

### Level 3: Analytics

| Exercise | Description | Techniques |
|----------|-------------|------------|
| **Monthly Cohorts** | Track customer retention by signup month | Window functions, CASE |
| **RFM Segmentation** | Score customers by Recency/Frequency/Monetary | Percentiles, scoring |
| **Funnel Analysis** | Purchase → Approval → Delivery conversion | Event sequencing |
| **Customer LTV** | Predict lifetime value by segment | Aggregations |
| **Churn Prediction** | Identify at-risk customers | Time-based analysis |

### Level 4: Advanced

| Exercise | Description | Tools |
|----------|-------------|-------|
| **Daily DAG** | Airflow DAG running dbt nightly | Airflow, dbt |
| **Data Quality** | Great Expectations suite | GE, dbt tests |
| **Lineage** | Track lineage in DataHub | DataHub ingestion |
| **Dashboard** | Executive KPI dashboard | Superset |
| **Alerting** | Slack alerts for data issues | Airflow callbacks |

---

## Sample dbt Models

### `models/staging/stg_transactions.sql` (UCI Online Retail)
```sql
{{ config(materialized='view') }}

select
    invoice_no,
    stock_code,
    description,
    quantity,
    invoice_date as transaction_at,
    unit_price,
    quantity * unit_price as line_total,
    customer_id,
    country,
    -- Flag cancelled orders (invoice starts with 'C')
    case when invoice_no like 'C%' then true else false end as is_cancelled
from {{ source('uci', 'transactions') }}
where customer_id is not null
```

### `models/marts/fct_invoices.sql` (UCI Online Retail)
```sql
{{ config(materialized='table') }}

with invoice_lines as (
    select * from {{ ref('stg_transactions') }}
    where not is_cancelled
)

select
    invoice_no,
    customer_id,
    country,
    min(transaction_at) as invoice_date,
    count(distinct stock_code) as unique_products,
    sum(quantity) as total_quantity,
    sum(line_total) as invoice_total,
    
    -- Invoice characteristics
    date_trunc('month', min(transaction_at)) as invoice_month,
    date_trunc('week', min(transaction_at)) as invoice_week,
    extract(dow from min(transaction_at)) as day_of_week,
    extract(hour from min(transaction_at)) as hour_of_day

from invoice_lines
group by invoice_no, customer_id, country
```

### `models/metrics/customer_rfm.sql` (UCI Online Retail)
```sql
{{ config(materialized='table') }}

with customer_metrics as (
    select
        customer_id,
        country,
        count(distinct invoice_no) as frequency,
        sum(invoice_total) as monetary,
        max(invoice_date) as last_purchase,
        min(invoice_date) as first_purchase,
        current_date - max(invoice_date)::date as recency_days
    from {{ ref('fct_invoices') }}
    group by customer_id, country
),

rfm_scores as (
    select
        *,
        ntile(5) over (order by recency_days desc) as r_score,
        ntile(5) over (order by frequency) as f_score,
        ntile(5) over (order by monetary) as m_score
    from customer_metrics
)

select
    customer_id,
    country,
    frequency,
    monetary,
    recency_days,
    first_purchase,
    last_purchase,
    r_score,
    f_score,
    m_score,
    r_score * 100 + f_score * 10 + m_score as rfm_score,
    case
        when r_score >= 4 and f_score >= 4 then 'Champions'
        when r_score >= 4 and f_score >= 2 then 'Loyal Customers'
        when r_score >= 3 and f_score >= 3 then 'Potential Loyalists'
        when r_score >= 4 and f_score = 1 then 'New Customers'
        when r_score >= 2 and f_score >= 2 then 'Promising'
        when r_score <= 2 and f_score >= 4 then 'At Risk'
        when r_score <= 2 and f_score >= 2 then 'Hibernating'
        else 'Lost'
    end as customer_segment
from rfm_scores
```

### `models/metrics/customer_cohorts.sql` (UCI Online Retail)
```sql
{{ config(materialized='table') }}

with customer_first_purchase as (
    select
        customer_id,
        min(invoice_date) as first_purchase_at,
        date_trunc('month', min(invoice_date)) as cohort_month
    from {{ ref('fct_invoices') }}
    group by 1
),

customer_activity as (
    select
        i.customer_id,
        c.cohort_month,
        date_trunc('month', i.invoice_date) as activity_month,
        i.invoice_total
    from {{ ref('fct_invoices') }} i
    join customer_first_purchase c on i.customer_id = c.customer_id
)

select
    cohort_month,
    activity_month,
    (extract(year from activity_month) - extract(year from cohort_month)) * 12 +
    (extract(month from activity_month) - extract(month from cohort_month)) as months_since_first,
    count(distinct customer_id) as active_customers,
    sum(invoice_total) as revenue,
    avg(invoice_total) as avg_order_value
from customer_activity
group by 1, 2
order by 1, 2
```

---

## Resource Requirements

### Minimum Cluster (Learning)

| Component | CPU | Memory | Storage |
|-----------|-----|--------|---------|
| PostgreSQL | 1 core | 2Gi | 20Gi |
| Airflow | 1 core | 2Gi | 5Gi |
| Superset | 500m | 1Gi | - |
| DataHub | 1 core | 2Gi | 10Gi |
| **Total** | **3.5 cores** | **7Gi** | **35Gi** |

### Recommended (Practice)

| Component | CPU | Memory | Storage |
|-----------|-----|--------|---------|
| PostgreSQL | 2 cores | 4Gi | 50Gi |
| Airflow | 2 cores | 4Gi | 10Gi |
| Superset | 1 core | 2Gi | - |
| DataHub | 2 cores | 4Gi | 20Gi |
| **Total** | **7 cores** | **14Gi** | **80Gi** |

---

## Deployment Plan

### Phase 1: Foundation (Week 1)
- [ ] Create analytics schemas in existing PostgreSQL
- [ ] Load UCI Online Retail dataset (primary)
- [ ] Basic SQL exercises on UCI data
- [ ] Set up dbt project structure

### Phase 2: Additional Datasets (Week 2)
- [ ] Load Olist Brazilian E-Commerce
- [ ] Load Instacart Market Basket
- [ ] Load RetailRocket Events
- [ ] Configure BigQuery access for GA sample

### Phase 3: Transformation (Week 3)
- [ ] Create staging models for UCI
- [ ] Build fact and dimension tables
- [ ] Add tests and documentation
- [ ] Generate dbt docs site

### Phase 4: Orchestration (Week 4)
- [ ] Deploy Airflow
- [ ] Create dbt DAG for daily runs
- [ ] Add data quality checks
- [ ] Configure alerting

### Phase 5: Visualization (Week 5)
- [ ] Deploy Superset
- [ ] Connect to PostgreSQL warehouse
- [ ] Build KPI dashboards
- [ ] Create cohort/RFM visualizations

### Phase 6: Governance (Week 6)
- [ ] Deploy DataHub or OpenMetadata
- [ ] Configure lineage ingestion
- [ ] Document data assets
- [ ] Set up data quality monitoring

### Phase 7: Advanced (Optional)
- [ ] Load Amazon Reviews subset (NLP practice)
- [ ] Build sentiment analysis models
- [ ] Create recommendation engine with Instacart data
- [ ] Attribution modeling with GA data

---

## Traefik IngressRoutes

```yaml
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: airflow
  namespace: analytics
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`airflow.barleta.local`)
      kind: Rule
      services:
        - name: airflow-webserver
          port: 8080
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: superset
  namespace: analytics
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`superset.barleta.local`)
      kind: Rule
      services:
        - name: superset
          port: 8088
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: datahub
  namespace: analytics
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`datahub.barleta.local`)
      kind: Rule
      services:
        - name: datahub-datahub-frontend
          port: 9002
```

---

## Next Steps

1. **Create analytics schemas**: Run SQL to create schemas in existing PostgreSQL
   ```bash
   kubectl exec -it postgresql-0 -n identity -- psql -U postgres -d midpoint -c "
     CREATE SCHEMA IF NOT EXISTS raw_uci;
     CREATE SCHEMA IF NOT EXISTS raw_olist;
     CREATE SCHEMA IF NOT EXISTS raw_instacart;
     CREATE SCHEMA IF NOT EXISTS raw_retailrocket;
     CREATE SCHEMA IF NOT EXISTS staging;
     CREATE SCHEMA IF NOT EXISTS marts;
     CREATE SCHEMA IF NOT EXISTS metrics;
   "
   ```

2. **Load UCI dataset**: Download and load primary dataset
   ```bash
   wget https://archive.ics.uci.edu/ml/machine-learning-databases/00352/Online%20Retail.xlsx
   # Use Python pandas to load into raw_uci.transactions
   ```

3. **Set up dbt project**: Create project structure and profiles
   ```bash
   dbt init analytics_project
   # Configure profiles.yml with PostgreSQL connection
   ```

4. **Deploy Airflow**: Install via Helm for orchestration
   ```bash
   helm upgrade --install airflow apache-airflow/airflow --namespace analytics
   ```

5. **Deploy Superset**: Install via Helm for visualization
   ```bash
   helm upgrade --install superset superset/superset --namespace analytics
   ```

6. **Build dashboards**: Connect Superset to PostgreSQL and create visualizations

---

## Connection Details

| Service | Host | Port | Credentials |
|---------|------|------|-------------|
| PostgreSQL | `postgresql.identity.svc` | 5432 | `postgres` / `Barleta2024!` |
| PostgreSQL (external) | `192.168.1.10:32432` | - | Same |
| Airflow | `airflow.barleta.local:31664` | - | Check secret |
| Superset | `superset.barleta.local:31664` | - | `admin` / `admin` |

This environment provides a complete, production-like analytics engineering practice platform that mirrors real-world data teams, reusing the existing Barleta infrastructure.

---

## SSO Configuration Guide

### Overview

All analytics services can be configured to use Keycloak for SSO authentication. This centralizes user management while preserving existing service account access.

### Keycloak Client Setup (Common Steps)

For each service, create a client in the `barleta` realm:
1. Navigate to Keycloak Admin → Clients → Create Client
2. Set **Client ID** (e.g., `grafana`, `metabase`, `datahub`)
3. Enable **Client authentication** (confidential client)
4. Enable **Standard flow** (authorization code)
5. Set **Valid redirect URIs** to `http://<service>.barleta.local:31664/*`
6. Set **Web origins** to `http://<service>.barleta.local:31664`
7. Note the **Client Secret** from the Credentials tab

---

### Grafana SSO Configuration

Grafana supports Keycloak via Generic OAuth. Configure using environment variables:

```yaml
# Keycloak Client Settings
# Client ID: grafana
# Valid Redirect URIs: http://grafana.barleta.local:31664/login/generic_oauth

# Grafana Environment Variables
env:
  - name: GF_AUTH_GENERIC_OAUTH_ENABLED
    value: "true"
  - name: GF_AUTH_GENERIC_OAUTH_NAME
    value: "Keycloak"
  - name: GF_AUTH_GENERIC_OAUTH_CLIENT_ID
    value: "grafana"
  - name: GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET
    value: "<client-secret>"
  - name: GF_AUTH_GENERIC_OAUTH_SCOPES
    value: "openid profile email roles"
  - name: GF_AUTH_GENERIC_OAUTH_AUTH_URL
    value: "http://keycloak.barleta.local:31664/realms/barleta/protocol/openid-connect/auth"
  - name: GF_AUTH_GENERIC_OAUTH_TOKEN_URL
    value: "http://keycloak.identity.svc.cluster.local:8080/realms/barleta/protocol/openid-connect/token"
  - name: GF_AUTH_GENERIC_OAUTH_API_URL
    value: "http://keycloak.identity.svc.cluster.local:8080/realms/barleta/protocol/openid-connect/userinfo"
  - name: GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP
    value: "true"
  - name: GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH
    value: "contains(roles[*], 'Admin') && 'Admin' || contains(roles[*], 'Editor') && 'Editor' || 'Viewer'"
```

**Role Mapping**: Create a Client Role Mapper in Keycloak to include roles in the ID token.

---

### Metabase SSO Configuration

⚠️ **Note**: Metabase open-source does NOT support OIDC natively. Options:
1. **JWT Authentication** (supported in open-source)
2. **SAML Authentication** (supported in open-source)
3. **OIDC** (Enterprise only)

**JWT Configuration with Keycloak**:

```yaml
# Keycloak Client Settings
# Client ID: metabase
# Enable: OAuth 2.0 Device Authorization Grant

# Metabase Environment Variables
env:
  - name: MB_JWT_ENABLED
    value: "true"
  - name: MB_JWT_IDENTITY_PROVIDER_URI
    value: "http://keycloak.identity.svc.cluster.local:8080/realms/barleta"
  - name: MB_JWT_SHARED_SECRET
    value: "<jwt-shared-secret>"  # Generate a strong secret
  - name: MB_JWT_ATTRIBUTE_EMAIL
    value: "email"
  - name: MB_JWT_ATTRIBUTE_FIRSTNAME
    value: "given_name"
  - name: MB_JWT_ATTRIBUTE_LASTNAME
    value: "family_name"
  - name: MB_JWT_GROUP_SYNC
    value: "true"
  - name: MB_JWT_GROUP_MAPPINGS
    value: '{"admin": ["Administrators"], "user": ["All Users"]}'
```

**Alternative - SAML Configuration**:
Configure Keycloak as SAML IdP and set up Metabase SAML in Admin → Authentication → SAML.

---

### DataHub SSO Configuration

DataHub supports OIDC directly via environment variables:

```yaml
# Keycloak Client Settings
# Client ID: datahub
# Valid Redirect URIs: http://datahub.barleta.local:31664/callback/oidc

# DataHub Frontend Helm Values (extraEnvs)
datahub-frontend:
  extraEnvs:
    - name: AUTH_OIDC_ENABLED
      value: "true"
    - name: AUTH_OIDC_CLIENT_ID
      value: "datahub"
    - name: AUTH_OIDC_CLIENT_SECRET
      valueFrom:
        secretKeyRef:
          name: datahub-oidc-secret
          key: client-secret
    - name: AUTH_OIDC_DISCOVERY_URI
      value: "http://keycloak.identity.svc.cluster.local:8080/realms/barleta/.well-known/openid-configuration"
    - name: AUTH_OIDC_BASE_URL
      value: "http://datahub.barleta.local:31664"
    - name: AUTH_OIDC_SCOPE
      value: "openid profile email"
    - name: AUTH_OIDC_USER_NAME_CLAIM
      value: "preferred_username"
    - name: AUTH_OIDC_JIT_PROVISIONING_ENABLED
      value: "true"
    - name: AUTH_OIDC_EXTRACT_GROUPS_ENABLED
      value: "true"
    - name: AUTH_OIDC_GROUPS_CLAIM
      value: "groups"
```

**Keycloak Group Mapper**: Add a protocol mapper to include `groups` claim in tokens.

---

### PostgreSQL Authentication Options

PostgreSQL can integrate with identity providers while preserving service accounts:

#### Option 1: LDAP Authentication (Recommended for Simplicity)

Configure `pg_hba.conf` with LDAP (Keycloak can federate to LDAP):

```conf
# Service accounts first (preserved)
local   all         postgres                      peer
local   all         analytics                     md5
local   all         airflow                       md5
local   all         superset                      md5
host    all         analytics   10.0.0.0/8        md5
host    all         airflow     10.0.0.0/8        md5
host    all         superset    10.0.0.0/8        md5

# LDAP for human users (FreeIPA backend)
host    all         all         0.0.0.0/0         ldap ldapserver=freeipa.identity.svc.cluster.local ldapbasedn="cn=users,cn=accounts,dc=barleta,dc=local" ldapbinddn="uid=admin,cn=users,cn=accounts,dc=barleta,dc=local" ldapbindpasswd="<password>" ldapsearchattribute="uid"
```

#### Option 2: OAuth/OIDC (PostgreSQL 16+)

Native OAuth support requires PostgreSQL 16+:

```conf
# pg_hba.conf
local   all   all   oauth issuer="http://keycloak.identity.svc.cluster.local:8080/realms/barleta/.well-known/openid-configuration" scope="openid" map=oauthmap

# pg_ident.conf (map Keycloak user IDs to PostgreSQL roles)
oauthmap   /^(.*)@barleta\.local$   \1
```

#### Option 3: pg_oidc_validator Extension (PostgreSQL < 16)

Install extension for OIDC support:

```sql
CREATE EXTENSION pg_oidc_validator;
```

Configure in `pg_hba.conf`:
```conf
host all all 0.0.0.0/0 oidc issuer="http://keycloak.identity.svc.cluster.local:8080/realms/barleta" scope="openid" map=oidc
```

#### Preserving Existing Service Accounts

**Critical**: Place service account rules BEFORE SSO rules in `pg_hba.conf`. PostgreSQL matches rules top-to-bottom and uses the first match.

```conf
# ORDER MATTERS - Service accounts first
host    midpoint    midpoint    10.0.0.0/8    md5
host    keycloak    postgres    10.0.0.0/8    md5
host    airflow     airflow     10.0.0.0/8    md5
host    superset    superset    10.0.0.0/8    md5
host    all         analytics   10.0.0.0/8    md5

# SSO users last
host    all         all         0.0.0.0/0     ldap ...
```

---

### SSO Summary Table

| Service | Protocol | Keycloak Support | Complexity | Notes |
|---------|----------|------------------|------------|-------|
| **Airflow** | OAuth2/OIDC | ✅ Native (FAB) | Medium | Requires `authlib` package |
| **Superset** | OAuth2/OIDC | ✅ Native | Medium | Requires `authlib` package |
| **Grafana** | Generic OAuth | ✅ Native | Low | Well-documented |
| **Metabase** | JWT/SAML | ⚠️ No OIDC (OSS) | Medium | JWT or SAML only in open-source |
| **DataHub** | OIDC | ✅ Native | Low | Good Keycloak docs |
| **PostgreSQL** | LDAP/OAuth | ⚠️ Complex | High | LDAP simpler; OAuth needs PG16+ |

### Recommended Approach

1. **Start with Grafana** - easiest to configure, good for testing
2. **Add DataHub** - straightforward OIDC
3. **Configure Superset/Airflow** - already done in current deployment
4. **PostgreSQL LDAP** - for human user access to database
5. **Metabase** - use LDAP (SAML/OIDC requires Enterprise)

---

## Current Deployment Status (December 2025)

### Running Services

| Service | URL | Authentication | Status |
|---------|-----|----------------|--------|
| **Grafana** | `http://grafana.barleta.local:31664` | Keycloak OIDC | ✅ Running |
| **Superset** | `http://superset.barleta.local:31664` | Keycloak OIDC | ✅ Running |
| **Airflow** | `http://airflow.barleta.local:31664` | Keycloak OIDC (KeycloakAuthManager) | ✅ Running |
| **Metabase** | `http://metabase.barleta.local:31664` | FreeIPA LDAP | ✅ Running |
| **DataHub** | `http://datahub.barleta.local:31664` | Keycloak OIDC | ✅ Running |

### Keycloak Clients (barleta realm)

| Client ID | Protocol | Secret |
|-----------|----------|--------|
| `grafana` | OIDC | `lKgHitWGLWXoLXV7vbM27C6oPiLDFYOE` |
| `datahub` | OIDC | `datahub-secret-2024` |
| `metabase` | SAML | N/A (not used - using LDAP instead) |
| `superset` | OIDC | `bn7Ueb6QmyBMtHwByabmCUHHvDEpBwJi` |
| `airflow` | OIDC | `cQ5cTszTYKs90SkX6zpfB0Zq1MoD8vjM` |

### DataHub Configuration Notes

DataHub requires specific MySQL host format for the wait script:
```yaml
global:
  sql:
    datasource:
      # host MUST include port for wait script
      host: "prerequisites-mysql:3306"
      # hostForMysqlClient is hostname only
      hostForMysqlClient: "prerequisites-mysql"
      port: "3306"
      url: "jdbc:mysql://prerequisites-mysql:3306/datahub?..."
```

### Airflow Keycloak Configuration (Airflow 3.x)

Airflow 3.x uses the official KeycloakAuthManager provider:
```yaml
# airflow-values.yaml
config:
  core:
    auth_manager: airflow.providers.keycloak.auth_manager.keycloak_auth_manager.KeycloakAuthManager
  keycloak_auth_manager:
    client_id: airflow
    client_secret: <secret>
    realm: barleta
    server_url: http://keycloak.identity.svc.cluster.local:8080

# Install provider via pip at startup
extraEnv: |
  - name: _PIP_ADDITIONAL_REQUIREMENTS
    value: "apache-airflow-providers-keycloak"
```

### Metabase LDAP Configuration

Metabase open source does NOT support SAML/OIDC - use LDAP with FreeIPA:
```yaml
MB_LDAP_ENABLED: "true"
MB_LDAP_HOST: "192.168.1.212"  # FreeIPA
MB_LDAP_PORT: "389"
MB_LDAP_BIND_DN: "uid=admin,cn=users,cn=accounts,dc=barleta,dc=local"
MB_LDAP_USER_BASE: "cn=users,cn=accounts,dc=barleta,dc=local"
MB_LDAP_USER_FILTER: "(uid={login})"
```

### Deployment Files

- `apps/analytics/grafana-deployment.yaml` - Grafana with Keycloak SSO
- `apps/analytics/metabase-deployment.yaml` - Metabase with FreeIPA LDAP
- `apps/analytics/datahub-values.yaml` - DataHub Helm values with OIDC
- `apps/analytics/datahub-ingress.yaml` - Traefik IngressRoute for DataHub
- `apps/analytics/elasticsearch-simple.yaml` - Elasticsearch for DataHub
- `apps/analytics/postgresql-ldap-config.yaml` - PostgreSQL LDAP reference config
