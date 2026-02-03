# Analytics Engineering Lesson Plan

A comprehensive curriculum for practicing analytics engineering skills using the Barleta platform.

---

## Platform Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Barleta Analytics Platform                    │
├─────────────────────────────────────────────────────────────────┤
│  Identity Layer (Keycloak SSO)                                │
├─────────────────────────────────────────────────────────────────┤
│  Orchestration    │  Transformation  │  Visualization           │
│  ─────────────    │  ──────────────  │  ─────────────           │
│  Airflow          │  dbt             │  Superset                │
│                   │                  │  Grafana                 │
│                   │                  │  Metabase                │
├─────────────────────────────────────────────────────────────────┤
│  Data Catalog: DataHub    │    Storage: PostgreSQL             │
├─────────────────────────────────────────────────────────────────┤
│  Infrastructure: Harvester HCI + Traefik Ingress               │
└─────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

- Access to Barleta environment (add entries to `/etc/hosts` pointing to `192.168.1.10`)
- User account: `chris` / `Ilovejeff1` (via Keycloak SSO)
- Basic SQL knowledge
- Python familiarity

### Required /etc/hosts Entries
```
192.168.1.10    airflow.barleta.local superset.barleta.local grafana.barleta.local
192.168.1.10    metabase.barleta.local datahub.barleta.local postgresql.barleta.local
192.168.1.10    keycloak.barleta.local argocd.barleta.local
```

## Access URLs

### Analytics Services (SSO via Keycloak)

| Service | URL | Auth Method |
|---------|-----|-------------|
| Airflow | http://airflow.barleta.local:31664 | Keycloak OIDC |
| Superset | http://superset.barleta.local:31664 | Keycloak OIDC |
| Grafana | http://grafana.barleta.local:31664 | Keycloak OIDC |
| DataHub | http://datahub.barleta.local:31664 | Keycloak OIDC |
| Metabase | http://metabase.barleta.local:31664 | Keycloak OIDC |

### Admin Services

| Service | URL | Credentials |
|---------|-----|-------------|
| Keycloak Admin | http://keycloak.barleta.local:31664/admin | admin / Barleta2024! |
| ArgoCD | http://argocd.barleta.local:31664 | admin / (from secret) |

### Database Access

| Service | Host | Port | Credentials |
|---------|------|------|-------------|
| PostgreSQL (external) | postgresql.barleta.local | 32432 | postgres / Barleta2024! |
| PostgreSQL (in-cluster) | postgresql.identity.svc.cluster.local | 5432 | postgres / Barleta2024! |

---

## Module 1: SQL Fundamentals with UCI Online Retail

### Lesson 1.1: Data Exploration
**Objective**: Understand the UCI Online Retail dataset structure

```sql
-- Connect to PostgreSQL and explore the data
SELECT COUNT(*) FROM raw_uci.transactions;

-- Understand the schema
SELECT column_name, data_type 
FROM information_schema.columns 
WHERE table_schema = 'raw_uci' AND table_name = 'transactions';

-- Sample data
SELECT * FROM raw_uci.transactions LIMIT 10;
```

**Exercise 1**: Write a query to find:
- Total number of unique customers
- Total number of unique products (stock_code)
- Date range of transactions

### Lesson 1.2: Aggregations and Grouping
**Objective**: Master GROUP BY and aggregate functions

```sql
-- Revenue by country
SELECT 
    country,
    COUNT(DISTINCT invoice_no) as total_orders,
    SUM(quantity * unit_price) as total_revenue
FROM raw_uci.transactions
WHERE quantity > 0 AND unit_price > 0
GROUP BY country
ORDER BY total_revenue DESC;
```

**Exercise 2**: Calculate:
- Top 10 products by quantity sold
- Average order value by month
- Customer count by country

### Lesson 1.3: Window Functions
**Objective**: Learn analytical functions for ranking and running totals

```sql
-- Customer ranking by total spend
SELECT 
    customer_id,
    SUM(quantity * unit_price) as total_spend,
    RANK() OVER (ORDER BY SUM(quantity * unit_price) DESC) as spend_rank
FROM raw_uci.transactions
WHERE customer_id IS NOT NULL AND quantity > 0
GROUP BY customer_id;
```

**Exercise 3**: Create queries for:
- Running total of daily revenue
- Month-over-month revenue growth
- Customer's purchase sequence (1st, 2nd, 3rd purchase)

---

## Module 2: dbt Fundamentals

### Lesson 2.1: Project Setup
**Objective**: Initialize and configure a dbt project

```bash
# Install dbt
pip install dbt-postgres

# Initialize project
dbt init analytics_project
cd analytics_project

# Configure profiles.yml for LOCAL development (external access)
cat > ~/.dbt/profiles.yml << 'EOF'
analytics_project:
  target: dev
  outputs:
    dev:
      type: postgres
      host: postgresql.barleta.local
      port: 32432
      user: postgres
      password: Barleta2024!
      dbname: superset
      schema: staging
    # For running inside the cluster (e.g., Airflow)
    prod:
      type: postgres
      host: postgresql.identity.svc.cluster.local
      port: 5432
      user: postgres
      password: Barleta2024!
      dbname: superset
      schema: analytics
EOF

# Test connection
dbt debug
```

**Available Databases:**
- `superset` - Superset metadata + analytics data
- `airflow` - Airflow metadata
- `metabase` - Metabase metadata
- `datahub` - DataHub metadata
- `keycloak` - Keycloak identity data

### Lesson 2.2: Staging Models
**Objective**: Create clean, standardized staging models

Create `models/staging/stg_transactions.sql`:
```sql
{{ config(materialized='view') }}

SELECT
    invoice_no,
    stock_code,
    TRIM(description) as description,
    quantity,
    invoice_date as transaction_at,
    unit_price,
    quantity * unit_price as line_total,
    customer_id::varchar as customer_id,
    country,
    CASE WHEN invoice_no LIKE 'C%' THEN true ELSE false END as is_cancelled
FROM {{ source('uci', 'transactions') }}
WHERE customer_id IS NOT NULL
```

**Exercise 4**: 
- Create staging model for products (unique stock_codes)
- Create staging model for customers
- Add schema tests for primary keys

### Lesson 2.3: Mart Models
**Objective**: Build business-ready fact and dimension tables

Create `models/marts/fct_invoices.sql`:
```sql
{{ config(materialized='table') }}

WITH invoice_lines AS (
    SELECT * FROM {{ ref('stg_transactions') }}
    WHERE NOT is_cancelled
)

SELECT
    invoice_no,
    customer_id,
    country,
    MIN(transaction_at) as invoice_date,
    COUNT(DISTINCT stock_code) as unique_products,
    SUM(quantity) as total_quantity,
    SUM(line_total) as invoice_total
FROM invoice_lines
GROUP BY invoice_no, customer_id, country
```

**Exercise 5**:
- Create `dim_customers` with first/last purchase dates
- Create `dim_products` with product descriptions
- Create `fct_daily_sales` aggregation

### Lesson 2.4: Testing and Documentation
**Objective**: Ensure data quality with tests

Create `models/schema.yml`:
```yaml
version: 2

models:
  - name: stg_transactions
    description: "Cleaned transaction data from UCI Online Retail"
    columns:
      - name: invoice_no
        description: "Invoice identifier"
        tests:
          - not_null
      - name: customer_id
        description: "Customer identifier"
        tests:
          - not_null
      - name: line_total
        description: "Line item total (quantity * unit_price)"
        tests:
          - not_null
```

**Exercise 6**:
- Add tests for all staging models
- Create custom test for negative quantities
- Generate and review dbt docs

---

## Module 3: Metrics and KPIs

### Lesson 3.1: RFM Analysis
**Objective**: Implement customer segmentation using RFM

```sql
-- Create RFM metrics model
WITH customer_metrics AS (
    SELECT
        customer_id,
        COUNT(DISTINCT invoice_no) as frequency,
        SUM(invoice_total) as monetary,
        MAX(invoice_date) as last_purchase,
        CURRENT_DATE - MAX(invoice_date)::date as recency_days
    FROM {{ ref('fct_invoices') }}
    GROUP BY customer_id
),

rfm_scores AS (
    SELECT
        *,
        NTILE(5) OVER (ORDER BY recency_days DESC) as r_score,
        NTILE(5) OVER (ORDER BY frequency) as f_score,
        NTILE(5) OVER (ORDER BY monetary) as m_score
    FROM customer_metrics
)

SELECT
    *,
    CASE
        WHEN r_score >= 4 AND f_score >= 4 THEN 'Champions'
        WHEN r_score >= 4 AND f_score >= 2 THEN 'Loyal'
        WHEN r_score >= 3 AND f_score >= 3 THEN 'Potential Loyalists'
        WHEN r_score >= 4 AND f_score = 1 THEN 'New Customers'
        WHEN r_score <= 2 AND f_score >= 4 THEN 'At Risk'
        ELSE 'Others'
    END as customer_segment
FROM rfm_scores
```

**Exercise 7**:
- Calculate segment sizes and revenue contribution
- Identify customers moving between segments

### Lesson 3.2: Cohort Analysis
**Objective**: Track customer retention over time

```sql
-- Monthly cohort retention
WITH first_purchase AS (
    SELECT 
        customer_id,
        DATE_TRUNC('month', MIN(invoice_date)) as cohort_month
    FROM {{ ref('fct_invoices') }}
    GROUP BY customer_id
),

activity AS (
    SELECT
        f.customer_id,
        fp.cohort_month,
        DATE_TRUNC('month', f.invoice_date) as activity_month
    FROM {{ ref('fct_invoices') }} f
    JOIN first_purchase fp ON f.customer_id = fp.customer_id
)

SELECT
    cohort_month,
    activity_month,
    (EXTRACT(YEAR FROM activity_month) - EXTRACT(YEAR FROM cohort_month)) * 12 +
    (EXTRACT(MONTH FROM activity_month) - EXTRACT(MONTH FROM cohort_month)) as months_since_first,
    COUNT(DISTINCT customer_id) as active_customers
FROM activity
GROUP BY 1, 2
ORDER BY 1, 2
```

**Exercise 8**:
- Create cohort retention visualization data
- Calculate cohort LTV (lifetime value)
- Compare retention across countries

---

## Module 4: Data Visualization with Superset

### Lesson 4.1: Database Connection
**Objective**: Connect Superset to PostgreSQL

1. Navigate to http://superset.barleta.local:31664
2. Login via Keycloak SSO (chris/Ilovejeff1)
3. Go to Settings → Database Connections → + Database
4. Select PostgreSQL
5. Enter connection string:
   ```
   postgresql://postgres:Barleta2024!@postgresql.identity.svc.cluster.local:5432/superset
   ```

**Note**: Superset uses Keycloak SSO - you'll be redirected to Keycloak for authentication.

### Lesson 4.2: Creating Charts
**Objective**: Build essential business charts

**Exercise 9**: Create the following visualizations:
- Line chart: Daily revenue trend
- Bar chart: Revenue by country (top 10)
- Pie chart: Customer segments
- Table: Top products by revenue
- Big Number: Total revenue, Total customers

### Lesson 4.3: Building Dashboards
**Objective**: Assemble an executive dashboard

**Exercise 10**: Create "Executive KPI Dashboard" with:
- KPI cards (revenue, orders, customers, AOV)
- Revenue trend (line chart)
- Geographic breakdown (map or bar)
- Product performance (table)
- Customer segment distribution

---

## Module 5: Orchestration with Airflow

### Lesson 5.1: DAG Basics
**Objective**: Understand Airflow DAG structure

Access Airflow at http://airflow.barleta.local:31664 (SSO via Keycloak)

**Note**: Airflow 3.x uses KeycloakAuthManager for authentication. Login with your Keycloak credentials.

```python
# Example DAG: dbt_daily.py
from airflow import DAG
from airflow.operators.bash import BashOperator
from datetime import datetime, timedelta

default_args = {
    'owner': 'analytics',
    'depends_on_past': False,
    'email_on_failure': False,
    'retries': 1,
    'retry_delay': timedelta(minutes=5),
}

with DAG(
    'dbt_daily',
    default_args=default_args,
    description='Run dbt models daily',
    schedule_interval='0 6 * * *',
    start_date=datetime(2024, 1, 1),
    catchup=False,
) as dag:

    dbt_run = BashOperator(
        task_id='dbt_run',
        bash_command='cd /opt/dbt && dbt run --profiles-dir /opt/dbt',
    )

    dbt_test = BashOperator(
        task_id='dbt_test',
        bash_command='cd /opt/dbt && dbt test --profiles-dir /opt/dbt',
    )

    dbt_run >> dbt_test
```

**Exercise 11**:
- Create a DAG for data quality checks
- Add email notifications on failure
- Implement SLA monitoring

---

## Module 6: Advanced Topics

### Lesson 6.1: Data Quality with Great Expectations
**Objective**: Implement automated data validation

```python
import great_expectations as gx

context = gx.get_context()

# Define expectations
suite = context.add_expectation_suite("uci_transactions")
validator = context.get_validator(
    batch_request=batch_request,
    expectation_suite_name="uci_transactions"
)

validator.expect_column_values_to_not_be_null("customer_id")
validator.expect_column_values_to_be_between("unit_price", min_value=0)
validator.expect_column_values_to_be_between("quantity", min_value=-1000, max_value=100000)
```

### Lesson 6.2: Incremental Models
**Objective**: Optimize for large datasets

```sql
{{ config(
    materialized='incremental',
    unique_key='invoice_no || stock_code'
) }}

SELECT * FROM {{ source('uci', 'transactions') }}
{% if is_incremental() %}
WHERE invoice_date > (SELECT MAX(invoice_date) FROM {{ this }})
{% endif %}
```

---

## Assessment Projects

### Project 1: End-to-End Pipeline
Build a complete analytics pipeline:
1. Raw data ingestion (SQL)
2. Staging models (dbt)
3. Mart models (dbt)
4. Metrics layer (dbt)
5. Dashboard (Superset)
6. Orchestration (Airflow)

### Project 2: Customer 360
Create a comprehensive customer view:
- Purchase history
- RFM segments
- Predicted churn
- Product preferences

### Project 3: Product Analytics
Analyze product performance:
- Best sellers by period
- Market basket analysis
- Seasonal trends
- Cross-sell recommendations

---

## Completion Checklist

- [ ] Module 1: SQL Fundamentals (Exercises 1-3)
- [ ] Module 2: dbt Fundamentals (Exercises 4-6)
- [ ] Module 3: Metrics and KPIs (Exercises 7-8)
- [ ] Module 4: Data Visualization with Superset (Exercises 9-10)
- [ ] Module 5: Orchestration with Airflow (Exercise 11)
- [ ] Module 6: Advanced Topics
- [ ] Module 7: Data Catalog with DataHub (Exercise 12)
- [ ] Module 8: Monitoring with Grafana (Exercise 13)
- [ ] Module 9: Business Intelligence with Metabase (Exercise 14)
- [ ] Project 1: End-to-End Pipeline
- [ ] Project 2: Customer 360
- [ ] Project 3: Product Analytics

---

## Module 7: Data Catalog with DataHub

### Lesson 7.1: Exploring DataHub
**Objective**: Understand data lineage and metadata management

1. Navigate to http://datahub.barleta.local:31664
2. Login via Keycloak SSO
3. Explore:
   - Dataset discovery
   - Data lineage visualization
   - Schema documentation
   - Data quality metrics

### Lesson 7.2: Ingesting Metadata
**Objective**: Push dbt metadata to DataHub

```bash
# Install datahub CLI
pip install acryl-datahub

# Configure DataHub connection
datahub init
# Server: http://datahub.barleta.local:31664
# Token: (generate from DataHub UI)

# Ingest dbt metadata
datahub ingest -c dbt_recipe.yaml
```

**Exercise 12**: 
- Ingest your dbt project metadata
- Document datasets with descriptions
- Add data owners and tags

---

## Module 8: Monitoring with Grafana

### Lesson 8.1: Platform Monitoring
**Objective**: Monitor analytics platform health

1. Navigate to http://grafana.barleta.local:31664
2. Login via Keycloak SSO
3. Explore pre-configured dashboards

### Lesson 8.2: Custom Dashboards
**Objective**: Create operational dashboards

**Exercise 13**:
- Create dashboard for dbt run metrics
- Add Airflow DAG success/failure rates
- Monitor database query performance

---

## Module 9: Business Intelligence with Metabase

### Lesson 9.1: Self-Service Analytics
**Objective**: Enable business users with Metabase

1. Navigate to http://metabase.barleta.local:31664
2. Login with LDAP credentials (chris/Ilovejeff1)
3. Create questions and dashboards

**Note**: Metabase uses Keycloak OIDC for authentication.

**Exercise 14**:
- Create a "Sales Overview" question
- Build a self-service dashboard
- Set up email subscriptions

---

## Quick Reference: Connection Strings

### PostgreSQL (Local Development)
```bash
# psql
psql -h postgresql.barleta.local -p 32432 -U postgres -d superset

# Connection string
postgresql://postgres:Barleta2024!@postgresql.barleta.local:32432/superset
```

### PostgreSQL (In-Cluster)
```bash
# From Airflow/dbt running in Kubernetes
postgresql://postgres:Barleta2024!@postgresql.identity.svc.cluster.local:5432/superset
```

---

## Resources

- [dbt Documentation](https://docs.getdbt.com/)
- [Apache Superset Docs](https://superset.apache.org/docs/)
- [Apache Airflow Docs](https://airflow.apache.org/docs/)
- [DataHub Docs](https://datahubproject.io/docs/)
- [Grafana Docs](https://grafana.com/docs/)
- [Metabase Docs](https://www.metabase.com/docs/)
- [UCI Online Retail Dataset](https://archive.ics.uci.edu/ml/datasets/Online+Retail)
- [Keycloak Documentation](https://www.keycloak.org/documentation)
