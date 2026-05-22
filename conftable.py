from atlassian import Confluence
from bs4 import BeautifulSoup
import csv
import os

# ========================= CONFIG =========================
CONFLUENCE_URL = "https://your-company.atlassian.net"
USERNAME = "your.email@company.com"
API_TOKEN = os.getenv("CONFLUENCE_API_TOKEN")   # Recommended

PAGE_ID = "123456789"                           # Change to your page ID
COLUMN_TO_EXTRACT = "Your Column Name"          # Exact column header
# =========================================================

# Connect to Confluence
confluence = Confluence(
    url=CONFLUENCE_URL,
    username=USERNAME,
    password=API_TOKEN,
    cloud=True
)

def get_page_tables(page_id):
    """Extract all tables from a Confluence page"""
    page = confluence.get_page_by_id(page_id, expand='body.storage')
    html = page['body']['storage']['value']
    
    soup = BeautifulSoup(html, 'html.parser')
    tables = soup.find_all('table')
    
    extracted_tables = []
    
    for idx, table in enumerate(tables):
        headers = []
        data = []
        
        # Extract headers
        header_row = table.find('tr')
        if header_row:
            headers = [th.get_text(strip=True) for th in header_row.find_all(['th', 'td'])]
        
        # Extract rows
        rows = table.find_all('tr')[1:] if header_row else table.find_all('tr')
        for tr in rows:
            row = [td.get_text(strip=True) for td in tr.find_all(['td', 'th'])]
            if row and any(cell.strip() for cell in row):   # skip empty rows
                data.append(row)
        
        if headers or data:
            extracted_tables.append({
                'table_index': idx,
                'headers': headers,
                'data': data
            })
    
    return extracted_tables


# ====================== MAIN ======================
tables = get_page_tables(PAGE_ID)

if not tables:
    print("No tables found on the page.")
else:
    print(f"Found {len(tables)} table(s) on the page.\n")
    
    # Use the first table (change index if you have multiple tables)
    table = tables[0]
    headers = table['headers']
    rows = table['data']
    
    print(f"Table {table['table_index']} Headers:")
    print(headers)
    
    # Extract specific column
    if COLUMN_TO_EXTRACT in headers:
        col_index = headers.index(COLUMN_TO_EXTRACT)
        
        column_values = []
        for row in rows:
            if col_index < len(row):
                value = row[col_index].strip()
                if value:  # skip empty
                    column_values.append(value)
        
        # Save column to text file
        with open("extracted_column.txt", "w", encoding="utf-8") as f:
            f.write("\n".join(column_values))
        
        print(f"\nSuccessfully extracted {len(column_values)} values from column '{COLUMN_TO_EXTRACT}'")
        print("Saved to: extracted_column.txt")
        
        # Optional: Save full table as CSV
        with open("full_table.csv", "w", encoding="utf-8", newline='') as f:
            writer = csv.writer(f)
            writer.writerow(headers)
            writer.writerows(rows)
        
        print("Full table saved to: full_table.csv")
        
    else:
        print(f"\nColumn '{COLUMN_TO_EXTRACT}' not found!")
        print("Available columns:", headers)
