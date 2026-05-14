import os
import subprocess
import json
from flask import Flask, render_template
import csv
import io

app = Flask(__name__)

DB_PATH = "/out/bouncer.db"
PASSPHRASE = os.environ.get("DB_PASSPHRASE")

def execute_sql(query):
    # Using the same approach as db_helper.sh
    cmd = ["sqlcipher", "-batch", "-header", "-csv", "-cmd", f"PRAGMA key = '{PASSPHRASE}';", DB_PATH, query]
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.stdout

@app.route("/")
def index():
    query = "SELECT repo, pr_number, head_oid, report_text, metrics_json FROM pr_reports;"
    csv_output = execute_sql(query)
    
    reader = csv.DictReader(io.StringIO(csv_output))
    reports = list(reader)
    
    for report in reports:
        if report['metrics_json']:
            try:
                report['metrics'] = json.loads(report['metrics_json'])
            except json.JSONDecodeError:
                report['metrics'] = {}
        else:
            report['metrics'] = {}
            
    return render_template("index.html", reports=reports)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001)
