import tempfile
import unittest
from pathlib import Path

import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.exc import IntegrityError

import loader


class LoaderIntegrationTest(unittest.TestCase):
    def test_ingestion_retry_and_rollback(self):
        engine = create_engine(loader.database_url())
        self.addCleanup(engine.dispose)
        with engine.begin() as connection:
            connection.execute(text('CREATE SCHEMA IF NOT EXISTS raw_uci'))
            connection.execute(text('DROP TABLE IF EXISTS raw_uci.transactions'))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture.xlsx'
            rows = [
                [100, 'A', 'Example', 2, pd.Timestamp('2026-01-01'), 1.5, 123, 'UK'],
                [101, 'B', 'Missing', 1, pd.Timestamp('2026-01-02'), 2, None, 'UK'],
            ]
            pd.DataFrame(rows, columns=loader.SOURCE_COLUMNS).to_excel(path, index=False)
            frame = loader.read_transactions(path)
            self.assertEqual(len(frame), 1)
            self.assertEqual(frame.iloc[0].customer_id, '123')
            self.assertEqual(loader.load_transactions(engine, frame), 1)
            self.assertEqual(loader.load_transactions(engine, frame), 0)
            with engine.begin() as connection:
                self.assertEqual(connection.execute(text('SELECT COUNT(*) FROM raw_uci.transactions')).scalar_one(), 1)
                connection.execute(text('TRUNCATE raw_uci.transactions'))
                connection.execute(text('ALTER TABLE raw_uci.transactions ADD CHECK (quantity > 0)'))
            bad = pd.concat([frame] * 1001, ignore_index=True)
            bad.loc[1000, 'quantity'] = -1
            with self.assertRaises(IntegrityError):
                loader.load_transactions(engine, bad)
            with engine.begin() as connection:
                self.assertEqual(connection.execute(text('SELECT COUNT(*) FROM raw_uci.transactions')).scalar_one(), 0)
            self.assertEqual(loader.load_transactions(engine, frame), 1)
            pd.DataFrame({'wrong': [1]}).to_excel(path, index=False)
            with self.assertRaises(ValueError):
                loader.read_transactions(path)


if __name__ == '__main__':
    unittest.main()
