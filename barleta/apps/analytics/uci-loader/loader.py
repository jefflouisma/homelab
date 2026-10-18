import os
from pathlib import Path
from tempfile import TemporaryDirectory
from urllib.request import urlretrieve

import pandas as pd
from sqlalchemy import URL, create_engine, text


SOURCE_URL = "https://archive.ics.uci.edu/ml/machine-learning-databases/00352/Online%20Retail.xlsx"
SOURCE_COLUMNS = [
    "InvoiceNo", "StockCode", "Description", "Quantity", "InvoiceDate",
    "UnitPrice", "CustomerID", "Country",
]
TARGET_COLUMNS = [
    "invoice_no", "stock_code", "description", "quantity", "invoice_date",
    "unit_price", "customer_id", "country",
]


def read_transactions(path):
    frame = pd.read_excel(path)
    if list(frame.columns) != SOURCE_COLUMNS:
        raise ValueError("Unexpected UCI workbook columns")
    frame.columns = TARGET_COLUMNS
    frame = frame.dropna(subset=["customer_id"]).copy()
    if frame.empty:
        raise ValueError("UCI workbook contains no rows with customers")
    frame["customer_id"] = frame["customer_id"].astype(int).astype(str)
    return frame


def database_url():
    return URL.create(
        "postgresql+psycopg2",
        username=os.environ["PGUSER"], password=os.environ["PGPASSWORD"],
        host=os.environ["PGHOST"], port=int(os.environ.get("PGPORT", "5432")),
        database=os.environ["PGDATABASE"],
    )


def load_transactions(engine, frame):
    with engine.begin() as connection:
        connection.execute(text("SELECT pg_advisory_xact_lock(87214103)"))
        exists = connection.execute(text("SELECT to_regclass('raw_uci.transactions')")).scalar()
        if exists:
            count = connection.execute(text("SELECT COUNT(*) FROM raw_uci.transactions")).scalar_one()
            if count:
                print(f"Keeping {count} existing rows; ingestion skipped")
                return 0
        frame.to_sql(
            "transactions", connection, schema="raw_uci", if_exists="append",
            index=False, chunksize=1000,
        )
        count = connection.execute(text("SELECT COUNT(*) FROM raw_uci.transactions")).scalar_one()
        if count != len(frame):
            raise RuntimeError(f"Row count mismatch: expected {len(frame)}, got {count}")
        print(f"Loaded {count} rows into raw_uci.transactions")
        return count


def main():
    engine = create_engine(database_url())
    try:
        with TemporaryDirectory() as directory:
            path = os.environ.get("UCI_DATASET_PATH")
            if not path:
                path = str(Path(directory) / "OnlineRetail.xlsx")
                urlretrieve(SOURCE_URL, path)
            load_transactions(engine, read_transactions(path))
    finally:
        engine.dispose()


if __name__ == "__main__":
    main()
