​import argparse

import json

import os

import shutil

import subprocess

import tempfile

import traceback

import psycopg2

import boto3

from boto3.s3.transfer import TransferConfig

from botocore.config import Config

from datetime import datetime

import asyncio

import concurrent.futures

import gzip

import snowflake.connector

from cryptography.hazmat.primitives import serialization

from cryptography.hazmat.backends import default_backend

import csv

import time

import datetime

import functools

import pandas as pd

from typing import List, Dict

from pathlib import Path

import random

import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

import logging

import re

 

# ---- Timestamped Log File Setup ----

timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")

log_file = f"process_tables_{timestamp}.log"

# Create logger

logger = logging.getLogger()

logger.setLevel(logging.INFO)

 

# Formatter

formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')

 

file_handler = logging.FileHandler(log_file, mode='a')

file_handler.setFormatter(formatter)

logger.addHandler(file_handler)

 

# Console handler

console_handler = logging.StreamHandler()

console_handler.setFormatter(formatter)

logger.addHandler(console_handler)

 

def get_sheet_data(file_path):

    df = pd.read_csv(file_path)

    df = df.applymap(lambda x: x.strip() if isinstance(x, str) else x)

    # Convert boolean columns directly to booleans (handling 'TRUE'/'FALSE' as booleans)

    df = df.replace({'TRUE': True, 'FALSE': False}, regex=True)

   

    # Convert missing values (NaN) to None, if required

    df = df.where(pd.notnull(df), None)  # Replaces NaN with None (optional)

   

    # Convert DataFrame to a list of dictionaries

    return df.to_dict(orient='records')

 

def get_gp_connection(config):

    try:

        connection = psycopg2.connect(

            host=config["host"],

            database=config["database"],

            user=config["user"],

            password=config["password"],

            port=config["port"]

        )

        return connection

    except Exception as e:

        logging.error(f"Error in Greenplumn connection: {e}")

 

def get_sf_connection(config):

    """

    Establishes a connection to Snowflake using one of the following methods:

    - Password authentication

    - Key-pair authentication

    - External browser authentication (default fallback)

    """

 

    conn_params = {

        'user': config["SNOWFLAKE_USER"],

        'account': config["SNOWFLAKE_ACCOUNT"],

        'warehouse': config["SNOWFLAKE_WAREHOUSE"],

        'database': config["SNOWFLAKE_DATABASE"],

        'schema': config["SCHEMA"],

        'role': config["SNOWFLAKE_ROLE"]

    }

 

    if config.get("SNOWFLAKE_PASSWORD"):

        # Standard password-based authentication

        conn_params['password'] = config["SNOWFLAKE_PASSWORD"]

 

    elif config.get("SNOWFLAKE_PASSPHRASE"):

        # Key-pair authentication

        db_name_lower = config['SNOWFLAKE_DATABASE'].lower()

        service_user_type = re.sub(r'\d+', '', config['SNOWFLAKE_USER'].split("_")[3])

        key_file_name = f"{db_name_lower}_{service_user_type}_key"

        key_path = f"C:\\Users\\CN464931\\Desktop\\KeyPairs\\{key_file_name}.p8"

        passphrase = config["SNOWFLAKE_PASSPHRASE"].encode()

 

        with open(key_path, "rb") as key_file:

            private_key = serialization.load_pem_private_key(

                key_file.read(),

                password=passphrase,

                backend=default_backend()

            )

 

        private_key_bytes = private_key.private_bytes(

            encoding=serialization.Encoding.DER,

            format=serialization.PrivateFormat.PKCS8,

            encryption_algorithm=serialization.NoEncryption()

        )

 

        conn_params['private_key'] = private_key_bytes

 

    else:

        # External browser-based SSO

        conn_params['authenticator'] = 'externalbrowser'

 

    return snowflake.connector.connect(**conn_params)

 

def get_s3_session(config):

    session = boto3.Session(

            aws_access_key_id=config['aws_access_key_id'],

            aws_secret_access_key=config['aws_secret_access_key']

        )

    return session

 

class ProcessTable:

    def __init__(self, table_detail, gp_config, sf_config):

        self.gp_config = gp_config

        self.gp_connection = get_gp_connection(gp_config)

        #self.sf_connection = get_sf_connection(sf_config)

        (self.gp_schema_name, self.gp_table_name) = [x.lower() for x in table_detail['table_name'].split('.')]

        self.sf_application_name = table_detail['application']

        if self.sf_application_name.upper() in {'NYHPETL', 'NYHPFIN', 'NYHPEXT','FACETS'}:

            path_prefix = 'NYHP'

        else:

            path_prefix = self.sf_application_name.upper()

        self.table_path_s3 = f"{path_prefix}/dataloads/s3protocol/{table_detail['table_name'].replace('.','/')}/"

        self.transform_cols = table_detail.get('transform_cols',True)

        self.sf_schema_suffix = table_detail.get('sf_schema_suffix','TARGET')

        self.create_sf_table = table_detail.get('create_sf_table',False)

        self.is_target_load_only = table_detail.get('is_target_load_only', False)

        self.enable_gpfdist = table_detail.get('enable_gpfdist',True)

        self.rowcount_check = table_detail.get('rowcount_check', True)

 

    def timing_decorator(func):

        @functools.wraps(func)

        def wrapper(self, *args, **kwargs):

            start_time = datetime.datetime.now()

            logging.info(f"{self.gp_table_name}: Started '{func.__name__}'")

            result = func(self, *args, **kwargs)

            end_time = datetime.datetime.now()

            logging.info(

                f"{self.gp_table_name}: Ended '{func.__name__}'. Duration: {end_time - start_time}"

            )

            return result

        return wrapper

 

    def check_row_counts(self, sf_connection):

        gp_row_count = self.get_gp_row_count()

        with sf_connection.cursor() as cursor:

            sf_schema_name = f"{self.sf_application_name}_CORE_{self.sf_schema_suffix}"

            cursor.execute(f"SELECT ROW_COUNT FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = '{sf_schema_name}' AND TABLE_NAME = UPPER('{self.gp_table_name}')")

            result = cursor.fetchone()

            sf_row_count = result[0] if result and result[0] is not None else -1

        return gp_row_count, sf_row_count

 

       

    def get_gp_table_columns(self, is_for_select_clause = True):

        try:

            with self.gp_connection.cursor() as cursor:

                cursor.execute(

                    f"SELECT column_name, data_type FROM information_schema.columns WHERE table_schema = '{self.gp_schema_name}' AND table_name = '{self.gp_table_name}' ORDER BY ordinal_position")

                columns = []

                for row in cursor.fetchall():

                    column_name = row[0]

                    data_type = row[1]

                    if ' ' in column_name or column_name != column_name.lower() or '/' in column_name or column_name == 'group':

                        column_name = f'"{column_name}"'

                    if data_type in ['character varying', 'character'] and self.transform_cols and is_for_select_clause:

                        column_name = f"REPLACE({column_name}, '\\', '$#$')"

                    columns.append(column_name)

                return ', '.join(columns)

        except Exception as e:

            logging.error(f"Error occurred while fetching columns for table '{self.gp_table_name}' in schema '{self.gp_schema_name}': {e}")

            return []

 

    @timing_decorator

    def delete_existing_files(self, s3_session, bucket_name):

        s3=s3_session.resource('s3')

        mybucket=s3.Bucket(bucket_name)

        mybucket.objects.filter(Prefix=self.table_path_s3).delete()

   

    @timing_decorator

    def alter_external_table_columns(self,gp_cursor, external_table):

        (ext_table_schema, ext_table_name) = external_table.split('.')

        # Fetch columns that are either 'money' or 'varchar' from the specified table

        gp_cursor.execute(f"""SELECT column_name, data_type, character_maximum_length

                        FROM INFORMATION_SCHEMA.COLUMNS

                        WHERE table_schema = '{ext_table_schema}'

                        AND table_name = '{ext_table_name}'

                        AND data_type IN ('money','character varying','character')""")

        columns = gp_cursor.fetchall()

 

        # Start building the ALTER TABLE SQL command

        alter_statements = []

 

        for column in columns:

            column_name = column[0]

            data_type = column[1]

            if ' ' in column_name or column_name != column_name.lower() or '/' in column_name or column_name == 'group':

                column_name = f'"{column_name}"'

 

            if data_type == 'money':

                # Alter money columns to NUMERIC(100,2)

                alter_statements.append(f"ALTER COLUMN {column_name} TYPE NUMERIC(100,2)")

           

            elif self.transform_cols and data_type in ('character varying','character'):

                # Alter varchar columns to increase length by 1

                max_length = column[2]

                if max_length is not None:

                    new_length = max_length + 100

                    alter_statements.append(f"ALTER COLUMN {column_name} TYPE VARCHAR({new_length})")

 

        # Only execute if there are columns to alter

        if alter_statements:

            alter_sql = f"ALTER TABLE {external_table} " + ", ".join(alter_statements) + ";"

            # print(alter_sql)

            gp_cursor.execute(alter_sql)

            logging.info(f"Altered table {external_table}.")

            #print(f"Executed the following ALTER TABLE statement:\n{alter_sql}")

        else:

            logging.info("No columns to alter.")

 

    @timing_decorator

    def create_external_table(self, s3_config_name, s3_session, bucket_name):

        external_table = f"{self.gp_schema_name}.ext_{datetime.datetime.now():%Y%m%d_%H%M%S}_{self.gp_table_name}"[:63]

        location = f"s3://s3-us-east-1.amazonaws.com/{bucket_name}/{self.table_path_s3} region=us-east-1 config=/home/gpadmin/{s3_config_name}.conf"

        self.delete_existing_files(s3_session,bucket_name)

        try:

            with self.gp_connection.cursor() as cursor:

                cursor.execute(f"DROP EXTERNAL TABLE IF EXISTS {external_table};")

                create_ext_table_sql = f"CREATE WRITABLE EXTERNAL TABLE {external_table} (LIKE {self.gp_schema_name}.{self.gp_table_name}) LOCATION ('{location}') FORMAT 'csv' ;"

                cursor.execute(create_ext_table_sql)

                # print(create_ext_table_sql)

                self.alter_external_table_columns(cursor, external_table)

 

                select_columns = self.get_gp_table_columns()

                insert_ext_table_sql = f"INSERT INTO {external_table} (SELECT {select_columns} FROM {self.gp_schema_name}.{self.gp_table_name});"

                # print(insert_ext_table_sql)

                cursor.execute(insert_ext_table_sql)

                rows_inserted = cursor.rowcount

 

                drop_ext_table_sql = f"DROP EXTERNAL TABLE {external_table};"

                cursor.execute(drop_ext_table_sql)

 

            logging.info(f"Completed external table load for the table {self.gp_table_name}, rows: {rows_inserted}")

            return rows_inserted

        except psycopg2.InterfaceError as e:

            logging.error(f"Connection error occurred for {self.gp_table_name}: {e}. Attempting to reopen connection...")

            self.gp_connection = get_gp_connection(self.gp_config)  # Reopen the connection

            return self.create_external_table(s3_config_name, s3_session, bucket_name)  # Retry the operation

 

        except Exception as e:

            logging.error(f"Error occurred while creating external table for {self.gp_table_name}: {e}")

            traceback.print_exc()

            self.gp_connection.rollback()

            raise e

 

    def get_sf_column_select_expr(self, cursor, sf_schema_name):

        try:

            cursor.execute(

                f"SELECT COLUMN_NAME, DATA_TYPE, ORDINAL_POSITION FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = '{sf_schema_name}' AND TABLE_NAME = '{self.gp_table_name.upper()}' ORDER BY ORDINAL_POSITION;")

            columns = cursor.fetchall()

 

            expressions = []

            for column_name, data_type, ordinal_position in columns:

                if data_type in ['TEXT','VARCHAR'] and self.transform_cols:

                    if self.transform_cols:

                        expression = f"RTRIM(REPLACE(${ordinal_position}, '$#$', '\\\\'))"

                    else:

                        expression = f"RTRIM(${ordinal_position})"

                else:

                    expression = f"${ordinal_position}"

                expressions.append(f"{expression}")

 

            # Join expressions to form the SELECT query

            select_expr = ', '.join(expressions)

            return select_expr

 

        except Exception as e:

            logging.error(f"Error occurred while generating the SELECT query for table '{self.gp_table_name}': {e}")

            return None

   

    def get_gp_col_detail(self):

        try:

            with self.gp_connection.cursor() as cursor:

                # Query to fetch column names and data types

                query = f"""

                SELECT column_name, data_type, character_maximum_length, numeric_precision, numeric_scale

                FROM information_schema.columns

                WHERE table_name = '{self.gp_table_name}' and table_schema = '{self.gp_schema_name}'

                ORDER BY ORDINAL_POSITION

                """

                cursor.execute(query)

                columns = cursor.fetchall()

                all_col_detail = []

            for column in columns:

                col_detail = list(column)

                column_name = col_detail[0]

                if ' ' in column_name or column_name != column_name.lower() or '/' in column_name or column_name == 'group':

                    col_detail[0] = f'"{column_name}"'

                all_col_detail.append(tuple(col_detail))

        except psycopg2.InterfaceError as e:

            logging.error(f"Connection error occurred for {self.gp_table_name}: {e}. Attempting to reopen connection...")

            self.gp_connection = get_gp_connection(self.gp_config)  # Reopen the connection

            return self.get_gp_col_detail()  # Retry the operation

 

        except psycopg2.OperationalError as e:

            logging.error(f"Connection error occurred for {self.gp_table_name}: {e}. Attempting to reopen connection...")

            self.gp_connection = get_gp_connection(self.gp_config)  # Reopen the connection

            return self.get_gp_col_detail()  # Retry the operation

 

        except Exception as e:

            logging.error(f"Error occurred while getting column detail for {self.gp_table_name}: {e}")

            traceback.print_exc()

            self.gp_connection.rollback()

            raise e

        return all_col_detail

 

    def get_sf_ddl(self, schema_suffix):

        # Mapping of PostgreSQL data types to Snowflake data types

        type_mapping = {

            'serial': 'INTEGER AUTOINCREMENT',

            'bigserial': 'BIGINT AUTOINCREMENT',

            'character varying': 'VARCHAR',

            'array':'ARRAY',

            'character': 'VARCHAR',

            'bit':'VARCHAR',

            'char':'VARCHAR',

            '"char"':'VARCHAR',

            'money':'NUMERIC',

            'bpchar': 'VARCHAR',

            'text': 'TEXT',

            'boolean': 'BOOLEAN',

            'bytea': 'BINARY',

            'integer': 'INTEGER',

            'bigint': 'BIGINT',

            'smallint': 'INTEGER',

            'decimal': 'NUMBER',

            'numeric': 'NUMERIC',

            'real': 'FLOAT',

            'double precision': 'FLOAT',

            'date': 'DATE',

            'time': 'TIME',

            'time without time zone': 'TIME',

            'timestamp': 'TIMESTAMP',

            'timestamp without time zone':'TIMESTAMP',

            'timestamp with time zone':'TIMESTAMP_TZ',

            'json': 'VARIANT',

            'jsonb': 'VARIANT',

            'unknown': 'TEXT',

            'interval': 'TEXT'

        }

        snowflake_ddl = f"CREATE OR REPLACE TABLE {self.sf_application_name}_CORE_{schema_suffix}.{self.gp_table_name} (\n"  

        columns = self.get_gp_col_detail()

        for column_name, data_type, length, numeric_precision, numeric_scale  in columns:

            snowflake_type = type_mapping.get(data_type.lower(), data_type)  # Default to original if not found

            if 'character varying' in data_type.lower():

                snowflake_type += f"({length})" if length else ""

            elif 'character' in data_type.lower():

                snowflake_type += f"({length})" if length else ""

            elif 'numeric' in data_type.lower():

                numeric_precision = 38 if numeric_precision is None else numeric_precision

                numeric_scale = 6 if numeric_scale is None else numeric_scale

                snowflake_type += f"({numeric_precision},{numeric_scale})"

            snowflake_ddl += f"    {column_name} {snowflake_type},\n"

       

        snowflake_ddl = snowflake_ddl.rstrip(',\n') + "\n);"

        #print(snowflake_ddl)

        return snowflake_ddl.strip()

 

    def process_file(self, obj, bucket_name, temp_dir, sf_schema_name, s3_obj, cursor):

        key = obj.key

        file_name = os.path.join(temp_dir, key.split('/')[-1])

        s3_obj.download_file(bucket_name, key, file_name)

        cursor.execute(f"USE SCHEMA {sf_schema_name}")

        cursor.execute(f"put file://{file_name} @%{self.gp_table_name}")

        logging.info(f"File {file_name} processed.")

        os.remove(file_name)

 

    @timing_decorator

    def copy_to_internal_stage(self, s3_session, bucket_name, sf_connection):

        s3=s3_session.resource('s3')

        s3_obj=s3_session.client('s3')

        mybucket=s3.Bucket(bucket_name)

        s3_objects = list(mybucket.objects.filter(Prefix=self.table_path_s3))

        sf_schema_name = f"{self.sf_application_name}_CORE_REPORTING"

        # Create a temporary directory to hold the files

        with tempfile.TemporaryDirectory() as temp_dir:

            with sf_connection.cursor() as cursor:

                cursor.execute(f"rm @%{self.gp_table_name}")

                with concurrent.futures.ThreadPoolExecutor(max_workers=15) as executor:

                    # Submit tasks to executor

                    futures = [executor.submit(self.process_file, obj, bucket_name, temp_dir, sf_schema_name, s3_obj, cursor)

                            for obj in s3_objects]

                    for future in concurrent.futures.as_completed(futures):

                        try:

                            # Wait for the result (if any) and ensure no exceptions are raised

                            future.result()  # This will raise if the function raised an exception

                        except Exception as e:

                            logging.error(f"Error processing file: {e}")

                            # raise  # Uncomment if you want to stop execution on error

 

    @timing_decorator

    def copy_data_to_snowflake(self, s3_session, bucket_name, sf_connection):

        try:

            with sf_connection.cursor() as cursor:

                if 'BMA' in self.sf_application_name:

                    schema_suffix = 'REPORTING'

                    table_path = f'@%{self.gp_table_name}'

                else:

                    schema_suffix = self.sf_schema_suffix

                    table_path = f'@{self.sf_application_name}_CORE_RAW.{self.sf_application_name}_INBOUND_STAGE/dataloads/s3protocol/{self.gp_schema_name}/{self.gp_table_name}/'

                sf_schema_name = f"{self.sf_application_name}_CORE_{schema_suffix}"

                # Create table if the flag is set

                if self.create_sf_table:

                    sf_ddl = self.get_sf_ddl(schema_suffix)

                    cursor.execute(sf_ddl)

                    logging.info(f"Table {self.gp_table_name} created in Snowflake.")

                # Call copy_to_internal_stage after table creation

                if 'BMA' in self.sf_application_name or 'FACETS' in self.sf_application_name:

                    table_path = f'@%{self.gp_table_name}'

                    self.copy_to_internal_stage(s3_session, bucket_name, sf_connection)

 

                logging.info(f"Copying data from S3/Internal stage to Snowflake table {self.gp_table_name}")

                select_expr = self.get_sf_column_select_expr(cursor, sf_schema_name)

                truncate_sql = f"TRUNCATE TABLE {sf_schema_name}.{self.gp_table_name}"

                cursor.execute(truncate_sql)

                cursor.execute(f"USE SCHEMA {sf_schema_name}")

                copy_command = f"""COPY INTO {sf_schema_name}.{self.gp_table_name} from (select {select_expr} from {table_path})

                    FILE_FORMAT=(type=CSV,FIELD_DELIMITER=',',RECORD_DELIMITER = '\n',FIELD_OPTIONALLY_ENCLOSED_BY = '"',  error_on_column_count_mismatch=True)

                    ;"""

                #ESCAPE_UNENCLOSED_FIELD = NONE,

                #print(copy_command)

                cursor.execute(copy_command)

                copy_detail = cursor.fetchall()

                file_count = len(copy_detail)

                inserted_row_count = sum(row[3] if len(row) > 3 else 0 for row in copy_detail)

                logging.info(f"File count: {file_count}, row_count: {inserted_row_count}")

            return file_count, inserted_row_count

        except snowflake.connector.errors.ProgrammingError as e:

            logging.error(f"Error occurred while copying data: {e}")

            traceback.print_exc()

            raise e

 

    @timing_decorator

    def get_row_count_from_s3(self,s3_session, bucket_name):

        s3_resource = s3_session.resource('s3')

        bucket = s3_resource.Bucket(bucket_name)

        s3_client = s3_session.client('s3')

        sql_stmt = """SELECT COUNT(1) FROM s3object """

        total_row_count= 0

        file_count = 0

        for obj in bucket.objects.filter(Prefix = self.table_path_s3):

            file_count = file_count + 1

            key = obj.key

            req = s3_client.select_object_content(

                Bucket = bucket_name,

                Key = key,

                ExpressionType="SQL",

                Expression=sql_stmt,

                InputSerialization={"CSV":{"FileHeaderInfo":"NONE","AllowQuotedRecordDelimiter":True},"CompressionType":"GZIP"},

                OutputSerialization={"CSV":{}}

            )

            for event in req['Payload']:

                if 'Records' in event:

                    row_count = int(event['Records']['Payload'].strip())

            total_row_count= total_row_count+row_count

        logging.info(f"Row count from S3: {total_row_count}, file_count {file_count}")

        return file_count, total_row_count

 

    def get_gp_row_count(self):

        try:

            with self.gp_connection.cursor() as cursor:

                # Query to fetch column names and data types

                query = f"""

                SELECT COUNT(1) AS row_count

                FROM {self.gp_schema_name}.{self.gp_table_name}

                """

                cursor.execute(query)

                row_count = cursor.fetchone()

                return row_count[0]

        except psycopg2.InterfaceError as e:

            logging.error(f"Connection error occurred for {self.gp_table_name}: {e}. Attempting to reopen connection...")

            self.gp_connection = get_gp_connection(self.gp_config)  # Reopen the connection

            return self.get_gp_row_count()  # Retry the operation

 

        except Exception as e:

            logging.error(f"Error occurred while getting row count for {self.gp_table_name}: {e}")

            traceback.print_exc()

            self.gp_connection.rollback()

            raise e

 

    def get_gp_primary_key(self):

        try:

            with self.gp_connection.cursor() as cursor:

                sql = f"""SELECT pg_attribute.attname FROM pg_index

                            JOIN pg_class ON pg_class.oid = pg_index.indrelid

                            JOIN pg_attribute ON pg_attribute.attrelid = pg_class.oid

                            JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace

                            WHERE pg_namespace.nspname = '{self.gp_schema_name}'

                            AND pg_class.relname = '{self.gp_table_name}' -- specify the table name here

                            AND pg_attribute.attnum = any(pg_index.indkey)

                            AND indisprimary;"""

           

                cursor.execute(sql)

                primary_keys = [row[0] for row in cursor.fetchall()]            

                return primary_keys

        except psycopg2.InterfaceError as e:

            logging.error(f"Connection error occurred for {self.gp_table_name}: {e}. Attempting to reopen connection...")

            self.gp_connection = get_gp_connection(self.gp_config)  # Reopen the connection

            return self.get_gp_primary_key()  # Retry the operation

 

        except Exception as e:

            logging.error(f"Error occurred while getting primary key for {self.gp_table_name}: {e}")

            traceback.print_exc()

            self.gp_connection.rollback()

            raise e

 

    @timing_decorator

    def load_chunk_to_s3(self, s3_session, bucket_name, part_number, offset, rows_per_chunk, order_by_clause, column_list):

        with get_gp_connection(self.gp_config).cursor() as cursor:

            local_gzip_filename = f"{self.gp_table_name}_{part_number}.csv.gz"

            start_time = time.time()

            with gzip.open(local_gzip_filename, 'w') as f:

                with cursor:

                    cursor.copy_expert(

                        f"COPY (SELECT {column_list} FROM {self.gp_schema_name}.{self.gp_table_name} ORDER BY {order_by_clause} OFFSET {offset} LIMIT {rows_per_chunk}) TO STDOUT WITH (FORMAT CSV)",

                        f)

            end_time = time.time()

            extraction_time = end_time - start_time

            logging.info(f"File extraction complete for part {part_number}. Time taken: {extraction_time:.2f} seconds")

 

            start_time = time.time()

            s3_key = f"{self.table_path_s3}/{local_gzip_filename}"

            s3_client = s3_session.client('s3')

            s3_client.upload_file(local_gzip_filename, bucket_name, s3_key)

            end_time = time.time()

            upload_time = end_time - start_time

            logging.info(f"File uploaded to S3 for part {part_number}. Time taken: {upload_time:.2f} seconds")

            #os.remove(local_gzip_filename)

        return extraction_time, upload_time

   

    @timing_decorator

    def export_gp_to_s3(self, s3_session, bucket_name):

        column_list = self.get_gp_table_columns()

        row_count = self.get_gp_row_count()

        order_by_col_list = self.get_gp_table_columns(False)

        order_by_clause = ', '.join(self.get_gp_primary_key() or []) or order_by_col_list

        rows_per_chunk = 20000000

        total_extraction_time = 0

        total_upload_time = 0

        with concurrent.futures.ThreadPoolExecutor(max_workers=5) as executor:

            part_number = 1

            futures = []

            offset = 0

            while offset < row_count:

                future = executor.submit(

                    self.load_chunk_to_s3,

                    s3_session,

                    bucket_name,

                    # temp_dir,

                    part_number,

                    offset,

                    rows_per_chunk,

                    order_by_clause,

                    column_list

                )

                futures.append(future)

                offset += rows_per_chunk

                part_number += 1

 

        for future in concurrent.futures.as_completed(futures):

                extraction_time, upload_time = future.result()

                total_extraction_time += extraction_time

                total_upload_time += upload_time

 

    def create_gpfdist_files(self):

        ports = [f"{(random.randint(0, 96) + i) % 100:02}" for i in range(4)]

       

        try:

            with get_gp_connection(self.gp_config).cursor() as cursor:

                cursor.execute(f"set writable_external_table_bufsize=12800;")

                cursor.execute(f"set gpfdist_retry_timeout=3600;")

                cursor.execute(f"SELECT substr(current_database(), 4, length(current_database()));")

                db_suffix = cursor.fetchone()[0]

                # shared_location = f"{self.gp_config['gpf_dist_path']}{self.gp_schema_name}\\inprocess\\" if db_suffix in ('dev','upgd') else f"\\\\ads.fideliscare.org\\applications\\GPSQL\\PRD\\outgoing\\infomart\\inprocess\\"

                gpfdist_base_url = "gpdev-dia1.fideliscare.org:85" if db_suffix in ('dev', 'upgd') else "prd-odsapp0101.ads.fideliscare.org:85"

                gpfdist_ports = [f"{gpfdist_base_url}{port}" for port in ports]

                external_table_name = f"ext_{datetime.datetime.now():%Y%m%d_%H%M%S}_{self.gp_table_name}"[:63]

                external_table = f"{self.gp_schema_name}.{external_table_name}"

                location_values = ",\n".join(

                                    [f"'gpfdist://{gpfdist_ports[i % 4]}/dataloads/{self.sf_application_name.lower()}/{external_table_name}_{i + 1:03}.csv.gz'"

                                    for i in range(336)]

                                )

                cursor.execute(f"DROP EXTERNAL TABLE IF EXISTS {external_table};")

                create_ext_table_sql = f"""

                                CREATE WRITABLE EXTERNAL TABLE {external_table} (LIKE {self.gp_schema_name}.{self.gp_table_name})

                                LOCATION (

                                    {location_values}

                                ) FORMAT 'csv' (DELIMITER ',' );

                                """

                # print(create_ext_table_sql)

                cursor.execute(create_ext_table_sql)

                self.alter_external_table_columns(cursor, external_table)

                select_columns = self.get_gp_table_columns()

                insert_ext_table_sql = f"INSERT INTO {external_table} (SELECT {select_columns} FROM {self.gp_schema_name}.{self.gp_table_name});"

                # print(insert_ext_table_sql)

                cursor.execute(insert_ext_table_sql)

                rows_inserted = cursor.rowcount

 

                drop_ext_table_sql = f"DROP EXTERNAL TABLE {external_table};"

                cursor.execute(drop_ext_table_sql)

 

                logging.info(f"Completed external table load for the table {self.gp_table_name}, rows: {rows_inserted}")

                return external_table_name

        except psycopg2.InterfaceError as e:

            logging.error(f"Connection error occurred for {self.gp_table_name}: {e}. Attempting to reopen connection...")

            self.gp_connection = get_gp_connection(self.gp_config)  # Reopen the connection

            return self.create_gpfdist_files()

 

        except Exception as e:

            logging.error(f"Error occurred while creating external table for {self.gp_table_name}: {e}")

            traceback.print_exc()

            self.gp_connection.rollback()

            raise e

           

    async def async_delete_file(self, file_path):

        # Simulate async file deletion

        await asyncio.to_thread(file_path.unlink)  # Delete file in background

        logging.info(f"File deleted: {file_path.name}")

 

    def upload_to_s3(self, s3_session, bucket_name, folder_path, file_prefix, files):

        start_time = time.time()

        start_time_formatted = datetime.datetime.fromtimestamp(start_time).strftime("%Y-%m-%d %H:%M:%S")

        logging.info(f"Started S3 upload for files {folder_path}")

        credentials = s3_session.get_credentials()

        os.environ['AWS_ACCESS_KEY_ID'] = credentials.access_key

        os.environ['AWS_SECRET_ACCESS_KEY'] = credentials.secret_key

        command = f"sync {folder_path} s3://{bucket_name}/{self.table_path_s3}"

        aws_cli_command = f"aws {command} --exclude \"*\" --include \"{file_prefix}*\""

        result = subprocess.run(aws_cli_command, shell=True, capture_output = True, text = True)

        end_time = time.time()

        upload_time = end_time - start_time

        logging.info(result)

        for file in files:

            file.unlink()

        logging.info(f"File uploaded to S3 for {folder_path}. Time taken: {upload_time:.2f} seconds")

       

    def upload_and_delete(self, s3_client, bucket_name, file_path):

        try:

            start_time = time.time()

            start_time_formatted = datetime.datetime.fromtimestamp(start_time).strftime("%Y-%m-%d %H:%M:%S")

            logging.info(f"Started S3 upload for file: {file_path.name}")

            s3_key = f"{self.table_path_s3}{file_path.name}"

            # Multipart upload config

            transfer_config = TransferConfig(

                multipart_threshold=8 * 1024 * 1024,

                multipart_chunksize=16 * 1024 * 1024,

                max_concurrency=20,

                use_threads=True

            )

            # Upload to S3

            s3_client.upload_file(str(file_path), bucket_name, s3_key, Config=transfer_config)

 

            upload_end = time.time()

            upload_time = upload_end - start_time

 

            # Delete local file

            delete_start = time.time()

            try:

                file_path.unlink()

                delete_success = True

            except Exception as delete_err:

                logging.error(f"Failed to delete file {file_path}: {delete_err}")

                delete_success = False

            delete_end = time.time()

 

            delete_time = delete_end - delete_start

            total_time = delete_end - start_time

 

            logging.info(f"File uploaded to S3: {s3_key}. Upload time: {upload_time:.2f}s | Delete time: {delete_time:.2f}s | Total time: {total_time:.2f}s")

            if not delete_success:

                logging.warning(f"File was uploaded but could not be deleted: {file_path}")

 

        except Exception as e:

            logging.error(f"Error processing file {file_path}: {e}")

 

    def export_gpfdist_to_s3(self, s3_session, bucket_name):

        shared_location = f"{self.gp_config['gpf_dist_path']}\\{self.sf_application_name.lower()}\\"

       

        # shared_location = Path(shared_location) / self.gp_schema_name / self.gp_table_name

        # shared_location.mkdir(parents=True, exist_ok=True)

        # shared_location = str(shared_location)  # if you need it as a string

 

        #file_prefix = f"ext_20250331_161732"

        #files = [file for file in Path(shared_location).rglob('*') if file.is_file() and file.name.startswith(file_prefix)]

        file_prefix = self.create_gpfdist_files()

        files = [file for file in Path(shared_location).iterdir() if file.is_file() and file.name.startswith(file_prefix)]

        logging.info(f"Starting with S3 upload of files...")

        #self.upload_to_s3(s3_session, bucket_name, shared_location, file_prefix, files)

        #s3_config = Config(s3={'use_accelerate_endpoint': True})

        s3_client = s3_session.client('s3', verify=False)

        with concurrent.futures.ThreadPoolExecutor(max_workers=15) as executor:

            futures = []

            for file in files:

                # Submit the upload task to the thread pool

                futures.append(executor.submit(self.upload_and_delete, s3_client, bucket_name, file))

           

            # Wait for all uploads to finish (but allow deletions to happen asynchronously)

            for future in futures:

                future.result()

       

def process_table(

    table: Dict,

    gp_config: dict,

    s3_config_name: str,

    s3_session,

    bucket_name: str,

    sf_connection,

    sf_config

) -> Dict:

    try:

        application = table['application']

        logging.info(f"Starting for the table {table}...")

        start_time = time.time()

 

        table_obj = ProcessTable(table, gp_config, sf_config)

 

        #check the row_counts first if they match

        gp_row_count, sf_row_count = table_obj.check_row_counts(sf_connection)

        logging.info(f"GP Rowcount: {gp_row_count}, SF Rowcount: {sf_row_count}")

        if gp_row_count == sf_row_count and table_obj.rowcount_check:

            table['status'] = f"Row counts already match between GP and Snowflake."

            table['rows_exported'] = gp_row_count

            table['rows_inserted'] = sf_row_count

            logging.info(f"Row counts already match between GP and Snowflake.")

       

        else:

            if not table_obj.is_target_load_only:

                # # Exporting data to S3

                rows_exported = table_obj.create_external_table(s3_config_name, s3_session, bucket_name)

                table['export_time'] = datetime.datetime.fromtimestamp(start_time).strftime("%Y-%m-%d %H:%M:%S")

                table['rows_exported'] = rows_exported

                table['status'] = 'Completed exporting to S3'

               

                #Verifying row count from S3

                file_count, rows_from_s3 = table_obj.get_row_count_from_s3(s3_session, bucket_name) if 'BMA' in application else table_obj.copy_data_to_snowflake(s3_session, bucket_name, sf_connection)

                table['s3_row_count'] = rows_from_s3

               

                if rows_exported != rows_from_s3 and file_count < 336 and table_obj.enable_gpfdist:

                    logging.warning('Row Count does not match with S3, using GP query to export to S3...')

                    table_obj.delete_existing_files(s3_session, bucket_name)

                    #table_obj.export_gp_to_s3(s3_session, bucket_name)

                    table_obj.export_gpfdist_to_s3(s3_session, bucket_name)

                    # Loading data into Snowflake

                    file_count, rows_inserted = table_obj.copy_data_to_snowflake(s3_session, bucket_name, sf_connection)

                else:

                    if 'BMA' in application:

                        file_count, rows_inserted = table_obj.copy_data_to_snowflake(s3_session, bucket_name, sf_connection)

            else:

                file_count, rows_inserted = table_obj.copy_data_to_snowflake(s3_session, bucket_name, sf_connection)

               

            table['status'] = 'Completed loading to Snowflake'

            table['rows_inserted'] = locals().get('rows_inserted', None) or rows_from_s3

       

        # Time taken for the entire process

        end_time = time.time()

        total_time_taken = end_time - start_time

        formatted_time = str(datetime.timedelta(seconds=total_time_taken))

        table['total_time_taken'] = formatted_time

        logging.info(f"Completed the process for the table {table}")

       

        return table

   

    except Exception as e:

        logging.error(f"Exception in processing the table {table}: {e}")

        table['status'] = f'Exception: {e}'

        return table

 

def append_row_dynamic_csv(file_path, row):

    """

    Appends a row to CSV, dynamically updating header if new columns appear.

    If new columns are found, rewrites the entire CSV with updated header.

    """

 

    # Determine current fieldnames if file exists

    if os.path.isfile(file_path) and os.stat(file_path).st_size > 0:

        with open(file_path, mode='r', newline='') as csvfile:

            reader = csv.DictReader(csvfile)

            existing_fieldnames = reader.fieldnames if reader.fieldnames else []

            existing_rows = list(reader)

    else:

        existing_fieldnames = []

        existing_rows = []

 

    row_keys = list(row.keys())

    # Check if new columns have appeared

    if set(row_keys) - set(existing_fieldnames):

        # New columns detected, update fieldnames

        updated_fieldnames = list(existing_fieldnames) + [k for k in row_keys if k not in existing_fieldnames]

 

        # Rewrite CSV with updated header

        with open(file_path, mode='w', newline='') as csvfile:

            writer = csv.DictWriter(csvfile, fieldnames=updated_fieldnames)

            writer.writeheader()

 

            for existing_row in existing_rows:

                full_row = {field: existing_row.get(field, "") for field in updated_fieldnames}

                writer.writerow(full_row)

 

            # Write the new row

            full_row = {field: row.get(field, "") for field in updated_fieldnames}

            writer.writerow(full_row)

    else:

        # No new columns, append row

        with open(file_path, mode='a', newline='') as csvfile:

            writer = csv.DictWriter(csvfile, fieldnames=existing_fieldnames or row_keys)

            if not existing_fieldnames:

                writer.writeheader()

            writer.writerow(row)

 

def process_tables_multithreaded(

    table_list: List[Dict],

    gp_config: dict,

    s3_config_name: str,

    s3_session,

    bucket_name: str,

    sf_connection,

    sf_config,

    file_path: str

):

    """Process multiple tables concurrently using a thread pool, saving results incrementally to CSV."""

 

    # Using ThreadPoolExecutor to run 5 threads concurrently

    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:

        future_to_table = {

            executor.submit(

                process_table,

                table,

                gp_config,

                s3_config_name,

                s3_session,

                bucket_name,

                sf_connection,

                sf_config

            ): table for table in table_list

        }

 

        for future in concurrent.futures.as_completed(future_to_table):

            table = future_to_table[future]

            try:

                result = future.result()  # Get the result dict for the table

 

            except Exception as e:

                logging.error(f"Error processing table {table['table_name']}: {e}, Details: {table}")

 

            finally:

                append_row_dynamic_csv(file_path, result)

 

    logging.info(f"Completed processing all tables. Results saved incrementally to {file_path}.")

 

def main():

   

    parser = argparse.ArgumentParser(description="GP_SF_Load.py GP_FIDUPGD_SVC NYHPFIN TST DataLoadConfig.json input_table_list.csv")

   

    # Add positional arguments (arguments without names)

    parser.add_argument('gp_config_name', type=str, help='GP Config Name')

    parser.add_argument('sf_app_name', type=str, help='SF App Name')

    parser.add_argument('environment', type=str, help='SF Environment')

    parser.add_argument('config_file_name', type=str, nargs='?', default="DataLoadConfig.json", help='Config File Name')

    parser.add_argument('input_table_list_file_name', type=str, nargs='?', default="input_table_list.csv", help='File name with list of tables to be loaded')

   

    # Parse the command-line arguments

    args = parser.parse_args()

    logging.info(args)

    with open(args.config_file_name, 'r') as file:

        config = json.load(file)

    gp_config = args.gp_config_name

    env = args.environment

    application = args.sf_app_name

    sf_config = f"SF_{env}_{application}"

    gp_config = config[gp_config]

    sf_config = config[sf_config]

    s3_config = config[f"S3_{env}"]

    sheet_name = f"{application}_{env}_{datetime.datetime.now().strftime('%Y%m%d%H%M%S')}"

    file_path = f'{sheet_name}.csv'

    table_list = get_sheet_data(args.input_table_list_file_name)

    bucket_name = s3_config['bucket_name']

    s3_session = get_s3_session(s3_config)

    s3_config_name = gp_config['s3_config_name']

    sf_connection = get_sf_connection(sf_config)

    process_tables_multithreaded(table_list, gp_config, s3_config_name, s3_session, bucket_name, sf_connection, sf_config, file_path)

 

if __name__ == "__main__":

    # Code here will only run if the file is run directly

    main()

 
