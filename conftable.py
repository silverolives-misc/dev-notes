from atlassian import Confluence
import pandas as pd
from bs4 import BeautifulSoup
import os

# ========================= CONFIG =========================
CONFLUENCE_URL = "https://your-company.atlassian.net"   # or your self-hosted URL
USERNAME = "your.email@company.com"                     # Email for Cloud
API_TOKEN = os.getenv("CONFLUENCE_API_TOKEN")           # Better to use env var

PAGE_ID = "123456789"                                   # Page ID (e.g. from URL)

COLUMN_TO_EXTRACT = "Your Column Name"                  # Exact header name
# =========================================================

# Connect to Confluence
confluence = Confluence(
    url=CONFLUENCE_URL,
    username=USERNAME,
    password=API_TOKEN,   # For Cloud it's the API token
    cloud=True            # Set False if self-hosted (Server/Data Center)
)

# Option A: Use built-in method (easiest)
def get_table_data(page_id):
    tables = confluence.get_tables_from_page(page_id)
    return tables  # returns list of dicts with table data

# Option B: Manual parsing (more control)
def get_page_table(page_id):
    page = confluence.get_page_by_id(page_id, expand='body.storage')
    html = page['body']['storage']['value']
    
    soup = BeautifulSoup(html, 'html.parser')
    tables = soup.find_all('table')
    
    extracted_tables = []
    
    for table in tables:
        data = []
        headers = []
        
        # Get headers
        for th in table.find_all('th'):
            text = th.get_text(strip=True)
            if text:
                headers.append(text)
        
        # Get rows
        for tr in table.find_all('tr'):
            row = [td.get_text(strip=True) for td in tr.find_all(['td', 'th'])]
            if row and any(row):  # skip empty rows
                data.append(row)
        
        if headers and data:
            extracted_tables.append({
                'headers': headers,
                'data': data
            })
    
    return extracted_tables

# ====================== MAIN ======================
tables = get_page_table(PAGE_ID)   # or use get_table_data()

if tables:
    # Take the first table (change index if needed)
    table = tables[0]
    df = pd.DataFrame(table['data'], columns=table['headers'])
    
    print("Full table:")
    print(df)
    
    # Extract one column
    if COLUMN_TO_EXTRACT in df.columns:
        column_data = df[COLUMN_TO_EXTRACT].dropna().tolist()
        
        # Save to file
        with open("extracted_column.txt", "w", encoding="utf-8") as f:
            f.write("\n".join(column_data))
        
        # Also save as CSV
        df.to_csv("full_table.csv", index=False)
        
        print(f"\nExtracted {len(column_data)} values from column '{COLUMN_TO_EXTRACT}'")
    else:
        print(f"Column '{COLUMN_TO_EXTRACT}' not found. Available columns: {df.columns.tolist()}")
else:
    print("No tables found on the page.")
